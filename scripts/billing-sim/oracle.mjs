// Independent oracle of the Prince Solar price rules (SOLAR-264).
// Written from the rules text in supabase/migrations/0110_billing.sql's header and the plan approved
// on SOLAR-264 (0127's header, 0129's: Family buys extra plants, R49 a plant), not from the SQL.
// Since SOLAR-437 also from the headers of 0136 (a downgrade picks the plants it keeps), 0138 (monthly
// to yearly on the same plan is paid now), 0155 (Home monthly to Family yearly from today) and 0156.
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
    this.plants = []; // {id, inv, seq, paused, acc}
    this.hasCard = false;
    this.nextKeep = [];   // the plants a booked downgrade keeps, picked first (0136)
    this.prepaid = null;  // the billing date a paid switch to yearly covers (0138)
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
    // a cancel waiting for a paid year to start: the paid room holds until then (0175)
    if (this.prepaid !== null && this.nextPlan === 'free') return null;
    const plan = this.nextPlan ?? this.plan;
    return cover(plan, plan === 'family' ? this.nextExtra ?? this.extra : 0);
  }
  // The room: why a plant may not start, or null. Booked-for-removal plants count (they collect until
  // their date). A new link also links stopped once the booked plan is full; a start under a booked
  // downgrade is allowed while the plan has room now: it collects to the billing date (0136).
  blocked(link = false) {
    if (this.comped) return null;
    if (this.active().length >= cover(this.plan, this.held())) return 'no room';
    const br = this.bookedRoom();
    if (link && br !== null && this.kept() >= br) return 'plan change';
    return null;
  }
  pickIdx(id) { const i = this.nextKeep.indexOf(id); return i < 0 ? Infinity : i; }
  byPick(a, b) { return this.pickIdx(a.id) - this.pickIdx(b.id) || a.seq - b.seq || a.id - b.id; }
  // The plants that stop on the billing date: collecting, not booked for deletion, past the booked
  // room, the pick first (0136). Empty when nothing is booked.
  drops() {
    const br = this.bookedRoom();
    if (br === null || this.comped) return [];
    return this.active().filter((p) => !this.rm.has(p.id)).sort((a, b) => this.byPick(a, b)).slice(br).map((p) => p.id);
  }
  // the collecting plants the booked plan keeps, in pick order
  picks() { const d = this.drops(); return this.active().filter((p) => !this.rm.has(p.id) && !d.includes(p.id)).sort((a, b) => this.byPick(a, b)).map((p) => p.id); }
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
    return freshIds.map((id) => { const paused = c.blocked(true) !== null; c.plants.push({ id, inv: 1, seq: Infinity, paused }); return { id, paused }; });
  }
  // Start stopped plants after a paid start or upgrade: the oldest stopped, while there is room.
  // More room on the same plan (0131): at most `max`, the newest linked first.
  resume(max = Infinity, newest = false) {
    // newest: more room on the same plan, plants booked for removal left out (0131)
    const stopped = this.ordered().filter((x) => x.paused && !(newest && this.rm.has(x.id)));
    if (newest) stopped.reverse();
    for (const p of stopped.slice(0, max)) {
      if (this.blocked() !== null) break;  // only the room now stops it (0136)
      p.paused = false;
      // a plant that is collecting again is no longer up for deletion (0116: plants stopped by a move to Free come back)
      this.freeRm.delete(p.id);
      if (this.rm.delete(p.id)) { this.unbooked = (this.unbooked || 0) + 1; if (this.rm.size === 0) this.rmOn = null; }
    }
  }
  clone() { const c = Object.assign(new Oracle(), this); c.plants = this.plants.map((p) => ({ ...p })); c.rm = new Set(this.rm); c.freeRm = new Set(this.freeRm); c.nextKeep = this.nextKeep.slice(); return c; }
  // A paid year holds plan, period, extras and anything booked as they are until it starts (0138).
  yearPaid(next) {
    if (this.prepaid === null) return false;
    return next.nextPlan !== this.nextPlan || next.nextPeriod !== this.nextPeriod || next.nextExtra !== this.nextExtra;
  }

  // ---- actions: each returns {err} for a refusal, else {} and applies the change ----
  // A downgrade books with the plants it keeps (0136): no "remove plants first". The same plan monthly
  // to yearly is paid now (0138). A plan change, or an undo, takes a booked extras drop with it (0155).
  bookChange(plan, period) {
    if (this.plan === 'free') return { err: 'nothing to change on Free' };
    if (this.comped) return { err: 'free of charge' };
    // a cancel already booked: a second one changes nothing (0176)
    if (this.nextPlan === 'free' && plan === 'free') return {};
    // a paid year: only a cancel, which keeps the switch and ends the plan a year later (0175),
    // or its undo back to the switch (0176)
    if (this.prepaid !== null) {
      if (plan === this.plan) { if (this.nextPlan === 'free') { this.nextPlan = null; this.nextKeep = []; } return {}; }
      if (plan !== 'free') return { err: 'your year is paid' };
      this.nextPlan = 'free'; this.nextKeep = [];
      return {};
    }
    // a booked cancel: only its undo, the plan as it is (0176)
    if (this.nextPlan === 'free' && !(plan === this.plan && (period ?? this.period) === this.period)) return { err: 'your plan is cancelled' };
    if (PLAN_RANK[plan] > PLAN_RANK[this.plan]) return { err: 'upgrade starts at once' };
    if (plan === this.plan && this.period === 'monthly' && period === 'yearly') return { err: 'switch to yearly is paid now' };
    const samePer = (period ?? this.period) === this.period;
    const n = {
      nextPlan: plan === this.plan ? null : plan,
      nextPeriod: plan === 'free' || samePer ? null : period,
      nextExtra: plan !== this.plan || samePer ? null : this.nextExtra,
    };
    if (this.yearPaid(n)) return { err: 'your year is paid' };
    this.nextKeep = plan === this.plan && !samePer && this.nextExtra !== null ? this.nextKeep : [];
    Object.assign(this, n);
    return {};
  }
  bookRemoval(id) {
    if (!this.has(id)) return { err: 'not your plant' };
    if (this.plan === 'free' || this.comped) return { err: 'removal on Free is at once' };
    this.rm.add(id); this.rmOn = this.next; return {};
  }
  keep(id) {
    // a plant a booked downgrade stops: first in the pick, the last pick drops out (0136)
    if (this.drops().includes(id)) { this.nextKeep = [id, ...this.picks()].slice(0, this.bookedRoom()); return {}; }
    // Free, or a plant the move to Free booked: it comes back only by a swap (start), never by Keep (0131, 0133)
    if (this.plan === 'free' || (this.rm.has(id) && this.freeRm.has(id))) return { err: 'start it instead' };
    // a removal booked before 0139 comes back whole: every plant of its login (no room check since 0139)
    const acc = this.get(id)?.acc ?? null;
    for (const x of [...this.rm]) if (!this.freeRm.has(x) && (x === id || (acc !== null && this.get(x)?.acc === acc))) this.rm.delete(x);
    if (this.rm.size === 0) this.rmOn = null;
    return {};
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
    const nextExtra = n === this.extra ? null : n;
    if (this.yearPaid({ nextPlan: this.nextPlan, nextPeriod: this.nextPeriod, nextExtra })) return { err: 'your year is paid' };
    this.nextKeep = n === this.extra && this.nextPlan !== null ? this.nextKeep : [];
    this.nextExtra = nextExtra;
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

  // What the user pays now (0138, 0155, 0156):
  //   start:  from Free, the plan and period asked (monthly when none).
  //   switch: the same plan, monthly to yearly: a year of what is held from the billing date, paid now.
  //   upgrade: a bigger plan in the period held, the difference for the days left; Home monthly to
  //            Family yearly instead starts a year today at its full price, less the unused days of the month.
  // `extras`: the extra plants asked for; none are sold (0156), only a negative count is refused.
  // Returns {kind, amount, period, added, extraTotal} or {err}.
  quote(plan, period, extras, today) {
    if (this.comped) return { err: 'this plan is free of charge' };
    if (this.state === 'past_due') return { err: 'settle the failed payment first' };
    if (this.prepaid !== null) return { err: 'your year is paid' };
    const kind = this.plan === 'free' ? 'start' : plan === this.plan && this.period === 'monthly' && period === 'yearly' ? 'switch' : 'upgrade';
    const across = kind === 'upgrade' && this.period === 'monthly' && period === 'yearly' && plan !== this.plan;
    const per = across ? 'yearly' : kind === 'upgrade' ? this.period : period ?? 'monthly';
    if (extras !== null && extras < 0) return { err: 'unknown plan or period' };
    const added = 0; // extra plants are no longer sold (0156)
    if (kind === 'switch' && this.nextPlan !== null) return { err: 'plan change' };
    if (kind === 'upgrade' && plan === this.plan) return { err: 'nothing to buy' };
    if (kind === 'upgrade' && this.plan === 'family' && plan === 'home') return { err: 'not an upgrade' };
    // a cancelled plan buys nothing more (0175)
    if (kind === 'upgrade' && this.nextPlan === 'free') return { err: 'your plan is cancelled' };
    const amount = this.amountFor(kind, plan, per, today);
    const extraTotal = plan !== 'family' ? 0 : kind === 'switch' ? this.nextExtra ?? this.extra : kind === 'start' ? added : this.held() + added;
    return { kind, amount, period: per, added, extraTotal, across };
  }
  amountFor(kind, plan, per, today) {
    if (kind === 'start') return price(plan, per, 0);
    if (kind === 'switch') return price(plan, 'yearly', plan === 'family' ? this.nextExtra ?? this.extra : 0);
    if (per !== this.period) return price(plan, per, 0) - prorate(price(this.plan, this.period, 0), today, this.next, this.period, this.day);
    return prorate(price(plan, per, plan === 'family' ? this.held() : 0) - price(this.plan, this.period, this.held()), today, this.next, this.period, this.day);
  }
  // Why a payment no longer applies (refunded), or null: the account moved on since the charge opened.
  stale(c, today) {
    if (this.prepaid !== null) return 'year paid';
    if (this.nextPlan === 'free' && (c.kind === 'upgrade' || c.kind === 'switch')) return 'plan cancelled';
    if (c.kind === 'switch') {
      if (this.plan !== c.plan || this.period !== 'monthly' || this.state === 'past_due' || this.comped) return 'plan changed';
      if (this.nextPlan !== null) return 'plan change booked';
      if ((c.billingDate ?? null) !== this.next) return 'billing date passed';
      return this.amountFor('switch', c.plan, 'yearly', today) !== c.amount ? 'price changed' : null;
    }
    if (c.kind === 'start' && this.plan !== 'free') return 'not on Free';
    if (c.kind === 'upgrade' && (this.plan === 'free' || this.state === 'past_due'
        || (this.period !== c.period && !(this.period === 'monthly' && c.period === 'yearly' && this.plan !== c.plan)))) return 'plan changed';
    if ((c.billingDate ?? null) !== this.next) return 'billing date passed';
    if (c.extraTotal !== (c.plan === 'family' ? this.held() + c.added : 0)) return 'extra plants changed';
    if (c.kind === 'upgrade' && this.plan === 'family' && c.plan === 'home') return 'not an upgrade';
    // priced again on the day it is paid (decided 2026-10-31, 0130): another price is refunded
    return Math.max(0, this.amountFor(c.kind, c.plan, c.period, today)) !== c.amount ? 'price changed' : null;
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
    if (this.stale(c, today) !== null) return false;
    if (reusable) this.hasCard = true;
    if (c.kind === 'switch') { this.nextPeriod = 'yearly'; this.prepaid = c.billingDate; return true; }
    if (c.kind === 'start' || this.period !== c.period) {
      // a start, or a bigger plan in a new period: a new billing date from today, nothing booked carries over
      this.plan = c.plan; this.period = c.period; this.day = dom(today); this.next = step(today, c.period, this.day, 1);
      this.nextPlan = null; this.nextPeriod = null; this.state = 'active'; this.pds = null;
      if (c.kind !== 'start') this.nextKeep = [];
    } else { if (this.plan !== c.plan) this.nextPlan = null; this.plan = c.plan; }
    const room = c.kind === 'upgrade' && this.plan === c.plan && c.added > 0;
    this.extra = c.extraTotal; this.nextExtra = null;
    if (room) this.resume(c.added, true); else this.resume();
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
      // not booked for deletion first, then collecting, then the pick, then the first linked (0131, 0136)
      const keep = this.plants.slice().sort((a, b) => this.rm.has(a.id) - this.rm.has(b.id) || a.paused - b.paused || this.byPick(a, b))[0];
      const stop = this.plants.filter((p) => p !== keep).map((p) => p.id);
      for (const p of this.plants) p.paused = p !== keep;
      stop.forEach((id) => { this.rm.add(id); this.freeRm.add(id); });
      if (stop.length) this.rmOn = addDays(d, 30);
      this.plan = 'free'; this.period = null; this.day = null; this.next = null;
      this.nextPlan = null; this.nextPeriod = null; this.state = 'active'; this.pds = null;
      this.extra = 0; this.nextExtra = null; this.nextKeep = []; this.prepaid = null;
      this.stat.toFree++;
    }
    // retries on day 1, 3, 7 after the billing date, once a day
    if (this.state === 'past_due' && [1, 3, 7].includes(dayNo(d) - dayNo(this.pds))
        && !this.charges.some((c) => c.kind === 'renewal' && c.createdOn === d)) {
      const first = this.charges.find((c) => (c.kind === 'renewal') && c.dueOn === this.pds);
      out.push({ kind: 'renewal', amount: first.amount, dueOn: first.dueOn, plan: first.plan, period: first.period });
      this.stat.retries++;
    }
    // the billing date: booked changes apply, the new amount is charged (none for a year a switch paid, 0138)
    // a cancel booked in a paid year: the year starts as paid, the cancel waits for its end (0175)
    if (this.plan !== 'free' && !this.comped && this.state === 'active' && this.next <= d && this.prepaid === this.next && this.nextPlan === 'free') {
      if (this.plan === 'family') this.extra = this.nextExtra ?? this.extra; else this.extra = 0;
      this.period = 'yearly'; this.next = step(this.next, 'yearly', this.day, 1);
      this.nextPeriod = null; this.nextExtra = null; this.prepaid = null;
    }
    if (this.plan !== 'free' && !this.comped && this.state === 'active' && this.next <= d) {
      const plan = this.nextPlan ?? this.plan, per = this.nextPeriod ?? this.period;
      const extra = plan === 'family' ? this.nextExtra ?? this.extra : 0;
      const dueOn = this.next;
      const amount = plan === 'free' || this.prepaid === dueOn ? 0 : price(plan, per, extra);
      const keep = this.picks(), before = new Set(this.active().map((p) => p.id));
      this.plan = plan; this.extra = extra; this.nextExtra = null;
      if (plan === 'free') { this.period = null; this.day = null; this.next = null; }
      else { this.period = per; this.next = step(dueOn, per, this.day, 1); }
      this.nextPlan = null; this.nextPeriod = null; this.nextKeep = []; this.prepaid = null;
      // the plants fit the new room: booked for deletion last, then the pick, then link order (0136)
      const ki = (id) => { const i = keep.indexOf(id); return i < 0 ? Infinity : i; };
      const fitted = this.active().sort((a, b) => this.rm.has(a.id) - this.rm.has(b.id) || ki(a.id) - ki(b.id) || a.seq - b.seq || a.id - b.id);
      fitted.slice(cover(this.plan, this.held())).forEach((p) => { p.paused = true; });
      // stopped by the change: deleted 30 days on, only a start keeps one; removals due today go now
      const stopped = this.plants.filter((p) => p.paused && before.has(p.id) && !this.rm.has(p.id)).map((p) => p.id);
      if (stopped.length) {
        if (this.rmOn !== null && this.rmOn <= dueOn) {
          this.plants = this.plants.filter((p) => !this.rm.has(p.id));
          this.stat.removals += this.rm.size;
          this.freeRm = new Set([...this.freeRm].filter((id) => !this.rm.has(id)));
          this.rm = new Set();
        }
        // on Free, deleted 30 days on; a smaller paid plan deletes them today (0187, SOLAR-492)
        if (plan === 'free') {
          stopped.forEach((id) => { this.rm.add(id); this.freeRm.add(id); });
          this.rmOn = addDays(dueOn, 30);
        } else {
          this.plants = this.plants.filter((p) => !stopped.includes(p.id));
          this.stat.removals += stopped.length;
        }
      }
      if (plan !== 'free' && amount > 0) { out.push({ kind: 'renewal', amount, dueOn, plan, period: per }); this.stat.renewals++; }
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
