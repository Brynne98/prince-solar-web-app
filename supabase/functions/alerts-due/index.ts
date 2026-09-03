// Returns api_alerts_due() for the todo app's solar-alerts sender.
//
// PostgREST on this project rejects the secret key from outside, and the
// legacy JWT is disabled, so the todo app cannot call the RPC directly.
// This function uses the platform-injected service role, which already
// works for poll / recover. Auth is a shared bearer token, not a JWT —
// verify_jwt is off for this function only.
import { bootstrapPlantId, db } from "../_shared/sunsynk.ts";

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  const expected = Deno.env.get("ALERTS_TOKEN") ?? "";
  const got = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  if (!expected || got !== expected) return json({ error: "unauthorized" }, 401);

  // Alerts are delivered to one phone, so they watch one plant: the first linked.
  const plant = await bootstrapPlantId();
  if (plant == null) return json([]);
  const { data, error } = await db.rpc("api_alerts_due", { p_plant: plant });
  if (error) return json({ error: error.message }, 500);
  return json(data ?? []);
});
