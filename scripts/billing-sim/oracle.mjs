// Independent oracle of the Prince Solar price rules (SOLAR-264).
// Written from the rules text in supabase/migrations/0110_billing.sql's header and the plan approved
// on SOLAR-264 (0127's header, 0129's: Family buys extra plants, R49 a plant), not from the SQL.
// Dates are 'YYYY-MM-DD' strings. Money is whole rand.

export const PLAN_RANK = { free: 0, home: 1, family: 2 };
// 0156 (SOLAR-371): Home 2 plants, Family 5, a year is 10 months; extra plants no longer sold,
// those already held keep their price.
const BASE = { home: { monthly: 99, yearly: 990 }, family: { monthly: 199, yearly: 1990 } };
const EXTRA = { monthly: 49, yearly: 588 }; // per extra plant held, per period
export const cover = (plan, extra = 0) => (plan === 'family' ? 5 + extra : plan === 'home' ? 2 : 1); // plants a plan collects

export function price(plan, period, extra = 0) {
  if (plan === 'free') return 0;
  return BASE[plan][period] + (plan === 'family' ? extra * EXTRA[period] : 0);
}
export const extraEach = (period) => EXTRA[period];

// ---- dates -----------------------------------------------------------------
export const dayNo = (s) => Date.UTC(+s.slice(0, 4), +s.slice(5, 7) - 1, +s.slice(8, 10)) / 86400000;
export const dayStr = (n) => new Date(n * 86400000).toISOString().slice(0, 10);
export const addDays = (s, n) => dayStr(dayNo(s) + n);
const monthLen = (y, m0) => new Date(Date.UTC(y, m0 + 1, 0)).getUTCDate();
export const dom = (s) => +s.slice(8, 10);
// The billing date n periods from `from`: same day of month as `day`, or the last day of a short month.
export function step(from, period, day, n) {
  const months = (+from.slice(0, 4)) * 12 + (+from.slice(5, 7) - 1) + n * (period === 'yearly' ? 12 : 1);
  const y = Math.floor(months / 12), m0 = months - y * 12;
  return dayStr(Date.UTC(y, m0, Math.min(day, monthLen(y, m0))) / 86400000);
}
// (difference) x days left / days in period, rounded to whole rand (halves up). No refunds.
export function prorate(diff, today, next, period, day) {
  if (diff <= 0) return 0;
  const start = step(next, period, day, -1);
  const t = Math.min(Math.max(dayNo(today), dayNo(start)), dayNo(next));
  const left = dayNo(next) - t, len = dayNo(next) - dayNo(start);
  return Math.floor((2 * diff * left + len) / (2 * len));
}
export const cyclePos = (today, next, period, day) => dayNo(today) - dayNo(step(next, period, day, -1)); // days into the period

// ---- one user's expected state -------------------------------------------------
export class Oracle {
  constructor() {
    this.plan = 'free'; this.period = null; this.day = null; this.next = null;
    this.state = 'active'; this.pds = null; // past_due_since
    this.nextPlan = null; this.nextPeriod = null;
    this.extra = 0; this.nextExtra = null; // extra plants paid for on Family; a drop booked for the billing date
    this.rm = new Set(); this.rmOn = null; this.comped = false;
    this.freeRm = new Set();  // plants the move to Free booked (0133): kept only by a start
    this.plants = []; // {id, inv, seq, paused}
    this.hasCard = false;
    this.charges = []; // expected charges {ref, kind, amount, plan, period, dueOn, createdOn, status, named, added}
    this.paidTotal = 0;
    this.stat = { toFree: 0, retries: 0, renewals: 0, removals: 0 };
  }
  ordered() { return this.plants.slice().sort((a, b) => a.seq - b.seq || a.id - b.id); }
  active() { return this.ordered().filter((p) => !p.paused); }
  kept() { return this.active().filter((p) => !this.rm.has(p.id)).length; }
  held() { return this.plan === 'family' ? this.extra : 0; }
  // the room once a booked change (plan or extras) lands; null when nothing is booked
  bookedRoom() {
    if (this.nextPlan === null && this.nextExtra === null) return null;
    const plan = this.nextPlan ?? this.plan;
    return cover(plan, plan === 'family' ? this.nextExtra ?? this.extra : 0);
  }
  // The room, one rule for links and starts: why a plant may not start, or null.
  // Booked-for-removal plants count (they collect until their date), except against a booked change.
  blocked() {
    if (this.comped) return null;
    if (this.active().length >= cover(this.plan, this.held())) return 'no room';
    const br = this.bookedRoom();
    if (br !== null && this.kept() >= br) return 'plan change';
    return null;
  }
  // On the billing date the plants fit the room: the first linked that are not about to be deleted stay.
  fit(going) {
    if (this.comped) return;
    const keep = this.active().sort((a, b) => (going.has(a.id) - going.has(b.id)) || a.seq - b.seq || a.id - b.id).slice(0, cover(this.plan, this.held()));
    for (const p of this.active()) if (!keep.includes(p)) p.paused = true;
  }
  has(id) { return this.plants.some((p) => p.id === id); }
  get(id) { return this.plants.find((p) => p.id === id); }

