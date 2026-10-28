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
import { db, linkAccount, PlanRefused } from "../_shared/sunsynk.ts";
import { serve } from "../_shared/errors.ts";
import { corsHeaders, json } from "../_shared/cors.ts";

serve("link-sunsynk", async (req) => {
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
  let confirmCost: boolean | "paused" = false;
  try {
    const body = await req.json();
    username = String(body?.username ?? "").trim();
    password = String(body?.password ?? "");
    // The user saw the R49-per-inverter cost for plants past the 3rd: true takes it,
    // "paused" links those plants paused.
    confirmCost = body?.confirmCost === true ? true : body?.confirmCost === "paused" ? "paused" : false;
  } catch {
    return json({ error: "body must be JSON" }, 400, cors);
  }
  if (!username || !password) return json({ error: "username and password are required" }, 400, cors);

  // At most 5 SunSynk logins per user per hour (0107), so one user can't get the
  // function's address blocked by SunSynk. Refuse if the count can't be read.
  const { data: allowed, error: limitErr } = await db.rpc("link_attempt", { p_user: userId });
  if (limitErr) {
    console.error(`link-sunsynk limit check failed for user ${userId}: ${limitErr.message}`);
    return json({ error: "could not reach SunSynk" }, 502, cors);
  }
  if (!allowed) return json({ error: "too many attempts" }, 429, { ...cors, "Retry-After": "3600" });

  try {
    const { accountId, plants, paused, reason } = await linkAccount(userId, username, password, confirmCost);
    password = ""; // done with it
    if (!plants.length) {
      // Linked, but SunSynk returned no plants: the login works but sees nothing —
      // typical when the installer owns the plant and hasn't shared it yet.
      return json({ ok: true, accountId, plants, paused, warning: "no plants visible on this SunSynk account" }, 200, cors);
    }
    // paused: plants linked but not on the plan; reason says why (upgrade_needed, free_week_used).
    return json({ ok: true, accountId, plants, paused, reason }, 200, cors);
  } catch (e) {
    password = "";
    // A Family plant past the 3rd (SOLAR-208): the app shows the cost and sends
    // again with confirmCost true or "paused".
    if (e instanceof PlanRefused) {
      return json({ error: e.reason, extraInverters: e.extraInverters, dueNow: e.dueNow }, 402, cors);
    }
    const msg = e instanceof Error ? e.message : String(e);
    // "login rejected: ..." comes from tokenLogin and contains only SunSynk's msg.
    const status = /login rejected/i.test(msg) ? 401 : 502;
    console.error(`link-sunsynk failed for user ${userId}: ${msg}`);
    return json({ error: status === 401 ? "SunSynk rejected those credentials" : "could not reach SunSynk" }, status, cors);
  }
});
