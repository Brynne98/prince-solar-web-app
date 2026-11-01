// A stand-in for Paystack's charge, verify and refund calls, for scale tests of /billing/run
// (SOLAR-264). Answers as test mode did on 2026-10-31: a reused reference is refused with 400
// "Duplicate Transaction Reference", an unknown one on verify with 400 "Transaction reference not found.".
//   node scripts/billing-sim/mock-paystack.mjs [--port 4500] [--latency 650] [--decline 0.1]
//        [--hang 0.005] [--drop 0.005] [--busy 0.005] [--verifybusy 0] [--seed 1]
// --hang: the charge goes through, the answer comes after 35 s (the function gives up at 30 s).
// --drop: the charge goes through, the connection is cut. --busy: 503, nothing charged.
// --verifybusy: verify answers 503, so a charge with a lost answer stays open until the next run.
// GET /stats: what was charged, per reference.
import http from 'node:http';

const arg = (k, d) => { const i = process.argv.indexOf('--' + k); return i > 0 ? Number(process.argv[i + 1]) : d; };
const PORT = arg('port', 4500), LATENCY = arg('latency', 650);
const P = { decline: arg('decline', 0.1), hang: arg('hang', 0.005), drop: arg('drop', 0.005), busy: arg('busy', 0.005), verifyBusy: arg('verifybusy', 0) };
let s = arg('seed', 1) >>> 0;
const rnd = () => { s = (s + 0x6d2b79f5) >>> 0; let t = s; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };

const tx = new Map();          // reference -> transaction
const refunded = new Set();
const stats = { calls: 0, charges: 0, duplicates: 0, verifies: 0, notFound: 0, refunds: 0, hang: 0, drop: 0, busy: 0, inFlight: 0, maxInFlight: 0 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const send = (res, code, body) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };

http.createServer(async (req, res) => {
  let raw = '';
  for await (const ch of req) raw += ch;
  const body = raw ? JSON.parse(raw) : {};
  const url = new URL(req.url, 'http://x');
  stats.calls++; stats.inFlight++; stats.maxInFlight = Math.max(stats.maxInFlight, stats.inFlight);
  try {
    if (req.method === 'GET' && url.pathname === '/stats') {
      const out = [...tx.values()].map((t) => ({ reference: t.reference, status: t.status, tries: t.tries }));
      return send(res, 200, { ...stats, transactions: out });
    }
    await sleep(LATENCY * (0.7 + 0.6 * rnd()));
    if (req.method === 'POST' && url.pathname === '/transaction/charge_authorization') {
      const old = tx.get(body.reference);
      if (old) { old.tries++; stats.duplicates++; return send(res, 400, { status: false, message: 'Duplicate Transaction Reference' }); }
      const x = rnd();
      if (x < P.busy) { stats.busy++; return send(res, 503, { status: false, message: 'Service unavailable' }); }
      const t = { reference: body.reference, amount: body.amount, currency: body.currency, tries: 1,
        status: rnd() < P.decline ? 'failed' : 'success', gateway_response: 'Approved',
        authorization: { authorization_code: body.authorization_code, reusable: true, last4: '4081', card_type: 'visa ' } };
      if (t.status === 'failed') t.gateway_response = 'Declined';
      tx.set(body.reference, t);
      stats.charges++;
      if (x < P.busy + P.hang) { stats.hang++; await sleep(35_000); }
      else if (x < P.busy + P.hang + P.drop) { stats.drop++; return req.socket.destroy(); }
      return send(res, 200, { status: true, message: 'Charge attempted', data: t });
    }
    if (req.method === 'GET' && url.pathname.startsWith('/transaction/verify/')) {
      stats.verifies++;
      if (rnd() < P.verifyBusy) { stats.verifyBusy = (stats.verifyBusy || 0) + 1; return send(res, 503, { status: false, message: 'Service unavailable' }); }
      const t = tx.get(decodeURIComponent(url.pathname.split('/').pop()));
      if (!t) { stats.notFound++; return send(res, 400, { status: false, message: 'Transaction reference not found.' }); }
      return send(res, 200, { status: true, message: 'Verification successful', data: t });
    }
    if (req.method === 'POST' && url.pathname === '/refund') {
      // as Paystack (test mode, 2026-10-31): a second refund of one transaction is refused
      if (refunded.has(body.transaction)) return send(res, 400, { status: false, message: 'A refund already exist' });
      refunded.add(body.transaction);
      stats.refunds++;
      return send(res, 200, { status: true, message: 'Refund has been queued for processing', data: { status: 'pending', transaction: { reference: body.transaction } } });
    }
    send(res, 404, { status: false, message: 'not here' });
  } finally { stats.inFlight--; }
}).listen(PORT, () => console.log(`mock paystack on :${PORT}, latency ${LATENCY} ms`, P));
