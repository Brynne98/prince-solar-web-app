// At most `max` tasks at once per key (SOLAR-649). Plain TypeScript with no imports:
// scripts/limit-test.mjs runs it under Node.
const busy = new Map<string, { n: number; queue: (() => void)[] }>();

/**
 * Waits for a free place under `key`; call the returned function when done. Throws after
 * `waitMs` without a place, so a caller on a time budget gives up rather than queue forever.
 */
export async function slot(key: string, max: number, waitMs = Infinity): Promise<() => void> {
  const s = busy.get(key) ?? { n: 0, queue: [] };
  busy.set(key, s);
  if (s.n < max) s.n++;
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
  // the place passes straight to the next waiter, or frees
  return () => {
    const next = s.queue.shift();
    if (next) next();
    else if (--s.n === 0) busy.delete(key);
  };
}
