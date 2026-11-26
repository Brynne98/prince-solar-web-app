// `link` — connect a brand login (the brand Connect first) to the signed-in dashboard user. reuse-check: allow
//
// The browser POSTs { username, password } with the user's Supabase JWT. This
// function exchanges the credentials for tokens via the official API, stores the
// refresh token in Vault, records which plants the user may now see, and returns
// those plants. The password exists in memory for the duration of one outbound
// request and is never logged, stored or echoed.
//
// This is the only place a the brand password ever touches the backend. Keep it that
// way: no console.log of the body, no error message that includes input.
import { db } from "../_shared/db.ts";
import { brandForUsername, brandOf, LoginRejected, saveAllCalls } from "../_shared/brands/index.ts";
import { linkAccount } from "../_shared/plants.ts";
import { noteError, serve, track } from "../_shared/errors.ts";
import { corsHeaders, json } from "../_shared/cors.ts";
import { mockClosed } from "../_shared/gate.ts";
import { billingState, loginName, Refused, type Rpc, saveLogin, saveLoginLive } from "../_shared/links.ts";

serve("link", async (req) => {
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
    username = loginName(body?.username);
    password = String(body?.password ?? "");
  } catch {
    return json({ error: "body must be JSON" }, 400, cors);
  }
  if (!username || !password) return json({ error: "username and password are required" }, 400, cors);
  // the brand's name in the answers the screen shows (the screen matches their words, link.jsx)
  const brandName = brandOf(brandForUsername(username)).displayName;
  // A fake login (SOLAR-270) answers as the brand would to a wrong one, except for testers.
  const confirmedEmail = userData.user.email_confirmed_at ? userData.user.email ?? "" : "";
  if (mockClosed(username, Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("TESTER_USERS") ?? "", userId,
    Deno.env.get("TESTER_EMAIL_PATTERN") ?? "", confirmedEmail)) {
    return json({ error: `${brandName} rejected those credentials` }, 401, cors);
  }

  // At most 5 failed the brand logins per user per hour (0107, 0135), so one user can't get the
  // function's address blocked by the brand. Refuse if the count can't be read.
  const { data: allowed, error: limitErr } = await db.rpc("link_attempt", { p_user: userId });
  if (limitErr) {
    console.error(`link limit check failed for user ${userId}: ${limitErr.message}`);
    noteError("limit_check_failed", new Error(`link_attempt: ${limitErr.message}`), { user: userId });
    return json({ error: `could not reach ${brandName}` }, 502, cors);
  }
  if (!allowed) return json({ error: "too many attempts" }, 429, { ...cors, "Retry-After": "3600" });

  // One login in the free week, none without a plan (billing.account_state may_add_login, 0247),
  // asked before the brand is. Before the billing switch-over the old rule (0203) still decides.
  // A login already on the account (a new password, a reconnect) always goes through.
  const call: Rpc = (fn, args) => db.rpc(fn, args);
  let acct;
  try {
    acct = await billingState(call, userId, username);
  } catch (e) {
    noteError("link_state_failed", e, { user: userId });
    return json({ error: `could not reach ${brandName}` }, 502, cors);
  }
  const live = !!acct?.live;
  if (live) {
    if (!acct.may_add_login && !acct.login_known) return json({ error: acct.state === "ended" ? "no plan" : "one login" }, 409, cors);
  } else {
    const { data: oneLogin, error: oneErr } = await db.rpc("link_login_allowed", { p_user: userId, p_username: username });
    if (!oneErr && oneLogin === false) return json({ error: "one login" }, 409, cors);
  }

  try {
    // Live: one transaction stores the login and lets the locked link_login decide before any
    // plant is linked; a refusal or failure leaves no login behind.
    const { accountId, plants, paused, reason } = await linkAccount(userId, username, password,
      live ? (token, ps) => saveLoginLive(call, userId, username, token, ps) : undefined, brandForUsername(username));
    password = ""; // done with it
    // A good link gives its try back, so only failed tries count (0135).
    const { error: refundErr } = await db.rpc("link_succeeded", { p_user: userId });
    if (refundErr) {
      console.error(`link refund failed for user ${userId}: ${refundErr.message}`);
      noteError("try_refund_failed", new Error(`link_succeeded: ${refundErr.message}`), { user: userId });
    }
    // Before the switch: the login and its plant list copied into the new tables (SOLAR-641).
    if (!live) await saveLogin(call, false, noteError, userId, accountId, username, plants);
    // SOLAR-319: a login added after the "need a hand" email went. Keyed on the email, so it counts once.
    // sent_at, not status: an email sent through the message outbox keeps status 'outbox' (0263).
    const { data: hand } = await db.from("email_queue").select("id, sent_at")
      .eq("user_id", userId).eq("kind", "need_a_hand").not("sent_at", "is", null).maybeSingle();
    if (hand) {
      await track("need_a_hand_login_linked_done", userId, String(hand.id), new Date().toISOString(),
        { hours: Math.round((Date.now() - Date.parse(hand.sent_at)) / 3_600_000) });
    }
    // SOLAR-584: how many of the plants had a free week before this account was made and
    // no other account holds now (an account deleted and made again). A count only.
    if (plants.length) {
      const { data: seen } = await db.rpc("plants_seen_before", { p_user: userId, p_plants: plants.map((p) => p.id) });
      await track("plants_linked_done", userId, `${accountId}:${Date.now()}`, new Date().toISOString(),
        { via: "login", count: plants.length, seen_before: seen ?? 0 });
    }
    if (!plants.length) {
      // Linked, but the brand returned no plants: the login works but sees nothing —
      // typical when the installer owns the plant and hasn't shared it yet.
      return json({ ok: true, accountId, plants, paused, warning: `no plants visible on this ${brandName} account` }, 200, cors);
    }
    // paused: plants linked but not on the plan; reason says why (upgrade_needed).
    return json({ ok: true, accountId, plants, paused, reason }, 200, cors);
  } catch (e) {
    password = "";
    if (e instanceof Refused) return json({ error: e.answer }, 409, cors);
    const msg = e instanceof Error ? e.message : String(e);
    // LoginRejected comes from tokenLogin and contains only the brand's msg.
    const status = e instanceof LoginRejected ? 401 : 502;
    console.error(`link failed for user ${userId}: ${msg}`);
    // A wrong password is the user's own, not a fault.
    if (status === 502) noteError("link_failed", e, { user: userId });
    return json({ error: status === 401 ? `${brandName} rejected those credentials` : `could not reach ${brandName}` }, status, cors);
  } finally {
    await saveAllCalls();
  }
});
