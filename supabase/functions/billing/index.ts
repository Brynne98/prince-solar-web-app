// `billing` — takes money through Paystack (SOLAR-208). The rules are in 0116; this
// only talks to Paystack and reports back.
//
//   POST /billing/pay      the signed-in user, { plan, period?, extras?, newCard? },
//                          { settle: true } to pay a failed renewal, or { card: true }
//                          to change the saved card (R1 on the card page, refunded once
//                          paid; SOLAR-238). Charges the saved
//                          card when there is one; otherwise answers { url } for
//                          Paystack's card page, which comes back to the app with
//                          ?reference=.
//   POST /billing/verify   the signed-in user, { reference }: asks Paystack whether
//                          that card-page payment went through. Answers { status, kind }.
//   POST /billing/webhook  Paystack's own notice of a payment, refund or dispute (HMAC-signed).
//                          Answers non-2xx when it could not record one, so Paystack sends it again.
//   POST /billing/run      pg_cron, every 5 minutes for 2 hours a day (0128): first refunds
//                          Paystack refused before are asked for again (0130, REFUND_BUDGET_MS),
//                          then renewals and retries, RUN_PARALLEL at a time, new ones started
//                          for RUN_BUDGET_MS; the rest go back for the next call.
//
// verify_jwt is off: Paystack has no Supabase session. Each route checks its caller.
// Secret: PAYSTACK_SECRET_KEY (test key until the company account is live).
import { db, denyUnlessServer } from "../_shared/sunsynk.ts";
import { serve, track } from "../_shared/errors.ts";
import { corsHeaders, json } from "../_shared/cors.ts";
import { createHmac, timingSafeEqual } from "node:crypto";
import { Buffer } from "node:buffer";
import { payClosed } from "../_shared/gate.ts";

const SECRET = Deno.env.get("PAYSTACK_SECRET_KEY") ?? "";
// Local tests point this at a stand-in server.
const PAYSTACK = Deno.env.get("PAYSTACK_URL") ?? "https://api.paystack.co";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
// Secret: auth user ids allowed to pay on a test key in production, comma-separated (SOLAR-267).
const TEST_USERS = Deno.env.get("PAYSTACK_TEST_USERS") ?? "";

type Card = Record<string, unknown>;
type Tx = {
  status: string; reference: string; amount: number; currency: string; gateway_response?: string; authorization?: Card;
  customer?: { email?: string }; paid_at?: string;
};
/** Paystack's HTTP status; 0 when no answer came (timeout, network). */
class PaystackError extends Error {
  constructor(message: string, readonly status: number) { super(message); }
}

// About 0.65 s a charge (test mode, 2026-10-30): 10 at a time for 40 s is ~600 a call.
// 60 s (~800 charges) hit the edge runtime's CPU limit locally (2026-10-31, scale.mjs), and
// a call cut off leaves its charges claimed for 10 minutes. A charge started at the
// budget's end can take 30 s plus 30 s to verify: 100 s, and the refunds before them 10 s plus one
// slow refund (30 s): 140 s at most, inside the 150 s a call may run.
const RUN_PARALLEL = 10;
const RUN_BUDGET_MS = 40_000;
// Refunds asked again first, one at a time (a few a day): 10 s, then the charges' 40 s.
const REFUND_BUDGET_MS = 10_000;