  // What the Billing screen shows.
  priceNow() { return this.comped ? null : price(this.plan, this.period, this.held()); }
  nextCharge() {
    if (this.plan === 'free' || this.comped) return 0;
    const p = this.nextPlan ?? this.plan, per = this.nextPeriod ?? this.period;
    if (p === 'free') return 0;
    return price(p, per, this.nextExtra ?? this.extra);
  }
  status() {
    return {
      plan: this.plan, period: this.period, state: this.state, comped: this.comped,
      nextDate: this.next, nextAmount: this.nextCharge(), price: this.priceNow(),
      nextPlan: this.nextPlan, nextPeriod: this.nextPeriod, removeOn: this.rmOn,
      extraPlants: this.extra, nextExtraPlants: this.nextExtra,
      removePlants: this.plants.filter((p) => this.rm.has(p.id)).map((p) => p.id).sort((a, b) => a - b),
    };
  }

  // ---- plants ----
  // New plants of one link, in plant-id order: each collects if the limit lets it, else links stopped.
  // Mutates nothing; returns [{id, paused}].
  planLink(freshIds) {
    const c = this.clone();
    return freshIds.map((id) => { const paused = c.blocked() !== null; c.plants.push({ id, inv: 1, seq: Infinity, paused }); return { id, paused }; });
  }
  // Start stopped plants after a paid start or upgrade: the oldest stopped, while there is room.
  // More room on the same plan (0131): at most `max`, the newest linked first.
  resume(max = Infinity, newest = false) {
    // newest: more room on the same plan, plants booked for removal left out (0131)
    const stopped = this.ordered().filter((x) => x.paused && !(newest && this.rm.has(x.id)));
    if (newest) stopped.reverse();
    for (const p of stopped.slice(0, max)) {
      if (this.blocked() !== null) break;
      p.paused = false;
      // a plant that is collecting again is no longer up for deletion (0116: plants stopped by a move to Free come back)
      this.freeRm.delete(p.id);
      if (this.rm.delete(p.id)) { this.unbooked = (this.unbooked || 0) + 1; if (this.rm.size === 0) this.rmOn = null; }
    }
  }
  clone() { const c = Object.assign(new Oracle(), this); c.plants = this.plants.map((p) => ({ ...p })); c.rm = new Set(this.rm); c.freeRm = new Set(this.freeRm); return c; }

  // ---- actions: each returns {err} for a refusal, else {} and applies the change ----
  bookChange(plan, period) {
    if (this.plan === 'free') return { err: 'nothing to change on Free' };
    if (this.comped) return { err: 'free of charge' };
    if (PLAN_RANK[plan] > PLAN_RANK[this.plan]) return { err: 'upgrade starts at once' };
    const keep = this.plants.filter((p) => !p.paused && !this.rm.has(p.id)).length;
    if (keep > cover(plan, plan === 'family' ? this.nextExtra ?? this.extra : 0)) return { err: 'remove plants first' };
    this.nextPlan = plan === this.plan ? null : plan;
    this.nextPeriod = plan === 'free' || (period ?? this.period) === this.period ? null : period;
    return {};
  }
  bookRemoval(id) {
    if (!this.has(id)) return { err: 'not your plant' };
    if (this.plan === 'free' || this.comped) return { err: 'removal on Free is at once' };
    this.rm.add(id); this.rmOn = this.next; return {};
  }
  keep(id) {
    // Free, or a plant the move to Free booked: it comes back only by a swap (start), never by Keep (0131, 0133)
    if (this.plan === 'free' || (this.rm.has(id) && this.freeRm.has(id))) return { err: 'start it instead' };
    const br = this.bookedRoom();
    if (br !== null) {
      const n = this.plants.filter((p) => !p.paused && (p.id === id || !this.rm.has(p.id))).length;
      if (n > br) return { err: 'needed for your plan change' };
    }
    this.rm.delete(id); if (this.rm.size === 0) this.rmOn = null; return {};
  }
  stop(id) {
    const p = this.get(id); if (!p) return { err: 'not linked' };
    p.paused = true; return {};
  }
  // Fewer extra plants from the billing date, or undo a drop (n = those held). More is a payment.
  bookExtras(n) {
    if (this.plan !== 'family' || this.comped) return { err: 'extra plants are on Family only' };
    if (n < 0 || n > this.extra) return { err: 'pay to add extra plants' };
    if (this.nextPlan !== null && n !== this.extra) return { err: 'plan change' };
    if (this.kept() > cover('family', n)) return { err: 'remove plants first' };
    this.nextExtra = n === this.extra ? null : n;
    return {};
  }
  start(id) {
    const p = this.get(id); if (!p) return { err: 'not linked' };
    if (!p.paused) return {};
    const why = this.blocked(); if (why) return { err: why };
    p.paused = false;
    // on Free the plant started is the one kept (0130); on any plan one the move to Free booked (0133)
    if ((this.plan === 'free' || this.freeRm.has(id)) && this.rm.delete(id) && this.rm.size === 0) this.rmOn = null;
    this.freeRm.delete(id);
    return {};
  }

