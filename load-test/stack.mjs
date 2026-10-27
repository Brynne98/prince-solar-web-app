// SOLAR-210 load test helpers on the host, two ports:
//   :4400   fake SunSynk for the load-test fleet. Login ltK owns plant 900000+K with
//           inverters LT<plant>A and LT<plant>B (load-test/setup.sql makes the same
//           fleet in the database). Every reply waits LATENCY_MS, like the real API.
//   :54400  /rest/v1/* passed to PostgREST on :54401, the path supabase-js uses.
//
//   LATENCY_MS=300 node load-test/stack.mjs
import http from "node:http";

const LATENCY_MS = Number(process.env.LATENCY_MS ?? 300);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let calls = 0;

function sastNow() {
  const d = new Date(Date.now() + 2 * 3600_000);
  return d.toISOString().slice(0, 16).replace("T", " ") + ":00";
}

function realtime(sn, kind) {
  const time = sastNow();
  const hour = Number(time.slice(11, 13)) + Number(time.slice(14, 16)) / 60;
  const pv = Math.max(0, Math.round(5000 * Math.sin(Math.PI * (hour - 6) / 12)));
  const load = 1200 + Math.round(Math.random() * 300);
  const vip = (p) => [{ volt: 230, current: Math.round(p / 230 * 100) / 100, power: p }];
  switch (kind) {
    case "input": return {
      pac: pv, etoday: 10, etotal: 9800,
      pvIV: [1, 2].map((no) => ({ pvNo: no, vpv: pv ? 330 : 1.2, ipv: pv / 2 / 330, ppv: pv / 2, todayPv: 5, sn, time })),
      mpptIV: [],
    };
    case "grid": return { pac: 200, fac: 50, pf: 1, qac: 0, etodayFrom: 2, etodayTo: 0, etotalFrom: 4200, etotalTo: 0, acRealyStatus: "1", status: 1, vip: vip(200) };
    case "battery": return {
      power: 800 - pv / 3, soc: 60, voltage: 52, current: -10, temp: 27, capacity: 200, numberOfBatteries: 1,
      etodayChg: 3, etodayDischg: 4, etotalChg: 3100, etotalDischg: 2900, type: "Lithium", status: 1,
    };
    case "load": return { totalPower: load, dailyUsed: 15, totalUsed: 12000, loadFac: 50, vip: vip(load), upsPowerL1: load };
    case "output": return { pac: load, pInv: pv, fac: 50, vip: vip(load) };
  }
}

const reply = (res, data, status = 200) => {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(status === 200 ? { code: 0, msg: "Success", success: true, data } : { code: status, msg: data, success: false, data: null }));
};
const page = (list, q) => {
  const limit = Number(q.get("limit")) || 20, pg = Math.max(1, Number(q.get("page")) || 1);
  return { pageSize: limit, pageNumber: pg, total: list.length, infos: list.slice((pg - 1) * limit, pg * limit) };
};

http.createServer(async (req, res) => {
  calls++;
  await sleep(LATENCY_MS);
  const url = new URL(req.url, "http://x");
  const path = url.pathname, q = url.searchParams;
  const user = (req.headers.authorization || "").replace(/^Bearer\s+(at:)?/i, "");
  const k = Number(/^lt(\d+)$/.exec(user)?.[1]);
  if (!k) return reply(res, "unauthorized", 401);
  const pid = 900000 + k;
  const sns = [`LT${pid}A`, `LT${pid}B`];
  let m;
  if (path === "/plants") return reply(res, page([{ id: pid, name: `Load test ${k}` }], q));
  if ((m = /^\/plant\/(\d+)$/.exec(path))) {
    return reply(res, { id: pid, name: `Load test ${k}`, timezone: { code: "Africa/Johannesburg" }, currency: { code: "ZAR" }, totalPower: 10 });
  }
  if (path === "/inverters") {
    return reply(res, page(sns.map((sn, i) => ({
      sn, alias: sn, plant: { id: pid, name: `Load test ${k}` }, model: "SUN-8K", equipModel: "SUN-8K", status: 1,
      gsn: `E${sn}`, version: { softVer: "1", hmiVer: "1" }, commTypeName: "WiFi", ord: i,
    })), q));
  }
  if ((m = /^\/inverter\/([A-Z0-9]+)\/realtime\/(input|output)$/.exec(path))) return reply(res, realtime(m[1], m[2]));
  if ((m = /^\/inverter\/(grid|battery|load)\/([A-Z0-9]+)\/realtime$/.exec(path))) return reply(res, realtime(m[2], m[1]));
  return reply(res, `no route for ${path}`, 404);
}).listen(4400);

// supabase-js calls <url>/rest/v1/<x>; PostgREST serves /<x>.
http.createServer((req, res) => {
  const up = http.request({
    host: "127.0.0.1", port: 54401, method: req.method, headers: req.headers,
    path: req.url.replace(/^\/rest\/v1/, ""),
  }, (r) => { res.writeHead(r.statusCode, r.headers); r.pipe(res); });
  up.on("error", (e) => { res.writeHead(502); res.end(String(e)); });
  req.pipe(up);
}).listen(54400);

setInterval(() => { if (calls) console.log(`${new Date().toISOString()} sunsynk calls ${calls}`); calls = 0; }, 60_000);
console.log(`fake SunSynk :4400 (latency ${LATENCY_MS} ms), /rest/v1 proxy :54400`);
