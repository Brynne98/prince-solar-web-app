// Browser origins allowed to call link-sunsynk and billing. app.princesolarhub.co.za in
// production, the two local dev ports otherwise. Anything else is refused at preflight. A custom domain is
// added with the LINK_ALLOWED_ORIGINS secret (comma-separated), no redeploy of code:
//   supabase secrets set LINK_ALLOWED_ORIGINS=https://app.example.com,https://example.com
const DEFAULT_ORIGINS = [
  "https://app.princesolarhub.co.za",
  // Until the .com 301 is live (SOLAR-190).
  "https://app.princesolarhub.com",
  "http://localhost:3003",
  "http://localhost:3011",
  "http://127.0.0.1:3003",
];
export const ALLOWED_ORIGINS = new Set([
  ...DEFAULT_ORIGINS,
  ...(Deno.env.get("LINK_ALLOWED_ORIGINS") ?? "").split(",").map((o) => o.trim()).filter(Boolean),
]);

export function corsHeaders(origin: string | null): Record<string, string> {
  const allow = origin && ALLOWED_ORIGINS.has(origin) ? origin : "";
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, content-type, apikey",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    Vary: "Origin",
  };
}

export const json = (b: unknown, status: number, cors: Record<string, string> = {}) =>
  new Response(JSON.stringify(b), {
    status,
    headers: { "Content-Type": "application/json", ...cors },
  });
