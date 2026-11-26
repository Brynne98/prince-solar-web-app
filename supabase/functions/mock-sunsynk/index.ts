// Fake SunSynk for the tester account in production (SOLAR-270): the local mock behind a
// function. Only logins ending in @mock reach it (_shared/brands/sunsynk/api.ts), and link-sunsynk
// lets only TESTER_USERS link one (SOLAR-477). Plant ids move up by MOCK_PLANT_OFFSET so a fake plant
// never shares an id with a real SunSynk plant. Fake data only; no secrets, no database.
import { handle } from "../_shared/mock-sunsynk.mjs";
import { MOCK_PLANT_OFFSET } from "../_shared/gate.ts";

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*?\/mock-sunsynk/, "") || "/";
  const body = req.method === "POST" ? await req.text() : "";
  const r = handle({ method: req.method, path, query: url.searchParams, auth: req.headers.get("authorization") ?? "", body, idOffset: MOCK_PLANT_OFFSET });
  return new Response(JSON.stringify(r.json), { status: r.status, headers: { "Content-Type": "application/json" } });
});
