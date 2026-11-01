// Fake SunSynk for the tester account in production (SOLAR-270): the local mock behind a
// function. Only logins ending in @mock reach it (_shared/sunsynk.ts), and link-sunsynk
// lets only PAYSTACK_TEST_USERS link one. Plant ids move up by ID_OFFSET so a fake plant
// never shares an id with a real SunSynk plant. Fake data only; no secrets, no database.
import { handle } from "../_shared/mock-sunsynk.mjs";

const ID_OFFSET = 900_000_000;

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*?\/mock-sunsynk/, "") || "/";
  const body = req.method === "POST" ? await req.text() : "";
  const r = handle({ method: req.method, path, query: url.searchParams, auth: req.headers.get("authorization") ?? "", body, idOffset: ID_OFFSET });
  return new Response(JSON.stringify(r.json), { status: r.status, headers: { "Content-Type": "application/json" } });
});
