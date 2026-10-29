// `billing` — takes money through Paystack (SOLAR-208). The rules are in 0116; this
// only talks to Paystack and reports back.
//
//   POST /billing/pay      the signed-in user, { plan, period?, added?, newCard? },
//                          { settle: true } to pay a failed renewal, or { card: true }
//                          to change the saved card (R1 on the card page, refunded once
//                          paid; SOLAR-238). Charges the saved
//                          card when there is one; otherwise answers { url } for
//                          Paystack's card page, which comes back to the app with
//                          ?reference=.
//   POST /billing/verify   the signed-in user, { reference }: asks Paystack whether
//                          that card-page payment went through. Answers { status, kind }.
//   POST /billing/webhook  Paystack's own notice of a payment (HMAC-signed).
//   POST /billing/run      pg_cron, daily (0116): renewals and retries.
//
// verify_jwt is off: Paystack has no Supabase session. Each route checks its caller.
// Secret: PAYSTACK_SECRET_KEY (test key until the company account is live).
import { db, denyUnlessServer } from "../_shared/sunsynk.ts";
import { serve } from "../_shared/errors.ts";
import { corsHeaders, json } from "../_shared/cors.ts";
import { createHmac, timingSafeEqual } from "node:crypto";
import { Buffer } from "node:buffer";

const SECRET = Deno.env.get("PAYSTACK_SECRET_KEY") ?? "";
// Local tests point this at a stand-in server.
const PAYSTACK = Deno.env.get("PAYSTACK_URL") ?? "https://api.paystack.co";
const TEST_KEY_LIVE = SECRET.startsWith("sk_test_") && (Deno.env.get("SUPABASE_URL") ?? "").endsWith(".supabase.co");

type Card = Record<string, unknown>;
type Tx = { status: string; reference: string; amount: number; currency: string; gateway_response?: string; authorization?: Card };

