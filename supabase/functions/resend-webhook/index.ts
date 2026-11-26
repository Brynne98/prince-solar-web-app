// Resend's webhook (SOLAR-679 F13): an address that bounced for good, marked our mail as spam,
// or is on Resend's own block list gets no more mail from us. The address goes into
// private.mail_blocked (mail_block, 0281); the email takes drop every later email to it.
//
// Resend signs each call the Svix way with the webhook's secret (RESEND_WEBHOOK_SECRET,
// "whsec_..."): svix-id, svix-timestamp and svix-signature headers. verify_jwt is off.
// Events taken: email.bounced (only bounce.type "Permanent"), email.complained,
// email.suppressed. Others are answered 200 and ignored, so a webhook with more events
// subscribed does no harm. A failed write answers 500: Svix sends the call again.
// Not a user action: no PostHog event.
import { timingSafeEqual } from "node:crypto";
import { Buffer } from "node:buffer";
import { serve } from "../_shared/errors.ts";

const SECRET = Deno.env.get("RESEND_WEBHOOK_SECRET") ?? "";
// Svix's own tolerance: a call older or newer than this is refused (a replayed call).
const TOLERANCE_S = 300;

/** True when one of svix-signature's "v1,<base64>" entries is the HMAC-SHA256 of
 *  "<id>.<timestamp>.<body>" under the secret, and the timestamp is within 5 minutes. */
export async function verify(secret: string, h: Headers, body: string, nowS = Date.now() / 1000): Promise<boolean> {
  const id = h.get("svix-id"), ts = h.get("svix-timestamp"), sigs = h.get("svix-signature");
  if (!secret || !id || !ts || !sigs || !/^\d+$/.test(ts) || Math.abs(nowS - Number(ts)) > TOLERANCE_S) return false;
  const key = await crypto.subtle.importKey("raw", Buffer.from(secret.replace(/^whsec_/, ""), "base64"),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const want = Buffer.from(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${ts}.${body}`)));
  return sigs.split(" ").some((s) => {
    const [v, b64] = s.split(",");
    const got = Buffer.from(b64 ?? "", "base64");
    return v === "v1" && got.length === want.length && timingSafeEqual(got, want);
  });
}

export type Block = { emails: string[]; reason: "bounced" | "complained" | "suppressed"; detail: string | null };
/** What an event blocks, or null: not one we act on (a soft bounce, a delivery, ...). */
export function blockOf(ev: any): Block | null {
  const d = ev?.data ?? {};
  const emails = (Array.isArray(d.to) ? d.to : [d.to]).filter((x: unknown) => typeof x === "string")
    .map((x: string) => (x.match(/<([^>]+)>/)?.[1] ?? x).trim().toLowerCase()).filter(Boolean);
  if (!emails.length) return null;
  const subject = d.email_id ? `email ${d.email_id}` : null;
  switch (ev?.type) {
    case "email.bounced": {
      if (d.bounce?.type !== "Permanent") return null;
      const detail = [d.bounce.subType, d.bounce.message].filter(Boolean).join(": ") || null;
      return { emails, reason: "bounced", detail: [subject, detail].filter(Boolean).join(" ") || null };
    }
    case "email.complained": return { emails, reason: "complained", detail: subject };
    case "email.suppressed": return { emails, reason: "suppressed", detail: subject };
  }
  return null;
}

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ error: { message: string } | null }>;
const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

export async function handle(req: Request, secret: string, rpc: Rpc, nowS?: number): Promise<Response> {
  if (req.method !== "POST") return reply(405, { error: "method not allowed" });
  if (!secret) return reply(503, { error: "not set up" });
  const raw = await req.text();
  if (!await verify(secret, req.headers, raw, nowS)) return reply(401, { error: "bad signature" });
  let ev: unknown;
  try { ev = JSON.parse(raw); } catch { return reply(400, { error: "not json" }); }
  const b = blockOf(ev);
  if (!b) return reply(200, { ignored: true });
  const { error } = await rpc("mail_block", { p_emails: b.emails, p_reason: b.reason, p_detail: b.detail });
  if (error) throw new Error(`mail_block: ${error.message}`);
  return reply(200, { blocked: b.emails.length, reason: b.reason });
}

if (import.meta.main) {
  const { db } = await import("../_shared/db.ts");
  serve("resend-webhook", (req) => handle(req, SECRET, (fn, args) => db.rpc(fn, args) as any));
}
