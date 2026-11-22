// `claim-share` — link a plant the owner shared to our SunSynk login (SOLAR-310).
//
// The browser POSTs { ref } with the user's Supabase JWT: the plant id or an inverter
// serial. claimShared() checks it live against what the share login sees, then links
// it to the user (0172 share_claim). No SunSynk password from the user, ever.
//
// Answers: 200 {result: "claimed" | "claimed_paused" | "yours", plantId, plantName},
// 404 {error: "not_shared"}, 409 {error: "taken"}, 429 too many tries. A taken plant's id
// is not sent back: a serial typed from someone else's inverter would reveal it.
import { claimShared, db, saveCallTally } from "../_shared/sunsynk.ts";
import { noteError, serve, track } from "../_shared/errors.ts";
import { corsHeaders, json } from "../_shared/cors.ts";

serve("claim-share", async (req) => {
  const cors = corsHeaders(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405, cors);

  const auth = req.headers.get("authorization") ?? "";
  const jwt = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!jwt) return json({ error: "sign in first" }, 401, cors);
  const { data: userData, error: userErr } = await db.auth.getUser(jwt);
  if (userErr || !userData?.user) return json({ error: "session invalid" }, 401, cors);
  const userId = userData.user.id;

  let ref = "";
  try {
    ref = String((await req.json())?.ref ?? "").replace(/\s+/g, "");
  } catch {
    return json({ error: "body must be JSON" }, 400, cors);
  }
  if (!/^[A-Za-z0-9]{4,32}$/.test(ref)) return json({ error: "ref required" }, 400, cors);

  // The same 5 failed tries an hour as a password link (0107, 0135), so nobody can
  // walk plant ids or serials to find shared plants. A claim gives its try back.
  const { data: allowed, error: limitErr } = await db.rpc("link_attempt", { p_user: userId });
  if (limitErr) {
    console.error(`claim-share limit check failed for user ${userId}: ${limitErr.message}`);
    noteError("limit_check_failed", new Error(`link_attempt: ${limitErr.message}`), { user: userId });
    return json({ error: "could not reach SunSynk" }, 502, cors);
  }
  if (!allowed) return json({ error: "too many attempts" }, 429, { ...cors, "Retry-After": "3600" });

  try {
    const r = await claimShared(userId, ref);
    if (r.result === "not_shared") return json({ error: "not_shared" }, 404, cors);
    if (r.result === "taken") return json({ error: "taken" }, 409, cors);
    // The new account tables (SOLAR-641): the claim, first claim wins.
    if (r.result !== "yours") {
      const { error: newErr } = await db.rpc("billing_links", { p_cmd: "claim_plant", p_args: { user: userId, plant: r.plantId, name: r.plantName } });
      if (newErr) noteError("claim_plant_failed", new Error(`claim_plant: ${newErr.message}`), { user: userId, plant: r.plantId });
    }
    const { error: refundErr } = await db.rpc("link_succeeded", { p_user: userId });
    if (refundErr) {
      console.error(`claim-share refund failed for user ${userId}: ${refundErr.message}`);
      noteError("try_refund_failed", new Error(`link_succeeded: ${refundErr.message}`), { user: userId });
    }
    // SOLAR-584: the plant had a free week before this account was made, and nobody holds it now.
    const { data: seen } = await db.rpc("plants_seen_before", { p_user: userId, p_plants: [r.plantId] });
    await track("plants_linked_done", userId, `${r.plantId}:${Date.now()}`, new Date().toISOString(),
      { via: "share", count: 1, seen_before: seen ?? 0 });
    return json({ ok: true, ...r }, 200, cors);
  } catch (e) {
    console.error(`claim-share failed for user ${userId}: ${e instanceof Error ? e.message : e}`);
    noteError("claim_failed", e, { user: userId });
    return json({ error: "could not reach SunSynk" }, 502, cors);
  } finally {
    await saveCallTally();
  }
});
