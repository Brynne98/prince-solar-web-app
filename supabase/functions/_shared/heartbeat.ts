// Phone paging (SOLAR-679 F12): a Better Stack heartbeat per watched job. Each URL is a secret,
// HEARTBEAT_URL_<NAME>; unset, nothing is sent (local runs, tests). A beat that stops arriving,
// or a /fail beat, pages Brynne's phone. Errors are swallowed: a missed beat is the alarm.
export type Beat = "reader" | "job_check" | "billing_run";

export async function heartbeat(name: Beat, ok = true, fetchFn: typeof fetch = fetch): Promise<void> {
  const url = Deno.env.get(`HEARTBEAT_URL_${name.toUpperCase()}`);
  if (!url) return;
  try {
    await fetchFn(ok ? url : `${url.replace(/\/+$/, "")}/fail`, { method: "POST", signal: AbortSignal.timeout(5000) });
  } catch { /* the next beat, or its absence, says it */ }
}