async function paystack<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  const res = await fetch(PAYSTACK + path, {
    method,
    headers: { Authorization: `Bearer ${SECRET}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(30_000),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok || out.status !== true) throw new Error(`paystack ${path.split("/").slice(0, 3).join("/")} ${res.status}: ${out.message ?? ""}`);
  return out.data as T;
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}

/** A card change's R1 goes back at once (0120). A refused refund is logged on the charge. */
async function refund(reference: string) {
  const err = await paystack("POST", "/refund", { transaction: reference }).then(() => null, (e) => e.message as string);
  if (err) console.error(`billing refund ${reference}: ${err}`);
  await rpc("billing_charge_refunded", { p_reference: reference, p_error: err });
}

/** Report a Paystack transaction back to 0116. Paid, failed, or still open (null).
 *  `out.kind`: the paid charge's kind, for /verify. */
async function settle(tx: Tx, out: { kind?: string } = {}): Promise<"paid" | "failed" | null> {
  if (tx.status === "success" && tx.currency === "ZAR") {
    const r = await rpc<{ kind?: string; refund?: boolean }>("billing_charge_paid",
      { p_reference: tx.reference, p_card: tx.authorization ?? null, p_cents: tx.amount });
    out.kind = r?.kind;
    if (r?.kind === "card" && r.refund) await refund(tx.reference);
    return "paid";
  }
  // Reversed: refunded. A card change's R1 goes back on purpose, often before the
  // user's /verify (the webhook came first); 0120 answers that it was paid.
  if (["failed", "abandoned", "reversed", "reversal-pending"].includes(tx.status)) {
    const r = await rpc<{ status?: string; kind?: string }>("billing_charge_failed",
      { p_reference: tx.reference, p_error: tx.gateway_response || tx.status });
    if (r?.status === "paid") { out.kind = r.kind; return "paid"; }
    return "failed";
  }
  return null; // pending, ongoing, send_otp...: the webhook settles it
}

/** Charge a saved card. A refused card is a failed charge, not an error. */
async function chargeCard(c: { reference: string; amount: number; card: string; email: string }) {
  try {
    const tx = await paystack<Tx>("POST", "/transaction/charge_authorization", {
      authorization_code: c.card, email: c.email, amount: c.amount * 100, currency: "ZAR", reference: c.reference,
    });
    return await settle(tx);
  } catch (e) {
    // A timeout can still have taken the money: ask Paystack before calling it failed.
    const msg = e instanceof Error ? e.message : String(e);
    const tx = await paystack<Tx>("GET", `/transaction/verify/${encodeURIComponent(c.reference)}`).catch(() => null);
    if (tx) {
      const r = await settle(tx);
      if (r) return r;
      if (tx.status !== "failed") return null; // still open: the webhook settles it
    }
    await rpc("billing_charge_failed", { p_reference: c.reference, p_error: msg });
    return "failed" as const;
  }
}

async function signedInUser(req: Request) {
  const auth = req.headers.get("authorization") ?? "";
  const jwt = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!jwt) return null;
  const { data, error } = await db.auth.getUser(jwt);
  return error || !data?.user ? null : data.user;
}

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
    // Only our own references; Paystack may send events for payments made elsewhere.
    if (ev.event === "charge.success" && String(ev.data?.reference ?? "").startsWith("psh_")) {
      // A reference we never opened is logged, not retried.
      await settle(ev.data as Tx).catch((e) => console.error(`billing webhook ${ev.data.reference}: ${e.message}`));
    }
    return json({ ok: true }, 200);
  }

  if (route === "run") {
    const deny = denyUnlessServer(req);
    if (deny) return deny;
    const due = await rpc<{ reference: string; amount: number; card: string; email: string }[]>("billing_run", {});
    const out = { charged: 0, paid: 0, failed: 0 };
    for (const c of due) {
      out.charged++;
      const r = await chargeCard(c);
      if (r) out[r]++;
    }
    return json(out, 200);
  }

  const user = await signedInUser(req);
  if (!user) return json({ error: "sign in first" }, 401, cors);
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "body must be JSON" }, 400, cors);
  }

  if (route === "verify") {
    const ref = String(body.reference ?? "");
    if (!ref.startsWith("psh_")) return json({ error: "unknown reference" }, 400, cors);
    const tx = await paystack<Tx>("GET", `/transaction/verify/${encodeURIComponent(ref)}`);
    const paid: { kind?: string } = {};
    const status = await settle(tx, paid);
    return json({ status: status ?? "pending", kind: paid.kind ?? null }, 200, cors);
  }

  if (route !== "pay") return json({ error: "not found" }, 404, cors);
  // Paystack's public test cards go through as paid on a test key, so the live project
  // takes no payment until the live key is set (SOLAR-214). Local runs still test.
  if (TEST_KEY_LIVE) return json({ error: "paid plans open soon" }, 503, cors);
  // The card page sends the user back here; only an allowed app origin.
  if (!origin || !cors["Access-Control-Allow-Origin"]) return json({ error: "origin not allowed" }, 403, cors);

  // Settle and card change always go to the card page: a new card is the point.
  const fresh = body.settle === true || body.card === true;
  const { data: open, error } = body.settle === true
    ? await db.rpc("billing_settle_open", { p_user: user.id })
    : body.card === true
    ? await db.rpc("billing_card_open", { p_user: user.id })
    : await db.rpc("billing_charge_open", {
      p_user: user.id, p_plan: String(body.plan ?? ""),
      p_period: body.period ? String(body.period) : null, p_added: Number(body.added) || 0,
    });
  // 22023: a refused change ("settle the failed payment first", ...): say why.
  if (error) return json({ error: error.message }, error.code === "22023" ? 409 : 500, cors);
  const o = open as { reference: string; amount: number; email?: string; card?: string | null };
  if (o.amount === 0) return json({ status: "paid", reference: o.reference }, 200, cors);

  if (o.card && body.newCard !== true && !fresh) {
    const r = await chargeCard({ reference: o.reference, amount: o.amount, card: o.card, email: o.email ?? user.email ?? "" });
    return json({ status: r ?? "pending", reference: o.reference }, 200, cors);
  }
  try {
    const page = await paystack<{ authorization_url: string }>("POST", "/transaction/initialize", {
      email: o.email ?? user.email, amount: o.amount * 100, currency: "ZAR", reference: o.reference,
      channels: ["card"], callback_url: `${origin}/?tab=account&section=plan`,
    });
    return json({ url: page.authorization_url, reference: o.reference }, 200, cors);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`billing pay ${o.reference}: ${msg}`);
    await rpc("billing_charge_failed", { p_reference: o.reference, p_error: msg });
    return json({ error: "could not reach Paystack" }, 502, cors);
  }
});
