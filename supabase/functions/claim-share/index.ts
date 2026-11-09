// `claim-share` — link a plant the owner shared to our SunSynk login (SOLAR-310).
//
// The browser POSTs { ref } with the user's Supabase JWT: the plant id or an inverter
// serial. claimShared() checks it live against what the share login sees, then links
// it to the user (0172 share_claim). No SunSynk password from the user, ever.
//
// Answers: 200 {result: "claimed" | "claimed_paused" | "yours", plantId, plantName},
// 404 {error: "not_shared"}, 409 {error: "taken"}, 429 too many tries. A taken plant's id
// is not sent back: a serial typed from someone else's inverter would reveal it.
import { claimShared, db } from "../_shared/sunsynk.ts";
import { serve } from "../_shared/errors.ts";
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
    return json({ error: "could not reach SunSynk" }, 502, cors);
  }
  if (!allowed) return json({ error: "too many attempts" }, 429, { ...cors, "Retry-After": "3600" });

  try {
    const r = await claimShared(userId, ref);
    if (r.result === "not_shared") return json({ error: "not_shared" }, 404, cors);
    if (r.result === "taken") return json({ error: "taken" }, 409, cors);
    const { error: refundErr } = await db.rpc("link_succeeded", { p_user: userId });
    if (refundErr) console.error(`claim-share refund failed for user ${userId}: ${refundErr.message}`);
    return json({ ok: true, ...r }, 200, cors);
  } catch (e) {
    console.error(`claim-share failed for user ${userId}: ${e instanceof Error ? e.message : e}`);
    return json({ error: "could not reach SunSynk" }, 502, cors);
  }
});
