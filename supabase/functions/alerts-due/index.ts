// Returns api_alerts_due() for the todo app's solar-alerts sender.
//
// PostgREST on this project rejects the secret key from outside, and the
// legacy JWT is disabled, so the todo app cannot call the RPC directly.
// This function uses the platform-injected service role, which already
// works for poll / recover. Auth is a shared bearer token, not a JWT —
// verify_jwt is off for this function only.
import { createClient } from "jsr:@supabase/supabase-js@2";

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  const expected = Deno.env.get("ALERTS_TOKEN") ?? "";
  const got = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  if (!expected || got !== expected) return json({ error: "unauthorized" }, 401);

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { data, error } = await sb.rpc("api_alerts_due");
  if (error) return json({ error: error.message }, 500);
  return json(data ?? []);
});
