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
import { db, linkAccount, LoginRejected, saveCallTally } from "../_shared/sunsynk.ts";
import { serve, track } from "../_shared/errors.ts";
import { corsHeaders, json } from "../_shared/cors.ts";
import { mockClosed } from "../_shared/gate.ts";

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
  try {
    const body = await req.json();
    username = String(body?.username ?? "").trim();
    password = String(body?.password ?? "");
  } catch {
    return json({ error: "body must be JSON" }, 400, cors);
  }
  if (!username || !password) return json({ error: "username and password are required" }, 400, cors);
  // A fake login (SOLAR-270) answers as SunSynk would to a wrong one, except for testers.
  if (mockClosed(username, Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("PAYSTACK_TEST_USERS") ?? "", userId)) {
    return json({ error: "SunSynk rejected those credentials" }, 401, cors);
  }

  // At most 5 failed SunSynk logins per user per hour (0107, 0135), so one user can't get the
  // function's address blocked by SunSynk. Refuse if the count can't be read.
  const { data: allowed, error: limitErr } = await db.rpc("link_attempt", { p_user: userId });
  if (limitErr) {
    console.error(`link-sunsynk limit check failed for user ${userId}: ${limitErr.message}`);
    return json({ error: "could not reach SunSynk" }, 502, cors);
  }
  if (!allowed) return json({ error: "too many attempts" }, 429, { ...cors, "Retry-After": "3600" });

  try {
    const { accountId, plants, paused, reason } = await linkAccount(userId, username, password);
    password = ""; // done with it
    // A good link gives its try back, so only failed tries count (0135).
    const { error: refundErr } = await db.rpc("link_succeeded", { p_user: userId });
    if (refundErr) console.error(`link-sunsynk refund failed for user ${userId}: ${refundErr.message}`);
    // SOLAR-319: a login added after the "need a hand" email went. Keyed on the email, so it counts once.
    const { data: hand } = await db.from("email_queue").select("id, sent_at")
      .eq("user_id", userId).eq("kind", "need_a_hand").eq("status", "sent").maybeSingle();
    if (hand) {
      await track("need_a_hand_login_linked_done", userId, String(hand.id), new Date().toISOString(),
        { hours: Math.round((Date.now() - Date.parse(hand.sent_at)) / 3_600_000) });
    }
    if (!plants.length) {
      // Linked, but SunSynk returned no plants: the login works but sees nothing —
      // typical when the installer owns the plant and hasn't shared it yet.
      return json({ ok: true, accountId, plants, paused, warning: "no plants visible on this SunSynk account" }, 200, cors);
    }
    // paused: plants linked but not on the plan; reason says why (upgrade_needed).
    return json({ ok: true, accountId, plants, paused, reason }, 200, cors);
  } catch (e) {
    password = "";
    const msg = e instanceof Error ? e.message : String(e);
    // LoginRejected comes from tokenLogin and contains only SunSynk's msg.
    const status = e instanceof LoginRejected ? 401 : 502;
    console.error(`link-sunsynk failed for user ${userId}: ${msg}`);
    return json({ error: status === 401 ? "SunSynk rejected those credentials" : "could not reach SunSynk" }, status, cors);
  } finally {
    await saveCallTally();
  }
});
