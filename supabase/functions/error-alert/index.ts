// PostHog error tracking alerts by email (SOLAR-336). PostHog's webhook destination calls
// this on a new issue and on a fixed issue that comes back; it sends one email to admin@
// through Resend. The caller must send the ERROR_ALERT_KEY secret in x-alert-key (PostHog
// keeps it as a secret header). verify_jwt is off for this function.
import { timingSafeEqual } from "node:crypto";
import { Buffer } from "node:buffer";
import { serve } from "../_shared/errors.ts";
import { errorAlert, FROM_ALERTS } from "../_shared/email.ts";

const KEY = Deno.env.get("ERROR_ALERT_KEY") ?? "";
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const RESEND_URL = Deno.env.get("RESEND_URL") ?? "https://api.resend.com/emails";
const TO = "admin@theronprince.co.za";

const same = (a: string, b: string) => {
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
};
const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

serve("error-alert", async (req) => {
  if (req.method !== "POST") return reply(405, { error: "method not allowed" });
  if (!KEY || !RESEND_KEY) return reply(503, { error: "not set up" });
  if (!same(req.headers.get("x-alert-key") ?? "", KEY)) return reply(401, { error: "unauthorized" });

  const b = await req.json().catch(() => null) as Record<string, unknown> | null;
  const trigger = b?.trigger === "reopened" ? "reopened" : b?.trigger === "created" ? "created" : null;
  if (!trigger) return reply(400, { error: "trigger must be created or reopened" });
  const str = (v: unknown, n: number) => String(v ?? "").slice(0, n);
  const mail = errorAlert({
    trigger, name: str(b!.name, 200) || "Unnamed error", description: str(b!.description, 1000),
    fn: str(b!.function, 60), url: str(b!.url, 500),
  });
  // PostHog retries a failed call; the event's uuid as the key means Resend sends it once.
  const res = await fetch(RESEND_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json",
      ...(b!.id ? { "Idempotency-Key": `err-${str(b!.id, 100)}` } : {}),
    },
    body: JSON.stringify({ from: FROM_ALERTS, to: [TO], subject: mail.subject, html: mail.html, text: mail.text }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) throw new Error(`resend ${res.status}: ${(await res.text()).slice(0, 200)}`);
  return reply(200, { ok: true });
});