  // What the user pays now to start `plan` (Free) or upgrade (Home -> Family, or more extra plants on Family).
  // `extras`: the extra plants wanted on Family in all; null keeps those held.
  // Returns {kind, amount, period, added, extraTotal} or {err}.
  quote(plan, period, extras, today) {
    if (this.comped) return { err: 'this plan is free of charge' };
    if (this.state === 'past_due') return { err: 'settle the failed payment first' };
    if (extras !== null && extras < 0) return { err: 'unknown plan or period' };
    const kind = this.plan === 'free' ? 'start' : 'upgrade';
    const per = kind === 'start' ? period ?? 'monthly' : this.period;
    const added = 0; // extra plants are no longer sold (0156)
    if (kind === 'upgrade' && plan === this.plan) {
      if (added === 0) return { err: 'nothing to buy' };
      if (this.nextPlan !== null) return { err: 'plan change' };
    }
    if (kind === 'upgrade' && this.plan === 'family' && plan === 'home') return { err: 'not an upgrade' };
    const amount = this.priceNow2(kind, plan, per, added, today);
    return { kind, amount, period: per, added, extraTotal: plan === 'family' ? this.held() + added : 0 };
  }
  priceNow2(kind, plan, per, added, today) {
    const newAmt = price(plan, per, (plan === 'family' ? this.held() : 0) + added);
    if (kind === 'start') return newAmt;
    return prorate(newAmt - price(this.plan, this.period, this.held()), today, this.next, this.period, this.day);
  }
  // The payment came in. `c` = {kind, plan, period, added, extraTotal, amount, createdOn, billingDate, dueOn}.
  // Returns false when the account moved on since the charge was opened (nothing applied: refund).
  applyPaid(c, today, reusable) {
    if (c.kind === 'settle' || c.kind === 'renewal') {
      if (!(this.state === 'past_due' && c.dueOn === this.pds)) return false;
      this.state = 'active'; this.pds = null;
      if (reusable) this.hasCard = true;
      return true;
    }
    if (c.kind === 'start' && this.plan !== 'free') return false;
    if (c.kind === 'upgrade' && (this.plan === 'free' || this.state === 'past_due' || this.period !== c.period)) return false;
    if ((c.billingDate ?? null) !== this.next) return false;
    if (c.added > 0 && this.nextPlan !== null && c.plan === this.plan) return false;
    if (c.extraTotal !== (c.plan === 'family' ? this.held() + c.added : 0)) return false;
    if (c.kind === 'upgrade' && this.plan === 'family' && c.plan === 'home') return false;
    // priced again on the day it is paid (decided 2026-10-31, 0130): another price is refunded
    if (Math.max(0, this.priceNow2(c.kind, c.plan, c.period, c.added, today)) !== c.amount) return false;
    if (c.kind === 'start') {
      this.plan = c.plan; this.period = c.period; this.day = dom(today); this.next = step(today, c.period, this.day, 1);
      this.nextPlan = null; this.nextPeriod = null; this.state = 'active'; this.pds = null;
    }
    const room = c.kind === 'upgrade' && this.plan === c.plan;
    if (c.kind !== 'start') { if (this.plan !== c.plan) this.nextPlan = null; this.plan = c.plan; }
    this.extra = c.extraTotal; this.nextExtra = null;
    if (room) this.resume(c.added, true); else this.resume();
    if (reusable) this.hasCard = true;
    return true;
  }
  // A pending renewal is still owed: the past-due date it is for, or the billing date just passed
  // with nothing else paid for it (0127's billing_charge_stale).
  renewalDue(c) {
    if (this.state === 'past_due' && c.dueOn === this.pds) return true;
    return this.state === 'active' && this.plan !== 'free' && !this.comped && !!this.next
      && c.dueOn === step(this.next, this.period, this.day, -1)
      && !this.charges.some((x) => x !== c && (x.kind === 'renewal' || x.kind === 'settle') && x.dueOn === c.dueOn && x.status === 'paid' && !x.refund);
  }
  // A renewal charge failed.
  renewalFailed(dueOn) { this.state = 'past_due'; this.pds = this.pds ?? dueOn; }

