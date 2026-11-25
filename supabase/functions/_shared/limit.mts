// At most `max` tasks at once per key (SOLAR-649). Plain TypeScript with no imports:
// scripts/limit-test.mjs runs it under Node.
const busy = new Map<string, { n: number; max: number; queue: (() => void)[] }>();

/**
 * Waits for a free place under `key`; call the returned function when done. Throws after
 * `waitMs` without a place, so a caller on a time budget gives up rather than queue forever.
 * `max` may change between calls (the poll lanes' cap, SOLAR-656): the latest one counts, so a
 * smaller cap retires places as they free and a larger one lets queued callers in at once.
 */
export async function slot(key: string, max: number, waitMs = Infinity): Promise<() => void> {
  const s = busy.get(key) ?? { n: 0, max, queue: [] };
  busy.set(key, s);
  s.max = max;
  while (s.n < s.max && s.queue.length) { s.n++; s.queue.shift()!(); }
  if (s.n < s.max) s.n++;
  else {
    await new Promise<void>((go, no) => {
      const take = () => { clearTimeout(timer); go(); };
      s.queue.push(take);
      const timer = Number.isFinite(waitMs) ? setTimeout(() => {
        const i = s.queue.indexOf(take);
        if (i >= 0) s.queue.splice(i, 1);
        no(new Error(`waited ${waitMs} ms for a place on ${key}`));
      }, waitMs) : undefined;
    });
  }
  // the place passes straight to the next waiter, or frees (or retires, over a smaller cap)
  return () => {
    const next = s.n <= s.max ? s.queue.shift() : undefined;
    if (next) next();
    else if (--s.n === 0 && !s.queue.length) busy.delete(key);
  };
}
