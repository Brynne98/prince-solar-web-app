// The guard a recover job carries through its writes (SOLAR-641, 0246): the plant's version
// when the work was handed out, and whether the database has refused a write since. One per
// job or queued fetch, never module-level, so two requests in one isolate never share it.
export type Guard = { version: number | null; refused: boolean };
export const newGuard = (version: number | null): Guard => ({ version, refused: false });

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<unknown>;
/** A guarded history write. Refused ("is not read now"): 0 rows, and this guard stops its job. */
export async function guardedWrite(rpc: Rpc, fn: string, plantId: number, g: Guard, args: Record<string, unknown>) {
  try {
    return await rpc(fn, { p_plant: plantId, p_version: g.version, ...args });
  } catch (e) {
    if (!/is not read now/.test(String(e instanceof Error ? e.message : e))) throw e;
    g.refused = true;
    return 0;
  }
}

/** A history-only day whose history step threw: failed, so the walk retries it. */
export const spineFailed = (day: string, missing: number, e: unknown) =>
  ({ day, banked: 0, missing, failed: true as const, reason: `history write failed: ${e instanceof Error ? e.message : e}` });
