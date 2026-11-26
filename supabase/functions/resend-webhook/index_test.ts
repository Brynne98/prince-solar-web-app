// deno test -A --node-modules-dir=none resend-webhook/index_test.ts (SOLAR-679 F13)
// The webhook: Svix signature, which events block an address, and what it writes.
import { assertEquals } from "jsr:@std/assert@1";
import { Buffer } from "node:buffer";
import { blockOf, handle, verify } from "./index.ts";

// a made-up secret in Svix's format, not a real one
const SECRET = "whsec_" + Buffer.from("0123456789abcdef0123456789abcdef").toString("base64");
const NOW = 1_800_000_000;

async function sign(body: string, id = "msg_1", ts = NOW, secret = SECRET) {
  const key = await crypto.subtle.importKey("raw", Buffer.from(secret.slice(6), "base64"), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = Buffer.from(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${ts}.${body}`))).toString("base64");
  return new Headers({ "svix-id": id, "svix-timestamp": String(ts), "svix-signature": `v1,${sig}` });
}
const bounced = (type = "Permanent", to = ["Gone@Example.com"]) => JSON.stringify({
  type: "email.bounced", created_at: "2026-11-26T10:00:00Z",
  data: { email_id: "e-1", from: "Prince Solar <alerts@x.test>", to, subject: "s",
          bounce: { type, subType: "General", message: "mailbox unavailable" } },
});

Deno.test("signature: a good one passes; a changed body, another secret, an old call fail", async () => {
  const body = bounced();
  assertEquals(await verify(SECRET, await sign(body), body, NOW), true);
  assertEquals(await verify(SECRET, await sign(body), body + " ", NOW), false);
  const other = "whsec_" + Buffer.from("another-secret-another-secret!!").toString("base64");
  assertEquals(await verify(SECRET, await sign(body, "msg_1", NOW, other), body, NOW), false);
  assertEquals(await verify(SECRET, await sign(body, "msg_1", NOW - 301), body, NOW), false);
  assertEquals(await verify(SECRET, new Headers(), body, NOW), false);
  assertEquals(await verify("", await sign(body), body, NOW), false);
});

Deno.test("signature: one good entry among several (a rotated secret) passes", async () => {
  const body = bounced();
  const h = await sign(body);
  h.set("svix-signature", `v1,AAAA ${h.get("svix-signature")}`);
  assertEquals(await verify(SECRET, h, body, NOW), true);
});

Deno.test("events: a permanent bounce, a complaint, a suppression block; others don't", () => {
  assertEquals(blockOf(JSON.parse(bounced())),
    { emails: ["gone@example.com"], reason: "bounced", detail: "email e-1 General: mailbox unavailable" });
  assertEquals(blockOf(JSON.parse(bounced("Transient"))), null);
  assertEquals(blockOf(JSON.parse(bounced("Undetermined"))), null);
  assertEquals(blockOf({ type: "email.complained", data: { email_id: "e-2", to: ["Name <a@b.test>"] } }),
    { emails: ["a@b.test"], reason: "complained", detail: "email e-2" });
  assertEquals(blockOf({ type: "email.suppressed", data: { to: ["s@b.test"] } }),
    { emails: ["s@b.test"], reason: "suppressed", detail: null });
  assertEquals(blockOf({ type: "email.delivered", data: { to: ["a@b.test"] } }), null);
  assertEquals(blockOf({ type: "email.complained", data: {} }), null);
});

Deno.test("handler: signed bounce writes mail_block; bad signature, no secret, a soft bounce write nothing", async () => {
  const calls: unknown[] = [];
  const rpc = (fn: string, args: Record<string, unknown>) => { calls.push([fn, args]); return Promise.resolve({ error: null }); };
  const req = async (body: string, h?: Headers) =>
    new Request("http://x/resend-webhook", { method: "POST", body, headers: h ?? await sign(body) });
  assertEquals((await handle(await req(bounced()), SECRET, rpc, NOW)).status, 200);
  assertEquals(calls, [["mail_block", { p_emails: ["gone@example.com"], p_reason: "bounced", p_detail: "email e-1 General: mailbox unavailable" }]]);
  assertEquals((await handle(await req(bounced(), new Headers()), SECRET, rpc, NOW)).status, 401);
  assertEquals((await handle(await req(bounced()), "", rpc, NOW)).status, 503);
  const soft = await handle(await req(bounced("Transient")), SECRET, rpc, NOW);
  assertEquals([soft.status, await soft.json()], [200, { ignored: true }]);
  assertEquals(calls.length, 1);
});

Deno.test("handler: a failed write throws (500), so Svix sends it again", async () => {
  const body = bounced();
  const req = new Request("http://x/resend-webhook", { method: "POST", body, headers: await sign(body) });
  let threw = false;
  try { await handle(req, SECRET, () => Promise.resolve({ error: { message: "down" } }), NOW); } catch { threw = true; }
  assertEquals(threw, true);
});
