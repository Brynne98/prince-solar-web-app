// SOLAR-686 H22: an imported day matches the live day where both exist. The fake SunSynk answers
// a live read for now only, so the reader's side here is the fake's own day as the reader samples
// it: each minute's value from the minute before (the reader reads a minute late at worst).
import { assert } from "jsr:@std/assert@1";
import { brandOf } from "../_shared/brands/index.ts";
import { dayClock } from "../_shared/localtime.ts";
import { compare } from "./day.ts";

// limits per series, in W (SoC in %): the median and p90 of |imported - reader|
const LIMITS = { pv_w: [150, 600], load_w: [150, 600], grid_w: [150, 600] } as const;
const MIN_OVERLAP = 600;

function passes(c: ReturnType<typeof compare>) {
  if (c.overlap < MIN_OVERLAP) return `overlap ${c.overlap}`;
  for (const [k, [med, p90]] of Object.entries(LIMITS)) {
    const e = (c.error as any)[k];
    if (e.n < MIN_OVERLAP / 2) return `${k}: ${e.n} pairs`;
    if (e.median > med || e.p90 > p90) return `${k}: median ${e.median}, p90 ${e.p90}`;
  }
  return null;
}

async function fakeDay() {
  const b = brandOf("mock");
  const t = await b.signIn("solo@mock", "any");
  const acc = { id: "h22", user_id: "u", username: "solo@mock", brand: "mock", access_token: t.access_token, access_expires_at: t.expires_at };
  const [inv] = await b.listInverters(acc);
  const day = new Date(Date.now() - 2 * 86400e3).toISOString().slice(0, 10);
  const clock = dayClock("Africa/Johannesburg", day);
  return { clock, spine: b.history.plantSpine([await b.history.inverterDay(acc, inv.sn, day, false)], clock) };
}

Deno.test("H22 an imported day against the reader's minutes: within the limits", async () => {
  const { spine } = await fakeDay();
  const reader = [...spine.entries()].map(([ts]) => ({ ts, ...(spine.get(ts - 60) ?? spine.get(ts)) }));
  const why = passes(compare(spine, reader));
  assert(why == null, why ?? "");
});

Deno.test("H22 a sparse match does not pass", async () => {
  const { spine } = await fakeDay();
  const reader = [...spine.entries()].filter(([ts]) => ts % 3600 === 0).map(([ts, r]) => ({ ts, ...r }));
  assert(passes(compare(spine, reader)) != null);
});

Deno.test("H22 a day shifted by an hour does not pass", async () => {
  const { spine } = await fakeDay();
  const reader = [...spine.entries()].map(([ts]) => ({ ts, ...(spine.get(ts - 3600) ?? {}) }));
  assert(passes(compare(spine, reader)) != null);
});
