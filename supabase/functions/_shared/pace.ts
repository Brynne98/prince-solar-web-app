// One Resend pace for every email a run sends (SOLAR-645 step 2). Resend limits calls per
// account, so the alert emails, the billing outbox and the bulk emails share one gap
// between calls. A 429 holds every later call until its Retry-After has passed.

/** Retry-After as milliseconds: seconds or an HTTP date. Missing or unreadable: 1 s.
 *  Capped at a minute; a longer wait goes to the next run. */
export function retryAfterMs(h: string | null | undefined, now: number): number {
  const MAX = 60_000;
  if (!h) return 1000;
  const s = Number(h);
  const ms = Number.isFinite(s) ? s * 1000 : Date.parse(h) - now;
  return Number.isFinite(ms) ? Math.min(MAX, Math.max(0, ms)) : 1000;
}

export class Pacer {
  private next = 0;
  constructor(private gapMs: number, private now: () => number = Date.now,
              private sleep: (ms: number) => Promise<unknown> = (ms) => new Promise((r) => setTimeout(r, ms))) {}

  /** Waits for the next free slot. False, without waiting, when that slot is after `deadline`. */
  async slot(deadline = Infinity): Promise<boolean> {
    const at = Math.max(this.now(), this.next);
    if (at > deadline) return false;
    const wait = at - this.now();
    if (wait > 0) await this.sleep(wait);
    this.next = at + this.gapMs;
    return true;
  }

  /** A 429: no call before Retry-After has passed. */
  hold(retryAfter: string | null | undefined) {
    const now = this.now();
    this.next = Math.max(this.next, now + retryAfterMs(retryAfter, now));
  }
}
