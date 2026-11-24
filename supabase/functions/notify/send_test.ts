// SUPABASE_URL=http://x SUPABASE_SERVICE_ROLE_KEY=x deno test -A --node-modules-dir=none notify/send_test.ts
// (SOLAR-645 step 2) A 429 from Resend: nothing sent, the rows go back after Retry-After under
// the same key, not counted as a try, and the next call waits for it.
import { assertEquals } from "jsr:@std/assert@1";

const calls: { at: number; key: string | null }[] = [];
const server = Deno.serve({ port: 0, onListen: () => {} }, (req) => {
  calls.push({ at: Date.now(), key: req.headers.get("Idempotency-Key") });
  return calls.length === 1
    ? new Response('{"name":"rate_limit_exceeded"}', { status: 429, headers: { "Retry-After": "1" } })
    : new Response('{"data":[]}', { status: 200 });
});
Deno.env.set("RESEND_URL", `http://localhost:${server.addr.port}/emails`);
const { sendBatch } = await import("./index.ts");
type Out = import("./index.ts").Out;

const out = (id: number): Out => ({
  row: { id, user_id: null, to_email: "a@b.test", plant_id: null, plant_name: null, tz: "Africa/Johannesburg", kind: "welcome",
         key: "welcome", data: {}, tries: 1, switch: null, unsub_token: null, batch_key: null },
  mail: { subject: "s", html: "h", text: "t" } as Out["mail"],
});

// The stand-in server lives across both tests and post() leaves an ok body unread.
const loose = { sanitizeResources: false, sanitizeOps: false };

Deno.test("429: rows back after Retry-After, same key, no try counted; the next call waits", loose, async () => {
  {
    const first = await sendBatch([out(1), out(2)], Date.now() + 10_000);
    assertEquals(first.map((d) => [d.status, d.retry_s, d.refund]), [["queued", 1, true], ["queued", 1, true]]);
    const key = first[0].batch_key!;
    const again = await sendBatch([out(1), out(2)], Date.now() + 10_000, key);
    assertEquals(again.map((d) => d.status), ["sent", "sent"]);
    assertEquals(calls[1].key, key);
    assertEquals(calls[1].at - calls[0].at >= 950, true, `waited ${calls[1].at - calls[0].at} ms`);
  }
});

Deno.test("held past the deadline: rows go back untouched, no call made", loose, async () => {
  // the pace holds the next call 550 ms; a deadline before that sends nothing
  const n = calls.length;
  const res = await sendBatch([out(3)], Date.now() + 100);
  assertEquals(res.map((d) => [d.status, d.refund, d.retry_s]), [["queued", true, 0]]);
  assertEquals(calls.length, n);
});

addEventListener("unload", () => server.shutdown());
