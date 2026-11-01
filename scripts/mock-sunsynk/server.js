#!/usr/bin/env node
// Mock of openapi.sunsynk.net for local development and the readiness tests. The logins,
// plants and answers live in supabase/functions/_shared/mock-sunsynk.mjs (SOLAR-270).
//
//   node scripts/mock-sunsynk/server.js            # listens on :4400
//   SUNSYNK_API_BASE=http://host.docker.internal:4400 for the local edge runtime
//
// /__calls lists the recent paths, for the tests that count SunSynk calls.
const http = require("node:http");
const PORT = Number(process.env.PORT) || 4400;
const seen = [];
function readBody(req) {
  return new Promise((resolve) => { let b = ""; req.on("data", (c) => (b += c)); req.on("end", () => resolve(b)); });
}

import("../../supabase/functions/_shared/mock-sunsynk.mjs").then(({ handle, LOGINS }) => {
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  seen.push({ t: Date.now(), path: url.pathname });
  if (seen.length > 5000) seen.splice(0, 1000);
  if (url.pathname === "/__calls") { res.writeHead(200, { "Content-Type": "application/json" }); return res.end(JSON.stringify(seen.slice(-500))); }
  const body = req.method === "POST" ? await readBody(req) : "";
  const r = handle({ method: req.method, path: url.pathname, query: url.searchParams, auth: req.headers.authorization || "", body });
  res.writeHead(r.status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(r.json));
});

server.listen(PORT, () => console.log(`mock sunsynk on :${PORT} — accounts: ${LOGINS.join(", ")}`));
});