  // ---- the daily run ----
  // Returns the charges the run opens: {kind:'renewal', amount, dueOn, card}; applies everything that needs no card.
  runDay(d) {
    const out = [];
    this.lastRun = d;
    // an unreported renewal from an earlier day is handed out again, same reference: today's try.
    // No longer owed: closed, not charged. Still open 3 days after its first try: failed.
    const carried = [];
    for (const c of this.charges.filter((x) => x.kind === 'renewal' && x.status === 'pending' && x.createdOn < d)) {
      if (!this.renewalDue(c)) { c.status = 'failed'; c.closed = true; continue; }
      // expired before today is counted (0132): no try was made today, so today's retry still comes
      if (dayNo(c.triedOn) <= dayNo(d) - 3) { c.status = 'failed'; this.renewalFailed(c.dueOn); continue; }
      c.createdOn = d;
      carried.push(c);
    }
    // unpaid after the last retry (day 7): Free, not while a try is open; the first-linked plant stays, the rest stop and go in 30 days
    if (this.state === 'past_due' && dayNo(d) - dayNo(this.pds) >= 8 && !this.charges.some((c) => c.kind === 'renewal' && c.status === 'pending')) {
      // the first linked that is not booked for deletion; all booked: the first linked (0131)
      const keep = this.ordered().find((p) => !this.rm.has(p.id)) ?? this.ordered()[0];
      const stop = this.plants.filter((p) => p !== keep).map((p) => p.id);
      for (const p of this.plants) p.paused = p !== keep;
      stop.forEach((id) => { this.rm.add(id); this.freeRm.add(id); });
      if (stop.length) this.rmOn = addDays(d, 30);
      this.plan = 'free'; this.period = null; this.day = null; this.next = null;
      this.nextPlan = null; this.nextPeriod = null; this.state = 'active'; this.pds = null;
      this.extra = 0; this.nextExtra = null;
      this.stat.toFree++;
    }
    // retries on day 1, 3, 7 after the billing date, once a day
    if (this.state === 'past_due' && [1, 3, 7].includes(dayNo(d) - dayNo(this.pds))
        && !this.charges.some((c) => c.kind === 'renewal' && c.createdOn === d)) {
      const first = this.charges.find((c) => (c.kind === 'renewal') && c.dueOn === this.pds);
      out.push({ kind: 'renewal', amount: first.amount, dueOn: first.dueOn, plan: first.plan, period: first.period });
      this.stat.retries++;
    }
    // the billing date: booked changes apply, the new amount is charged
    if (this.plan !== 'free' && !this.comped && this.state === 'active' && this.next <= d) {
      const plan = this.nextPlan ?? this.plan, per = this.nextPeriod ?? this.period;
      const extra = plan === 'family' ? this.nextExtra ?? this.extra : 0;
      const amount = plan === 'free' ? 0 : price(plan, per, extra);
      const dueOn = this.next;
      this.plan = plan; this.extra = extra; this.nextExtra = null;
      if (plan === 'free') { this.period = null; this.day = null; this.next = null; }
      else { this.period = per; this.next = step(dueOn, per, this.day, 1); }
      this.nextPlan = null; this.nextPeriod = null;
      this.fit(this.rmOn !== null && this.rmOn <= dueOn ? this.rm : new Set());
      if (plan !== 'free') { out.push({ kind: 'renewal', amount, dueOn, plan, period: per }); this.stat.renewals++; }
    }
    for (const o of out) {
      o.card = this.hasCard; o.createdOn = d; o.status = this.hasCard ? 'pending' : 'failed'; o.triedOn = d;
      this.charges.push(o);
    }
    for (const o of out) if (!o.card) this.renewalFailed(o.dueOn); // no saved card: fails at once
    out.unshift(...carried);
    // booked removals due
    if (this.rm.size && this.rmOn !== null && this.rmOn <= d) {
      this.plants = this.plants.filter((p) => !this.rm.has(p.id));
      this.stat.removals += this.rm.size;
      this.rm = new Set(); this.rmOn = null; this.freeRm = new Set();
    }
    return out;
  }
  // dates after `cur` on which the run has something to do for this user
  dueDates() {
    const ds = [];
    if (this.plan !== 'free' && !this.comped && this.state === 'active' && this.next) ds.push(this.next);
    if (this.state === 'past_due') for (const k of [1, 3, 7, 8]) ds.push(addDays(this.pds, k));
    // still past due after day 8 (the last try was open then): the next day
    if (this.state === 'past_due' && this.lastRun && dayNo(this.lastRun) - dayNo(this.pds) >= 8) ds.push(addDays(this.lastRun, 1));
    if (this.rm.size && this.rmOn) ds.push(this.rmOn);
    for (const c of this.charges) if (c.kind === 'renewal' && c.status === 'pending') ds.push(addDays(c.createdOn, 1));
    return ds;
  }
}
