// The brand registry (SOLAR-681 R15): code outside brands/ gets a login's adapter here and
// never imports one directly.
import type { Brand } from "./types.ts";
import { sunsynk } from "./sunsynk/index.ts";

export * from "./types.ts";

const BRANDS: Record<string, Brand> = { [sunsynk.code]: sunsynk };

/** The brand of a login made before logins had one, and of a link that names none. */
export const DEFAULT_BRAND = sunsynk.code;

/** The adapter for a brand code (a login's `brand`). */
export function brandOf(code: string): Brand {
  const b = BRANDS[code];
  if (!b) throw new Error(`brand_unknown: ${code}`);
  return b;
}

/** Every adapter, e.g. to save each one's call counts. */
export const allBrands = (): Brand[] => Object.values(BRANDS);

/** Saves every adapter's call counts; a poll run passes its shard, run time and plants. */
export async function saveAllCalls(run?: { shard: number; ms: number; plants: number }) {
  await Promise.all(allBrands().map((b) => b.saveCalls(run)));
}
