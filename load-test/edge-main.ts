// Main service for the edge-runtime container (SOLAR-210). Each request runs the
// named function in a fresh worker with Supabase's hosted limits
// (docs: functions/limits): 2 s CPU per request, 256 MB, 400 s wall on paid plans.
// CPU_LIMIT_MS raises the CPU limit so a run can measure how far past 2 s it goes.
const CPU_LIMIT_MS = Number(Deno.env.get("CPU_LIMIT_MS") ?? 2000);

Deno.serve(async (req) => {
  const name = new URL(req.url).pathname.split("/").filter(Boolean)[0];
  const t0 = performance.now();
  try {
    // @ts-ignore EdgeRuntime is the runtime's global
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath: `/home/deno/functions/${name}`,
      memoryLimitMb: 256,
      workerTimeoutMs: 400_000,
      cpuTimeSoftLimitMs: CPU_LIMIT_MS,
      cpuTimeHardLimitMs: CPU_LIMIT_MS,
      noModuleCache: false,
      forceCreate: true,
      envVars: Object.entries(Deno.env.toObject()),
    });
    const res = await worker.fetch(req);
    const body = await res.text();
    return new Response(body, {
      status: res.status,
      headers: { "Content-Type": "application/json", "X-Wall-Ms": String(Math.round(performance.now() - t0)) },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e), wallMs: Math.round(performance.now() - t0) }), { status: 500 });
  }
});
