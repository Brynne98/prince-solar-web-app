// deno test -A --node-modules-dir=none _shared/heartbeat_test.ts (SOLAR-679 F12)
import { heartbeat } from "./heartbeat.ts";

const eq = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} !== ${JSON.stringify(b)}`); };
const calls: string[] = [];
const fake = ((u: string | URL | Request) => { calls.push(String(u)); return Promise.resolve(new Response("ok")); }) as typeof fetch;

Deno.test("no URL set: nothing is sent", async () => {
  calls.length = 0;
  Deno.env.delete("HEARTBEAT_URL_READER");
  await heartbeat("reader", true, fake);
  eq(calls, []);
});

Deno.test("ok beats the URL; a failure beats URL/fail", async () => {
  calls.length = 0;
  Deno.env.set("HEARTBEAT_URL_JOB_CHECK", "https://beat.test/abc/");
  await heartbeat("job_check", true, fake);
  await heartbeat("job_check", false, fake);
  eq(calls, ["https://beat.test/abc/", "https://beat.test/abc/fail"]);
  Deno.env.delete("HEARTBEAT_URL_JOB_CHECK");
});

Deno.test("a failed send is swallowed", async () => {
  Deno.env.set("HEARTBEAT_URL_BILLING_RUN", "https://beat.test/x");
  await heartbeat("billing_run", true, (() => Promise.reject(new Error("down"))) as typeof fetch);
  Deno.env.delete("HEARTBEAT_URL_BILLING_RUN");
});
