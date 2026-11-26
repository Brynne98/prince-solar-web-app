// The gateway's verify_jwt lets through the publishable key and any user's
// session, so poll / recover / sync-plant-energy check the caller themselves.
// pg_cron and plant_bootstrap_kick send the vault service_role_key, an
// sb_secret_ key; the platform injects every secret key as SUPABASE_SECRET_KEYS
// (JSON, by name). The legacy service role JWT is accepted too (local stack).
const SERVER_KEYS = new Set(
  [
    ...Object.values(JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}") as Record<string, string>),
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  ].filter((k): k is string => !!k),
);

/** 401 response unless the bearer is one of the project's server keys; null when allowed. */
export function denyUnlessServer(req: Request): Response | null {
  const got = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  if (got && SERVER_KEYS.has(got)) return null;
  return new Response(JSON.stringify({ error: "unauthorized" }), {
    status: 401,
    headers: { "Content-Type": "application/json" },
  });
}
