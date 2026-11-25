// Fake SunSynk answered inside the calling function (SOLAR-637). A call to the mock-sunsynk
// function counts toward Supabase's 30 function-to-function calls per run, so a shard with
// many fake logins had its later readings refused. Same answers as mock-sunsynk/index.ts.
// No Deno APIs: scripts/mock-fetch-test.mjs runs it under Node.
import { handle } from "./mock-sunsynk.mjs";

/** A request to the hosted mock at `base`, answered without a network call; plant ids move up by idOffset. */
export async function mockFetch(base: string, idOffset: number, url: string, init: RequestInit = {}): Promise<Response> {
  init.signal?.throwIfAborted();
  const u = new URL(url);
  const r = handle({
    method: init.method ?? "GET",
    path: u.pathname.slice(new URL(base).pathname.length) || "/",
    query: u.searchParams,
    auth: new Headers(init.headers).get("authorization") ?? "",
    body: typeof init.body === "string" ? init.body : "",
    idOffset,
  });
  return new Response(JSON.stringify(r.json), { status: r.status, headers: { "Content-Type": "application/json" } });
}
