// `billing` — takes money through Paystack (SOLAR-208, rebuilt for SOLAR-641). Every rule
// lives in the database (migrations 0240-0245, schema `billing`, reached through
// public.billing_v2); this only talks to Paystack and reports each answer back.
//
//   POST /billing/pay      the signed-in user, { plan, period?, extras?, plants, newCard? }:
//                          a first plan or a restart (start_checkout) when no plan runs, else
//                          an upgrade. { settle: true } pays the open renewal bill now;
//                          { card: true } checks a new card (Paystack's minimum, refunded).
//                          Charges the saved card when there is one; otherwise answers { url }
//                          for Paystack's card page, which comes back with ?reference=.
//   POST /billing/change   the signed-in user, { action: downgrade | interval | cancel |
//                          undo_cancel, plan?, extras?, drop?, period? }: booked for the next
//                          billing date. Answers account_state.
//   POST /billing/verify   the signed-in user, { reference }: asks Paystack about that try.
//   POST /billing/webhook  Paystack's notice of a payment, refund or dispute (HMAC-signed).
//                          Stored first (deduped on type, entity and status); answers non-2xx
//                          when it could not be processed, so Paystack sends it again.
//   POST /billing/run      pg_cron: the daily job (billing.run). Tries whose lease ran out
//                          are verified first, then the due charges, RUN_PARALLEL at a time for
//                          RUN_BUDGET_MS, then refunds owed or failed before.
//
// verify_jwt is off: Paystack has no Supabase session. Each route checks its caller.
// Secret: PAYSTACK_SECRET_KEY.
import { db, denyUnlessServer } from "../_shared/sunsynk.ts";
import { noteError, serve, track } from "../_shared/errors.ts";
import { corsHeaders, json } from "../_shared/cors.ts";
import { createHmac, timingSafeEqual } from "node:crypto";
import { Buffer } from "node:buffer";
import { payClosed } from "../_shared/gate.ts";
import { pool, refundIds, verifyStatus } from "./helpers.ts";

const SECRET = Deno.env.get("PAYSTACK_SECRET_KEY") ?? "";
// Local tests point this at a stand-in server.
const PAYSTACK = Deno.env.get("PAYSTACK_URL") ?? "https://api.paystack.co";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
// Secret: auth user ids allowed to pay on a test key in production, comma-separated (SOLAR-267).
const TEST_USERS = Deno.env.get("PAYSTACK_TEST_USERS") ?? "";
const TESTER_EMAILS = Deno.env.get("TESTER_EMAIL_PATTERN") ?? "";

type Tx = Record<string, unknown> & { status?: string; reference?: string };
type Charge = { reference: string; amount_minor: number; currency: string; auth_ref?: string; auth_email?: string };
type Applied = { action: string; status?: string; kind?: string; refund?: string | null; reason?: string; declined?: boolean;
  hard?: boolean; pay_url?: string; user?: string | null; days_since_plan?: number | null };

/** Paystack's HTTP status; 0 when no answer came (timeout, network). */
class PaystackError extends Error {
  constructor(message: string, readonly status: number) { super(message); }
}

// About 0.65 s a charge (test mode, 2026-10-30): 10 at a time for 40 s is ~600 a call, inside
// the 150 s a call may run with the verifies and refunds around it. A charge not started
// keeps its try for 10 minutes; the next call verifies it (not found: void) and charges again.
const RUN_PARALLEL = 10;
const RUN_BUDGET_MS = 40_000;
const REFUND_BUDGET_MS = 10_000;
// Tries to ask Paystack about, apart from the new charges: 5 at a time for 30 s.
const VERIFY_PARALLEL = 5;
const VERIFY_BUDGET_MS = 30_000;