async function paystack<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  const what = `paystack ${path.split("/").slice(0, 3).join("/")}`;
  const res = await fetch(PAYSTACK + path, {
    method,
    headers: { Authorization: `Bearer ${SECRET}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(30_000),
  }).catch((e) => { throw new PaystackError(`${what}: ${e instanceof Error ? e.message : e}`, 0); });
  const out = await res.json().catch(() => ({}));
  if (!res.ok || out.status !== true) throw new PaystackError(`${what} ${res.status}: ${out.message ?? ""}`, res.status);
  return out.data as T;
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}

/** A card change's R1, or a payment that applied nothing, goes back at once (0120, 0128).
 *  A refused refund is logged on the charge; the daily run asks again (0130). */
async function refund(reference: string) {
  const err = await paystack("POST", "/refund", { transaction: reference }).then(() => null, (e) => e.message as string);
  if (err) console.error(`billing refund ${reference}: ${err}`);
  await rpc("billing_charge_refunded", { p_reference: reference, p_error: err });
}

/** A payment with no charge to apply it to (another amount or currency, an account
 *  deleted) goes back at once. Paystack resends its events, and a second refund of one
 *  payment is refused (400 "A refund already exist"): logged, so the webhook answers 200.
 *  Any other error is thrown: the webhook answers 500 and Paystack sends the event again (0132). */
const refundNow = (reference: string) => paystack("POST", "/refund", { transaction: reference })
  .then(() => {}, (e) => {
    if (!(e instanceof PaystackError) || e.status !== 400) throw e;
    console.error(`billing refund ${reference}: ${e.message}`);
  });

/** Mark a charge failed (0116) and count it, by user id only (SOLAR-243). A charge
 *  already settled ("again") was counted the first time; a card page left without trying a
 *  card is not a decline (declined false, SOLAR-338). A failed count never stops the report. */
async function chargeFailed(reference: string, error: string, renewal: boolean, declined = true) {
  const r = await rpc<{ status?: string; kind?: string; applied?: boolean; again?: boolean }>("billing_charge_failed",
    { p_reference: reference, p_error: error });
  if (declined && r?.status === "failed" && !r.again) {
    const user = await rpc<string | null>("billing_charge_user", { p_reference: reference }).catch(() => null);
    if (user) await track("payment_failed", user, reference, new Date().toISOString(), { renewal });
  }
  return r;
}

/** Report a Paystack transaction back to 0116. Paid, failed, still open (null), or "refund":
 *  paid after the account changed, so nothing applied and the money goes back (0127, 0128).
 *  `out.kind`: the paid charge's kind, for /verify. */
async function settle(tx: Tx, out: { kind?: string } = {}, renewal = false): Promise<"paid" | "failed" | "refund" | null> {
  if (tx.status === "success" && tx.currency !== "ZAR") {
    console.error(`billing ${tx.reference}: paid in ${tx.currency}, not ZAR: not applied, refunding`);
    await refundNow(tx.reference);
    return "refund";
  }
  if (tx.status === "success" && tx.currency === "ZAR") {
    // The email Paystack saved the card under: a renewal charges the card with it. The
    // price is judged on the day Paystack took the money (0130).
    const { data: r, error } = await db.rpc("billing_charge_paid", {
      p_reference: tx.reference, p_card: tx.authorization ?? null, p_cents: tx.amount,
      p_email: tx.customer?.email ?? null, p_paid_at: tx.paid_at ?? null,
    }) as { data: { kind?: string; refund?: boolean; applied?: boolean } | null; error: { message: string } | null };
    if (error && /^paid \d+ cents, charge is/.test(error.message)) {
      // Another amount than the charge: never ours to keep, so it goes back.
      console.error(`billing ${tx.reference}: ${error.message}: refunding`);
      await refundNow(tx.reference);
      return "refund";
    }
    if (error) throw new Error(`billing_charge_paid: ${error.message}`);
    out.kind = r?.kind;
    if (r?.applied === false) {
      // refund false: Paystack has the refund already (a replay, or refunded before it was reported).
      if (r.refund !== false) {
        console.error(`billing ${tx.reference}: paid after the account changed, not applied: refunding`);
        await refund(tx.reference);
      }
      return "refund";
    }
    if (r?.kind === "card" && r.refund) await refund(tx.reference);
    // A first payment from Free after the "come back" email (SOLAR-328, 0144). Only a
    // count: a failure here never stops the payment being reported.
    if (r?.kind === "start") {
      const { data: w } = await db.rpc("winback_return", { p_reference: tx.reference }).maybeSingle<{ user_id: string; email_id: number; days: number; at: string }>();
      if (w) await track("winback_resubscribed_done", w.user_id, String(w.email_id), w.at, { days: w.days });
    }
    return "paid";
  }
  // Reversed: refunded. A card change's R1 goes back on purpose, often before the
  // user's /verify (the webhook came first); 0120 answers that it was paid.
  if (["failed", "abandoned", "reversed", "reversal-pending"].includes(tx.status)) {
    const r = await chargeFailed(tx.reference, tx.gateway_response || tx.status, renewal, tx.status === "failed");
    if (r?.status === "paid") { out.kind = r.kind; return r.applied === false ? "refund" : "paid"; }
    return "failed";
  }
  return null; // pending, ongoing, send_otp...: the webhook settles it
}

/** Charge a saved card. A refused card is a failed charge, not an error. Safe to call
 *  again with the same reference: Paystack refuses a reused one (400 "Duplicate
 *  Transaction Reference"), and the first try's outcome is read back instead.
 *  `run`: a renewal, handed out again by the next run, so a charge with no clear answer
 *  stays open. Otherwise the user is on the page and is sent to the card page. */
async function chargeCard(c: { reference: string; amount: number; card: string; email: string }, run = false) {
  let err!: PaystackError;
  try {
    const tx = await paystack<Tx>("POST", "/transaction/charge_authorization", {
      authorization_code: c.card, email: c.email, amount: c.amount * 100, currency: "ZAR", reference: c.reference,
    });
    return await settle(tx, {}, run);
  } catch (e) {
    if (!(e instanceof PaystackError)) throw e;
    err = e;
  }
  // A timeout can still have taken the money, and a reused reference was charged
  // before: ask Paystack before calling it failed.
  let tx: Tx | null = null;
  try {
    tx = await paystack<Tx>("GET", `/transaction/verify/${encodeURIComponent(c.reference)}`);
  } catch (e) {
    // No such transaction (400 "Transaction reference not found."): failed only when
    // Paystack refused the charge with a 400 (a dead card, "Email does not match
    // Authorization code"). No answer, 401 (our key), 429 or 5xx: nothing charged yet,
    // left open; the next run hands a renewal out again.
    const none = e instanceof PaystackError && e.status === 400;
    if (run && (!none || err.status !== 400)) {
      console.error(`billing charge ${c.reference}: ${err.message}; left open`);
      return null;
    }
  }
  if (tx) return await settle(tx, {}, run); // null: still open, the webhook settles it
  await chargeFailed(c.reference, err.message, run);
  return "failed" as const;
}

async function signedInUser(req: Request) {
  const auth = req.headers.get("authorization") ?? "";
  const jwt = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!jwt) return null;
  const { data, error } = await db.auth.getUser(jwt);
  return error || !data?.user ? null : data.user;
}

serve("billing", async (req) => {
  const route = new URL(req.url).pathname.split("/").pop();
  const origin = req.headers.get("origin");
  const cors = corsHeaders(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405, cors);
  if (!SECRET) return json({ error: "payments not set up" }, 503, cors);

  if (route === "webhook") {
    // Signed with the secret key over the raw body (Paystack docs, "Verify event origin").
    const raw = await req.text();
    const want = createHmac("sha512", SECRET).update(raw).digest();
    const got = Buffer.from(req.headers.get("x-paystack-signature") ?? "", "hex");
    if (got.length !== want.length || !timingSafeEqual(got, want)) return json({ error: "bad signature" }, 401);
    const ev = JSON.parse(raw);
    const event = String(ev.event ?? "");
    // Only our own references; Paystack may send events for payments made elsewhere.
    try {
      const paid = String(ev.data?.reference ?? "");
      if (event === "charge.success" && paid.startsWith("psh_")) {
        try {
          await settle(ev.data as Tx);
        } catch (e) {
          if (!/unknown reference/.test(e instanceof Error ? e.message : String(e))) throw e;
          // Our reference with no charge row: the account was deleted. Not ours to keep.
          console.error(`billing webhook ${paid}: paid for no charge we hold: refunding`);
          await refundNow(paid);
        }
      }
      // refund.pending, .processing, .processed, .failed: data is the refund, naming the
      // payment in transaction_reference (as GET /refund answers). Refunds made by hand in
      // the dashboard come this way too.
      const refunded = String(ev.data?.transaction_reference ?? "");
      if (event.startsWith("refund.") && refunded.startsWith("psh_")) {
        const status = event.slice("refund.".length);
        if (status === "failed") console.error(`billing refund ${refunded} failed: ${ev.data?.reason ?? ""}`);
        // Paystack sends amount as a string ("10000", in cents) in its samples.
        const cents = Number(ev.data?.amount);
        const id = ev.data?.id ?? ev.data?.refund_reference;
        await rpc("billing_charge_refund_event", {
          p_reference: refunded, p_status: status, p_reason: ev.data?.reason ?? null,
          p_cents: Number.isSafeInteger(cents) && cents > 0 ? cents : null, p_refund: id != null ? String(id) : null,
        });
      }
      // charge.dispute.create, .remind, .resolve. Lost: resolved with money given back to the
      // customer (refund_amount above 0, or the merchant accepted it); 0130 treats it as an
      // unpaid renewal. Paystack's resolve payload is not seen live yet: check the first one.
      const disputed = String(ev.data?.transaction?.reference ?? "");
      if (event.startsWith("charge.dispute.") && disputed.startsWith("psh_")) {
        const status = String(ev.data?.status ?? "");
        const back = Number(ev.data?.refund_amount);
        const lost = event === "charge.dispute.resolve"
          && (status === "lost" || ev.data?.resolution === "merchant-accepted" || (Number.isFinite(back) && back > 0));
        console.error(`billing dispute ${disputed}: ${event} ${status} ${ev.data?.resolution ?? ""}${lost ? " (lost)" : ""}`);
        await rpc("billing_charge_disputed", {
          p_reference: disputed, p_status: status || event.slice("charge.dispute.".length), p_lost: lost,
          p_cents: Number.isSafeInteger(back) && back > 0 ? back : null,
        });
      }
    } catch (e) {
      console.error(`billing webhook ${event}: ${e instanceof Error ? e.message : e}`);
      return json({ error: "not recorded" }, 500);
    }
    return json({ ok: true }, 200);
  }

  if (route === "run") {
    const deny = denyUnlessServer(req);
    if (deny) return deny;
    // Refunds Paystack refused, or never asked for: once more, first and on a budget of
    // their own, so a busy renewal day does not leave them waiting (0132).
    const refundsStart = Date.now();
    let refunds = 0;
    for (const ref of await rpc<string[]>("billing_refunds_due", {})) {
      if (Date.now() - refundsStart >= REFUND_BUDGET_MS) break;
      await refund(ref);
      refunds++;
    }
    const start = Date.now();
    const due = await rpc<{ reference: string; amount: number; card: string; email: string }[]>("billing_run", {});
    const out = { due: due.length, charged: 0, paid: 0, failed: 0, refund: 0, open: 0, left: 0 };
    let next = 0;
    // Each worker takes the next charge until none are left or the budget is spent. A
    // charge left open (no answer, or a database error) stays claimed for 10 minutes.
    const worker = async () => {
      while (next < due.length && Date.now() - start < RUN_BUDGET_MS) {
        const c = due[next++];
        out.charged++;
        const r = await chargeCard(c, true).catch((e) => {
          console.error(`billing run ${c.reference}: ${e instanceof Error ? e.message : e}`);
          return null;
        });
        out[r ?? "open"]++;
      }
    };
    await Promise.all(Array.from({ length: RUN_PARALLEL }, worker));
    const left = due.slice(next).map((c) => c.reference);
    if (left.length) await rpc("billing_run_release", { p_refs: left });
    out.left = left.length;
    return json({ ...out, refunds }, 200);
  }

  const user = await signedInUser(req);
  if (!user) return json({ error: "sign in first" }, 401, cors);
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "body must be JSON" }, 400, cors);
  }

  if (route === "verify") {
    const ref = String(body.reference ?? "");
    if (!ref.startsWith("psh_")) return json({ error: "unknown reference" }, 400, cors);
    // Only the user who opened the charge hears about it.
    if (await rpc<string | null>("billing_charge_user", { p_reference: ref }) !== user.id) return json({ error: "unknown reference" }, 400, cors);
    const tx = await paystack<Tx>("GET", `/transaction/verify/${encodeURIComponent(ref)}`);
    const paid: { kind?: string } = {};
    const status = await settle(tx, paid);
    return json({ status: status ?? "pending", kind: paid.kind ?? null }, 200, cors);
  }

  if (route !== "pay") return json({ error: "not found" }, 404, cors);
  if (payClosed(SECRET, SUPABASE_URL, TEST_USERS, user.id)) return json({ error: "paid plans open soon" }, 503, cors);
  // The card page sends the user back here; only an allowed app origin.
  if (!origin || !cors["Access-Control-Allow-Origin"]) return json({ error: "origin not allowed" }, 403, cors);

  // Settle and card change always go to the card page: a new card is the point.
  const fresh = body.settle === true || body.card === true;
  const { data: open, error } = body.settle === true
    ? await db.rpc("billing_settle_open", { p_user: user.id })
    : body.card === true
    ? await db.rpc("billing_card_open", { p_user: user.id })
    : await db.rpc("billing_charge_open", {
      p_user: user.id, p_plan: String(body.plan ?? ""),
      p_period: body.period ? String(body.period) : null,
      // extras: the extra plants wanted on Family in all (SOLAR-264); left out, those held
      p_extra: Number.isSafeInteger(body.extras) ? body.extras : null,
      // plants: the stopped plants the room is for; they start first once paid (0130)
      p_plants: Array.isArray(body.plants) ? body.plants.filter(Number.isSafeInteger) : null,
    });
  // 22023: a refused change ("settle the failed payment first", ...): say why.
  if (error) return json({ error: error.message }, error.code === "22023" ? 409 : 500, cors);
  const o = open as { reference: string; amount: number; email?: string; card?: string | null; cardEmail?: string };
  if (o.amount === 0) return json({ status: "paid", reference: o.reference }, 200, cors);

  if (o.card && body.newCard !== true && !fresh) {
    const r = await chargeCard({ reference: o.reference, amount: o.amount, card: o.card, email: o.cardEmail ?? o.email ?? user.email ?? "" });
    return json({ status: r ?? "pending", reference: o.reference }, 200, cors);
  }
  try {
    const page = await paystack<{ authorization_url: string }>("POST", "/transaction/initialize", {
      email: o.email ?? user.email, amount: o.amount * 100, currency: "ZAR", reference: o.reference,
      channels: ["card"], callback_url: `${origin}/?tab=account&section=plan`,
    });
    return json({ url: page.authorization_url, reference: o.reference }, 200, cors);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`billing pay ${o.reference}: ${msg}`);
    await rpc("billing_charge_failed", { p_reference: o.reference, p_error: msg });
    return json({ error: "could not reach Paystack" }, 502, cors);
  }
});
