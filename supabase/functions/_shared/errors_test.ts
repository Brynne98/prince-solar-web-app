// deno test -A --node-modules-dir=none _shared/errors_test.ts (SOLAR-595)
// A fake plant's note stays in the log; a real plant's note, or one naming both, goes to PostHog.
Deno.env.set("POSTHOG_URL", "http://posthog.test/e/");
Deno.env.set("TESTER_USERS", "tester-1");
Deno.env.delete("SUPABASE_URL");
const { noteError, flushErrors } = await import("./errors.ts");

const sent: string[] = [];
globalThis.fetch = (_url: string | URL | Request, init?: RequestInit) => {
  sent.push(JSON.parse(String(init?.body)).properties.kind);
  return Promise.resolve(new Response("{}"));
};
const quiet = console.warn;
const eq = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} !== ${JSON.stringify(b)}`); };

Deno.test("a test-plant note is not sent; a real-plant note is", async () => {
  sent.length = 0; console.warn = () => {};
  noteError("fake_only", new Error("x"), { plant: 900000123, day: "2026-11-18" });
  noteError("real_only", new Error("x"), { plant: 2345678 });
  noteError("mixed", new Error("x"), { plant: 900000123 });
  noteError("mixed", new Error("x"), { plant: 2345678 });
  noteError("tester_no_plant", new Error("x"), { user: "tester-1" });
  noteError("user_no_plant", new Error("x"), { user: "someone-else" });
  await flushErrors("recover");
  console.warn = quiet;
  eq(sent.sort(), ["mixed", "real_only", "user_no_plant"]);
});