async function paystack<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  const what = `paystack ${path.split("/").slice(0, 3).join("/")}`;
  const res = await fetch(PAYSTACK + path, {
    method,
    headers: { Authorization: `Bearer ${SECRET}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(30_000),
  }).catch((e) => { throw new PaystackError(`${what}: ${e instanceof Error ? e.message : e}`, 0); });
  const out = await res.json().catch(() => ({}));
  if (!res.ok || out.status !== true) throw new PaystackError(`${what} ${res.status}: ${out.message ?? ""}`, res.status);
  return out.data as T;
}

/** One billing command (public.billing_v2, service role only). */
async function bill<T>(cmd: string, args: Record<string, unknown> = {}, door = "billing_v2"): Promise<T> {
  const { data, error } = await db.rpc(door, { p_cmd: cmd, p_args: args });
  if (error) throw Object.assign(new Error(`${cmd}: ${error.message}`), { code: error.code });
  return data as T;
}

/** Send a refund the database says is owed, and record Paystack's answer. A second refund
 *  of one payment is refused ("already exist"): the database counts that as sent. */
async function sendRefund(refund: string, reference: string) {
  let err: string | null = null;
  let id: string | null = null;
  try {
    const r = await paystack<{ id?: number | string }>("POST", "/refund", { transaction: reference });
    id = r?.id != null ? String(r.id) : null;
  } catch (e) {
    err = e instanceof Error ? e.message : String(e);
    if (!/already/i.test(err)) noteError("refund_refused", e, { ref: reference });
  }
  await bill("record_refund", { refund, error: err, provider_id: id });
}

/** Hand one Paystack answer to apply_payment; send any refund it owes; count it (user id only). */
async function report(reference: string, tx: Tx): Promise<Applied> {
  const r = await bill<Applied>("apply_payment", { reference, tx });
  if (r.refund && (r.action === "refund" || r.kind === "card_check")) {
    if (r.action === "refund") {
      console.error(`billing ${reference}: not applied (${r.reason}): refunding`);
      noteError(`payment_${r.reason ?? "not_applied"}`, new Error(`${reference}: ${r.reason}: refunding`), { ref: reference });
    }
    await sendRefund(r.refund, reference);
  }
  const at = new Date().toISOString();
  if (r.user && r.action === "failed" && r.declined) {
    await track("payment_failed", r.user, reference, at, { renewal: r.kind === "renewal" }).catch(() => {});
  }
  if (r.user && r.action === "applied" && r.kind === "purchase") {
    await track("plan_started_done", r.user, reference, at,
      { returning: r.days_since_plan != null, days_since_plan: r.days_since_plan ?? null }).catch(() => {});
    // A purchase after the win-back email (SOLAR-328), read from the new tables (0246).
    const w = await bill<{ user: string; email_id: number; days: number; at: string } | null>("winback", { reference }, "billing_jobs")
      .catch(() => null);
    if (w) await track("winback_resubscribed_done", w.user, String(w.email_id), w.at, { days: w.days }).catch(() => {});
  }
  return r;
}

/** Ask Paystack about one try. Not found: it never reached Paystack. No answer: left for the next call. */
async function verify(reference: string): Promise<Applied | null> {
  try {
    return await report(reference, await paystack<Tx>("GET", `/transaction/verify/${encodeURIComponent(reference)}`));
  } catch (e) {
    if (e instanceof PaystackError && e.status === 400) return await report(reference, { status: "not_found" });
    if (e instanceof PaystackError) {
      console.error(`billing verify ${reference}: ${e.message}`);
      return null;
    }
    throw e;
  }
}

/** Charge a saved card for a try already written. A timeout can still have taken the money:
 *  Paystack is asked before anything is called failed. */
async function charge(c: Charge): Promise<Applied> {
  let err: PaystackError;
  try {
    const tx = await paystack<Tx>("POST", "/transaction/charge_authorization", {
      authorization_code: c.auth_ref, email: c.auth_email, amount: c.amount_minor, currency: c.currency, reference: c.reference,
    });
    return await report(c.reference, tx);
  } catch (e) {
    if (!(e instanceof PaystackError)) throw e;
    err = e;
  }
  try {
    return await report(c.reference, await paystack<Tx>("GET", `/transaction/verify/${encodeURIComponent(c.reference)}`));
  } catch (e) {
    if (!(e instanceof PaystackError)) throw e;
    // Not found after Paystack refused the charge with a 400 (a dead card, "Email does not
    // match Authorization code"): a failed try. Anything else: unknown, verified before any new try.
    if (e.status === 400 && err.status === 400) {
      return await report(c.reference, { status: "failed", reference: c.reference, gateway_response: err.message });
    }
    console.error(`billing charge ${c.reference}: ${err.message}; unknown`);
    noteError("charge_unknown", err, { ref: c.reference });
    return await report(c.reference, { status: "unknown", message: err.message });
  }
}

async function signedInUser(req: Request) {
  const auth = req.headers.get("authorization") ?? "";
  const jwt = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!jwt) return null;
  const { data, error } = await db.auth.getUser(jwt);
  return error || !data?.user ? null : data.user;
}

const interval = (v: unknown) => v === "yearly" || v === "year" ? "year" : v === "monthly" || v === "month" ? "month" : null;
const ids = (v: unknown) => Array.isArray(v) ? v.filter(Number.isSafeInteger) : null;

serve("billing", async (req) => {
  const route = new URL(req.url).pathname.split("/").pop();
  const origin = req.headers.get("origin");
  const cors = corsHeaders(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405, cors);
  if (!SECRET) return json({ error: "payments not set up" }, 503, cors);

  if (route === "webhook") {
    // Signed with the secret key over the raw body (Paystack docs, "Verify event origin").
    const raw = await req.text();
    const want = createHmac("sha512", SECRET).update(raw).digest();
    const got = Buffer.from(req.headers.get("x-paystack-signature") ?? "", "hex");
    if (got.length !== want.length || !timingSafeEqual(got, want)) return json({ error: "bad signature" }, 401);
    const ev = JSON.parse(raw);
    const event = String(ev.event ?? "");
    const d = ev.data ?? {};
    // Only our own references; Paystack may send events for payments made elsewhere.
    let ref = "", entity = "", status = "";
    if (event === "charge.success") {
      ref = entity = String(d.reference ?? ""); status = String(d.status ?? "success");
    } else if (event.startsWith("refund.")) {
      // data is the refund, naming the payment in transaction_reference. Dashboard refunds come this way too.
      ref = String(d.transaction_reference ?? ""); status = event.slice("refund.".length);
      entity = String(d.id ?? d.refund_reference ?? ref);
    } else if (event.startsWith("charge.dispute.")) {
      ref = String(d.transaction?.reference ?? ""); status = String(d.status ?? event.slice("charge.dispute.".length));
      entity = String(d.id ?? ref);
    }
    if (!ref.startsWith("psh_")) return json({ ok: true }, 200);
    const e = await bill<{ id: number; process: boolean }>("event_begin",
      { provider: "paystack", type: event, entity, status, payload: ev });
    if (!e.process) return json({ ok: true, duplicate: true }, 200);
    try {
      if (event === "charge.success") {
        await report(ref, d as Tx);
      } else if (event.startsWith("refund.")) {
        if (status === "failed") noteError("refund_failed", new Error(`refund ${ref} failed: ${d.reason ?? ""}`), { ref });
        // Paystack sends amount as a string ("10000", in cents) in its samples.
        const cents = Number(d.amount);
        await bill("record_refund_event", {
          reference: ref, status, ...refundIds(d),
          amount: Number.isSafeInteger(cents) && cents > 0 ? cents : null, reason: d.reason ?? null,
        });
      } else {
        // Lost: resolved with money given back (refund_amount above 0, or the merchant accepted it).
        const back = Number(d.refund_amount);
        const lost = event === "charge.dispute.resolve"
          && (d.status === "lost" || d.resolution === "merchant-accepted" || (Number.isFinite(back) && back > 0));
        noteError("dispute", new Error(`dispute ${ref}: ${event} ${status}${lost ? " (lost)" : ""}`), { ref });
        await bill("record_dispute", {
          reference: ref, event, status, lost, amount: Number.isSafeInteger(back) && back > 0 ? back : null,
          dispute_id: d.id != null ? String(d.id) : null,
        });
      }
      await bill("event_done", { id: e.id });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`billing webhook ${event}: ${msg}`);
      noteError("webhook_failed", err);
      await bill("event_done", { id: e.id, error: msg }).catch(() => {});
      return json({ error: "not recorded" }, 500);
    }
    return json({ ok: true }, 200);
  }

  if (route === "run") {
    const deny = denyUnlessServer(req);
    if (deny) return deny;
    const r = await bill<{ busy?: boolean; verify: string[]; charges: Charge[]; refunds: { refund: string; reference: string }[];
      steps: Record<string, number> }>("run");
    if (r.busy) return json({ busy: true }, 200);
    const out = { verified: 0, charged: 0, applied: 0, failed: 0, pending: 0, unknown: 0, refund: 0, void: 0, left: 0, refunds: 0 };
    // Unanswered tries first, on their own budget, so a slow Paystack cannot eat the charges'.
    const v = await pool(r.verify, VERIFY_PARALLEL, VERIFY_BUDGET_MS,
      (ref) => verify(ref).catch((e) => noteError("run_verify_failed", e, { ref })));
    out.verified = v.done.length;
    const c = await pool(r.charges, RUN_PARALLEL, RUN_BUDGET_MS, async (ch) => {
      out.charged++;
      const a = await charge(ch).catch((e) => {
        console.error(`billing run ${ch.reference}: ${e instanceof Error ? e.message : e}`);
        noteError("run_charge_failed", e, { ref: ch.reference });
        return null;
      });
      const k = (a?.action ?? "unknown") as keyof typeof out;
      if (k in out) out[k]++;
    });
    // Charges never started never reached Paystack: void, so the next call tries again.
    for (const ch of c.left) await report(ch.reference, { status: "not_found" }).catch(() => {});
    out.left = c.left.length;
    const refundsStart = Date.now();
    for (const f of r.refunds) {
      if (Date.now() - refundsStart >= REFUND_BUDGET_MS) break;
      await sendRefund(f.refund, f.reference).catch((e) => noteError("run_refund_failed", e, { ref: f.reference }));
      out.refunds++;
    }
    // the daily job's heartbeat (0246): billing.alerts lists it once it goes quiet
    await bill("heartbeat", { job: "billing-run", result: { ...out, steps: r.steps } }, "billing_jobs")
      .catch((e) => noteError("billing_heartbeat_failed", e, { hourly: true }));
    return json({ ...out, steps: r.steps }, 200);
  }

  const user = await signedInUser(req);
  if (!user) return json({ error: "sign in first" }, 401, cors);
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "body must be JSON" }, 400, cors);
  }
  // 22023: a refused command ("pay the failed payment first", ...): say why.
  const refused = (e: unknown) => {
    const code = (e as { code?: string })?.code;
    const msg = e instanceof Error ? e.message.replace(/^\w+: /, "") : String(e);
    return json({ error: msg }, code === "22023" || code === "P0002" ? 409 : 500, cors);
  };

  if (route === "verify") {
    const ref = String(body.reference ?? "");
    if (!ref.startsWith("psh_")) return json({ error: "unknown reference" }, 400, cors);
    // Only the user who opened the try hears about it.
    const owner = await bill<{ user?: string } | null>("attempt_user", { reference: ref });
    if (owner?.user !== user.id) return json({ error: "unknown reference" }, 400, cors);
    const r = await verify(ref);
    return json({ status: verifyStatus(r), kind: r?.kind ?? null }, 200, cors);
  }

  if (route === "change") {
    const action = String(body.action ?? "");
    try {
      const state = action === "downgrade"
        ? await bill("downgrade", { user: user.id, plan: body.plan, extras: body.extras ?? 0, drop: ids(body.drop) ?? [] })
        : action === "interval" ? await bill("switch_interval", { user: user.id, interval: interval(body.period) })
        : action === "cancel" ? await bill("cancel", { user: user.id })
        : action === "undo_cancel" ? await bill("undo_cancel", { user: user.id })
        : null;
      if (!state) return json({ error: "unknown change" }, 400, cors);
      return json(state, 200, cors);
    } catch (e) {
      return refused(e);
    }
  }

  if (route !== "pay") return json({ error: "not found" }, 404, cors);
  const confirmedEmail = user.email_confirmed_at ? user.email ?? "" : "";
  if (payClosed(SECRET, SUPABASE_URL, TEST_USERS, user.id, TESTER_EMAILS, confirmedEmail)) return json({ error: "paid plans open soon" }, 503, cors);
  // The card page sends the user back here; only an allowed app origin.
  if (!origin || !cors["Access-Control-Allow-Origin"]) return json({ error: "origin not allowed" }, 403, cors);

  let inv: { invoice: string; kind: string; status: string; amount_minor: number; currency: string; saved_card: boolean };
  try {
    if (body.settle === true) inv = await bill("pay_now", { user: user.id });
    else if (body.card === true) inv = await bill("start_card_check", { user: user.id });
    else {
      const st = await bill<{ state: string; plan: string | null }>("account_state", { user: user.id });
      const args = { user: user.id, plan: String(body.plan ?? ""), extras: Number.isSafeInteger(body.extras) ? body.extras : 0, plants: ids(body.plants) };
      inv = st.plan && (st.state === "active" || st.state === "past_due")
        ? await bill("upgrade", args)
        : await bill("start_checkout", { ...args, interval: interval(body.period) ?? "month" });
    }
  } catch (e) {
    return refused(e);
  }
  if (inv.status === "waived") return json({ status: "applied", waived: true }, 200, cors);

  // A card check and a new card go to the card page: a new card is the point.
  const channel = inv.saved_card && body.newCard !== true && body.card !== true ? "saved_card" : "card_page";
  type Try = Charge & { busy?: boolean; verify?: string[]; url?: string };
  let t: Try;
  try {
    t = await bill<Try>("begin_attempt", { invoice: inv.invoice, channel });
    if (t.verify) {
      for (const ref of t.verify) await verify(ref);
      t = await bill<Try>("begin_attempt", { invoice: inv.invoice, channel });
    }
  } catch (e) {
    return refused(e);
  }
  if (t.busy || t.verify) return json({ error: "a payment is already in progress" }, 409, cors);
  // The card page for this bill is still open: the owner goes back to the same page.
  if (t.url) return json({ url: t.url, reference: t.reference }, 200, cors);

  if (channel === "saved_card") {
    const r = await charge(t);
    return json({ status: r.action, reference: t.reference, url: r.pay_url ?? null }, 200, cors);
  }
  try {
    const page = await paystack<{ authorization_url: string }>("POST", "/transaction/initialize", {
      email: user.email, amount: t.amount_minor, currency: t.currency, reference: t.reference,
      channels: ["card"], callback_url: `${origin}/?tab=account&section=plan`,
    });
    // kept, so closing the page and trying again within its hour lands on the same page
    await bill("attempt_page", { reference: t.reference, url: page.authorization_url })
      .catch((e) => noteError("pay_page_not_saved", e, { user: user.id, ref: t.reference }));
    return json({ url: page.authorization_url, reference: t.reference }, 200, cors);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`billing pay ${t.reference}: ${msg}`);
    noteError("pay_failed", e, { user: user.id, ref: t.reference });
    await report(t.reference, { status: "not_found" }).catch(() => {});
    return json({ error: "could not reach Paystack" }, 502, cors);
  }
});
