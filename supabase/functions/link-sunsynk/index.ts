// `link-sunsynk` — connect a SunSynk Connect login to the signed-in dashboard user.
//
// The browser POSTs { username, password } with the user's Supabase JWT. This
// function exchanges the credentials for tokens via the official API, stores the
// refresh token in Vault, records which plants the user may now see, and returns
// those plants. The password exists in memory for the duration of one outbound
// request and is never logged, stored or echoed.
//
// This is the only place a SunSynk password ever touches the backend. Keep it that
// way: no console.log of the body, no error message that includes input.
import { db, linkAccount } from "../_shared/sunsynk.ts";

// Browser origins allowed to call this. GitHub Pages in production, the two local
// dev ports otherwise. Anything else is refused at preflight.
const ALLOWED_ORIGINS = new Set([
  "https://brynne98.github.io",
  "http://localhost:3003",
  "http://localhost:3011",
  "http://127.0.0.1:3003",
]);

function corsHeaders(origin: string | null): Record<string, string> {
  const allow = origin && ALLOWED_ORIGINS.has(origin) ? origin : "";
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, content-type, apikey",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    Vary: "Origin",
  };
}

const json = (b: unknown, status: number, cors: Record<string, string>) =>
  new Response(JSON.stringify(b), {
    status,
    headers: { "Content-Type": "application/json", ...cors },
  });

Deno.serve(async (req) => {
  const cors = corsHeaders(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405, cors);

  // Who is asking? The user's own Supabase session, not the service key.
  const auth = req.headers.get("authorization") ?? "";
  const jwt = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!jwt) return json({ error: "sign in first" }, 401, cors);
  const { data: userData, error: userErr } = await db.auth.getUser(jwt);
  if (userErr || !userData?.user) return json({ error: "session invalid" }, 401, cors);
  const userId = userData.user.id;

  let username = "";
  let password = "";
  try {
    const body = await req.json();
    username = String(body?.username ?? "").trim();
    password = String(body?.password ?? "");
  } catch {
    return json({ error: "body must be JSON" }, 400, cors);
  }
  if (!username || !password) return json({ error: "username and password are required" }, 400, cors);

  try {
    const { accountId, plants } = await linkAccount(userId, username, password);
    password = ""; // done with it
    if (!plants.length) {
      // Linked, but SunSynk returned no plants: the login works but sees nothing —
      // typical when the installer owns the plant and hasn't shared it yet.
      return json({ ok: true, accountId, plants, warning: "no plants visible on this SunSynk account" }, 200, cors);
    }
    return json({ ok: true, accountId, plants }, 200, cors);
  } catch (e) {
    password = "";
    const msg = e instanceof Error ? e.message : String(e);
    // "login rejected: ..." comes from tokenLogin and contains only SunSynk's msg.
    const status = /login rejected/i.test(msg) ? 401 : 502;
    console.error(`link-sunsynk failed for user ${userId}: ${msg}`);
    return json({ error: status === 401 ? "SunSynk rejected those credentials" : "could not reach SunSynk" }, status, cors);
  }
});
