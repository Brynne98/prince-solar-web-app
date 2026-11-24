// `notify` — sends the emails Supabase Auth doesn't (SOLAR-157, SOLAR-183), and the
// billing emails (SOLAR-208, 0116).
//
// Since 0257 (SOLAR-645) cron calls notify-email and notify-push, which use the passes
// exported here. This function's own run (all of it in one call) stays for going back.
//
// pg_cron fires this every minute (migration 0092). The emails are already queued
// when their cause happens (0102): poll steps each plant's state and queues grid,
// battery, string and readings emails; triggers queue welcome, history, Reconnect
// and account deleted. Each run here first calls email_sweep() for what only the
// clock can tell (no readings for 30 min, SunSynk down/back,
// reports due today), then sends the queue: claim up to BATCH rows (skip locked,
// so runs can overlap), build each email, send them in one Resend batch call,
// and mark each row sent, skipped, failed, or queued again with a growing wait.
// It keeps going until the queue is empty or BUDGET_MS is spent.
//
// email_claim skips rows whose switch is off (email_wanted, 0091), whose plant the
// user no longer has, and "back" emails whose "down" never went. needs_relink, relinked,
// share_down, share_back, plant_off_login, welcome, history and account deleted have no switch.
//
// After the emails, the pop-ups (SOLAR-244, 0124): push_claim hands over the alerts
// due one, with their words and the user's browsers, each tried once. A browser the
// push service says is gone (404, 410) is deleted. Off when VAPID_KEYS is unset, NOTIFY_LIVE
// isn't "1", or ?dry=1. Each pop-up is tried once: the email is the channel that retries.
//
// Nothing is sent unless the NOTIFY_LIVE secret is "1". Otherwise, and with ?dry=1,
// the run writes nothing (no sweep, no claim) and returns the next BATCH it would
// send. ?render=all&plant=<id> returns every template built from that plant's data,
// for checking by eye.
import { db, denyUnlessServer } from "../_shared/sunsynk.ts";
import { noteError, reportError, serve, track } from "../_shared/errors.ts";
import {
  accountDeleted, type Email, type Price, type History, freeWeekEnded, freeWeekEndsSoon, freeWeekSetup, historySynced, movedToFree,
  PAY_URL, cardChanged, cardExpiring, paymentFailed, paymentReceived, paymentRefunded, billMailFailed, type Period, planChangeBooked, planKept, plantEvent, type PlantEvent, loginEvent, plantsRemovalSoon,
  offerEnds, planSwitched, planUpgraded, renewalNotice, REPLY_TO, report, type Report, senderFor, sunsynkBack, sunsynkDown, welcome, winback, cancelEndsSoon, needAHand, feedback, unpaidReminder, unpaidLast, unpaidDeleted, APP,
} from "../_shared/email.ts";
import { outboxMail, FROM_BILLING, FROM_HELLO } from "../_shared/email.ts";
import { msgKey, type Post, sendOutboxOne } from "../_shared/outbox.ts";
import { mail as accountMail, type MailInput } from "../_shared/text.ts";
import { Pacer, retryAfterMs } from "../_shared/pace.ts";
import * as webpush from "jsr:@negrel/webpush@0.5.0";

export const LIVE = Deno.env.get("NOTIFY_LIVE") === "1";
export const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
// Local tests point this at a stand-in server.
const RESEND_URL = Deno.env.get("RESEND_URL") ?? "https://api.resend.com/emails";
// Resend's batch call takes up to 100 emails.
const BATCH = 100;
// The cron call times out at 55 s; stop claiming before that, the rest goes next minute.
export const BUDGET_MS = 40_000;
// Resend's default limit is 2 calls a second.
const PACE_MS = 550;
// exportVapidKeys() JSON: {publicKey, privateKey} as JWKs. The public half is VAPID_PUBLIC in public/config.js.
export const VAPID_KEYS = Deno.env.get("VAPID_KEYS") ?? "";
// Pop-ups sent at once; a stage change can queue thousands in one minute.
const PUSH_AT_ONCE = 50;

type Plant = { id: number; name: string; tz: string };

export const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b, null, 1), { status, headers: { "Content-Type": "application/json" } });

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}

// ------------------------------------------------------------------- dates

/** Local parts of an instant in a time zone: "2026-10-24", hour, weekday (1 = Monday). */
function local(tz: string, at = new Date()) {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-GB", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hourCycle: "h23", weekday: "short",
  }).formatToParts(at).map((x) => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, hour: Number(p.hour), dow: "MonTueWedThuFriSatSun".indexOf(p.weekday) / 3 + 1 };
}
const addDays = (d: string, n: number) => new Date(Date.parse(d + "T00:00:00Z") + n * 86400e3).toISOString().slice(0, 10);
// en-GB writes "Sept"; the app and the mock write "Sep". Whole word only, so
// "September" stays whole.
const fmtDay = (d: string, o: Intl.DateTimeFormatOptions) =>
  new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", ...o }).format(new Date(d + "T00:00:00Z")).replace(/\bSept\b/, "Sep");
/** "1 Nov 2026", as the billing emails write a date. */
const day = (d: string) => fmtDay(d, { day: "numeric", month: "short", year: "numeric" });
const dayMonth = (d: string) => fmtDay(d, { day: "numeric", month: "short" });
const hhmm = (epoch: number, tz: string) =>
  new Intl.DateTimeFormat("en-GB", { timeZone: tz, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date(epoch * 1000));
/** "today", or the event's date when it was on another local day ("Tue 21 Oct"). */
function dayOf(epoch: number, tz: string): string {
  const d = local(tz, new Date(epoch * 1000)).date;
  return d === local(tz).date ? "today" : fmtDay(d, { weekday: "short", day: "numeric", month: "short" });
}
/** The days a payment covers, "2026-11-01".."2026-11-30" as "1 to 30 Nov" (SOLAR-415). */
function covers(from: string, to: string): string {
  const [fy, fm] = [from.slice(0, 4), from.slice(5, 7)], [ty, tm] = [to.slice(0, 4), to.slice(5, 7)];
  if (fy === ty && fm === tm) return `${Number(from.slice(8))} to ${fmtDay(to, { day: "numeric", month: "short" })}`;
  return fy === ty ? `${fmtDay(from, { day: "numeric", month: "short" })} to ${fmtDay(to, { day: "numeric", month: "short" })}` : `${day(from)} to ${day(to)}`;
}
/** Battery % at an instant: the newest reading in the 10 minutes before it, as grid_down's
 *  chargePct (0151). Null when none. */
async function socAt(plant: number, at: number): Promise<number | null> {
  const { data } = await db.from("agg_minute").select("soc").eq("plant_id", plant).gte("ts", at - 600).lte("ts", at)
    .not("soc", "is", null).order("ts", { ascending: false }).limit(1).maybeSingle();
  return data?.soc == null ? null : Math.round(data.soc);
}
/** The saved card and the plan, for billing emails that name them (0162). */
const billFacts = (user: string | null) =>
  user ? rpc<{ card: string | null; plan: "free" | "home" | "family" } | null>("email_billing_facts", { p_user: user }) : Promise.resolve(null);
/** A plan's monthly price and its usual price (SOLAR-415). With a user, the price that user
 *  pays today: an offer they already left is not quoted again (SOLAR-443, 0169). */
type Prices = { prices: { monthly: Record<string, number> }; listPrices: { monthly: Record<string, number> }; offer?: Price["offer"] };
let offerNow: Prices | null = null;
async function priceOf(plan: "home" | "family", user: string | null): Promise<Price> {
  const o = user ? await rpc<Prices>("email_prices", { p_user: user }) : (offerNow ??= await rpc<Prices>("api_offer"));
  return { plan, now: o.prices.monthly[plan], list: o.listPrices.monthly[plan], offer: o.offer && { ...o.offer, until: o.offer.until && dayMonth(o.offer.until) } };
}
/** The plan that holds the plants the account ticked: Home for 1 or 2, Family for 3 to 5. */
const pickedPlan = async (plants: number | undefined, user: string | null): Promise<Price> =>
  ({ ...await priceOf((plants ?? 1) > 2 ? "family" : "home", user), plants: plants ?? 1 });
/** The account's first plant (or the one given), its name and how many day totals it holds. */
async function historyAt(user: string | null, plantId?: number | null): Promise<{ plant: string; days: number } | null> {
  if (!user) return null;
  let q = db.from("plant_users").select("plant_id, plant_name").eq("user_id", user);
  if (plantId) q = q.eq("plant_id", plantId);
  const { data: pu } = await q.order("linked_at").limit(1).maybeSingle();
  if (!pu) return null;
  const { count } = await db.from("plant_energy").select("period", { count: "exact", head: true }).eq("plant_id", pu.plant_id).eq("bucket", "day");
  return { plant: pu.plant_name || "your plant", days: count ?? 0 };
}
/** The account's plants with these names (none given: every plant still reading), and the
 *  most day totals any one of them holds: how far back the history goes, never a sum (SOLAR-616). */
async function historyOf(user: string | null, names?: string[]): Promise<{ plants: string[]; days: number }> {
  if (!user || names?.length === 0) return { plants: [], days: 0 };
  const q = db.from("plant_users").select("plant_id, plant_name").eq("user_id", user);
  const { data: pu } = await (names ? q.in("plant_name", names) : q.in("plant_id", await chosenPlants(user))).order("linked_at");
  let days = 0;
  for (const p of pu ?? []) {
    const { count } = await db.from("plant_energy").select("period", { count: "exact", head: true }).eq("plant_id", p.plant_id).eq("bucket", "day");
    days = Math.max(days, count ?? 0);
  }
  return { plants: (pu ?? []).map((p) => p.plant_name || "your plant"), days };
}
/** The plants the user's account reads (0247 chosen_plant_ids: the billing tables once live). */
const chosenPlants = async (user: string | null) => ((await rpc<number[] | null>("chosen_plant_ids", { p_user: user })) ?? []).map(Number);
/** The newest earlier email of a kind for this user, to read what it said. */
async function lastMail(user: string | null, kind: string, before: number): Promise<Record<string, any> | null> {
  if (!user) return null;
  const { data } = await db.from("email_queue").select("data").eq("user_id", user).eq("kind", kind).lt("id", before)
    .order("id", { ascending: false }).limit(1).maybeSingle();
  return data?.data ?? null;
}

function lasted(fromEpoch: number, toEpoch: number): string {
  const m = Math.max(1, Math.round((toEpoch - fromEpoch) / 60));
  // the app's format (fmtDuration) and the pop-ups' (0153): 45 min, 1h 33m, 2h
  return m < 60 ? `${m} min` : m % 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${Math.floor(m / 60)}h`;
}

// ------------------------------------------------------------------- energy

type DayRow = { period: string; pv_kwh: number | null; load_kwh: number | null; imp_kwh: number | null };
const dayEnergy = (plant: number, from: string, to: string) =>
  rpc<DayRow[]>("_plant_day_energy", { p_plant: plant, p_from: from, p_to: to });
const sum = (rows: DayRow[], k: keyof DayRow) => rows.reduce((n, r) => n + (Number(r[k]) || 0), 0);
// A house always uses something; a day of zeros is SunSynk's filler for a day with no readings.
const hasData = (r: DayRow) => (Number(r.load_kwh) || 0) > 0 || (Number(r.pv_kwh) || 0) > 0;
const pct = (cur: number, prev: number) => (prev > 0 ? ((cur - prev) / prev) * 100 : undefined);
const independence = (home: number, imp: number) => (home > 0 ? Math.max(0, Math.min(100, ((home - imp) / home) * 100)) : 0);
const r1 = (n: number) => Math.round(n * 10) / 10;

/** One value per day from `from` to `to`; null where SunSynk had nothing. */
function perDay(rows: DayRow[], from: string, to: string, k: keyof DayRow): (number | null)[] {
  const by = new Map(rows.filter(hasData).map((r) => [r.period, r[k] == null ? null : r1(Number(r[k]))]));
  const out: (number | null)[] = [];
  for (let d = from; d <= to; d = addDays(d, 1)) out.push(by.get(d) ?? null);
  return out;
}
function best(rows: DayRow[], k: keyof DayRow, label: (d: string) => string) {
  const top = rows.filter((r) => r[k] != null).sort((a, b) => Number(b[k]) - Number(a[k]))[0];
  return top ? { label: label(top.period), kwh: r1(Number(top[k])) } : undefined;
}

async function plantCfg(plant: number) {
  const { data } = await db.from("plant_config").select("tariff_import, has_grid").eq("plant_id", plant).maybeSingle();
  return { tariff: Number(data?.tariff_import) || 0, hasGrid: data?.has_grid !== false };
}

/** Up to the 60 days SunSynk lets us backfill, ending yesterday, from the first day
 *  that has readings. Null when there is no solar in them. */
async function buildHistory(p: Plant): Promise<History | null> {
  const today = local(p.tz).date;
  const to = addDays(today, -1);
  const rows = (await dayEnergy(p.id, addDays(today, -60), to)).filter(hasData);
  if (!rows.length) return null;
  const from = rows.reduce((d, r) => (r.period < d ? r.period : d), to);
  const bestDay = best(rows, "pv_kwh", (d) => fmtDay(d, { day: "numeric", month: "short" }));
  if (!bestDay) return null;
  const { hasGrid } = await plantCfg(p.id);
  const home = sum(rows, "load_kwh"), imp = sum(rows, "imp_kwh");
  const short = (d: string) => fmtDay(d, { day: "numeric", month: "short" });
  return {
    plant: p.name, plantId: p.id, days: Math.round((Date.parse(to) - Date.parse(from)) / 86400e3) + 1, from: short(from), to: short(to),
    daily: perDay(rows, from, to, "pv_kwh"), madeKwh: sum(rows, "pv_kwh"), homeKwh: home,
    independencePct: independence(home, imp), importKwh: hasGrid ? imp : null,
    bestDay, highestUse: best(rows, "load_kwh", short),
  };
}

/** The finished week, month or year before `today`, against the one before it. Null when it has no readings. */
// freeFrom: the free week's first day; the day-7 report covers that week (SOLAR-475, 0182).
async function buildReport(p: Plant, period: Period, today: string, linkedOn?: string, freeFrom?: string): Promise<Report | null> {
  let from: string, to: string, pFrom: string, pTo: string, label: string, prevLabel: string;
  const [y, m] = today.split("-").map(Number);
  if (period === "week") {
    to = freeFrom ? addDays(freeFrom, 6) : addDays(today, -((new Date(today + "T00:00:00Z").getUTCDay() + 6) % 7 + 1)); from = addDays(to, -6);
    pTo = addDays(from, -1); pFrom = addDays(pTo, -6);
    label = `${fmtDay(from, { day: "numeric", ...(from.slice(5, 7) !== to.slice(5, 7) ? { month: "short" } : {}) })} – ${fmtDay(to, { day: "numeric", month: "short", year: "numeric" })}`;
    prevLabel = "last week";
  } else if (period === "month") {
    from = new Date(Date.UTC(y, m - 2, 1)).toISOString().slice(0, 10); to = addDays(`${today.slice(0, 7)}-01`, -1);
    pFrom = new Date(Date.UTC(y, m - 3, 1)).toISOString().slice(0, 10); pTo = addDays(from, -1);
    label = fmtDay(from, { month: "long", year: "numeric" }); prevLabel = fmtDay(pFrom, { month: "long" });
  } else {
    from = `${y - 1}-01-01`; to = `${y - 1}-12-31`; pFrom = `${y - 2}-01-01`; pTo = `${y - 2}-12-31`;
    label = String(y - 1); prevLabel = String(y - 2);
  }
  const all = await dayEnergy(p.id, pFrom, to);
  // A plant added partway through counts from the day it was added, not from its 60-day
  // import, and has no earlier period of its own to compare with (SOLAR-305).
  const start = linkedOn && linkedOn > from ? linkedOn : from;
  const cur = all.filter((r) => r.period >= start && hasData(r));
  const prev = start > from ? [] : all.filter((r) => r.period <= pTo && hasData(r));
  if (!cur.length) return null;
  const { tariff, hasGrid } = await plantCfg(p.id);
  const made = sum(cur, "pv_kwh"), home = sum(cur, "load_kwh"), imp = sum(cur, "imp_kwh");
  const pMade = sum(prev, "pv_kwh"), pHome = sum(prev, "load_kwh"), pImp = sum(prev, "imp_kwh");
  const saved = (h: number, i: number) => Math.max(0, h - i) * tariff;
  const dayLabel = (d: string) => fmtDay(d, period === "week" ? { weekday: "short", day: "numeric", month: "short" } : { day: "numeric", month: "short" });
  const days = perDay(cur, from, to, "pv_kwh");
  let daily: Report["daily"];
  if (period === "year") {
    const months = Array.from({ length: 12 }, (_, i) => cur.filter((r) => Number(r.period.slice(5, 7)) === i + 1));
    daily = { from: "Jan", to: "Dec", values: months.map((ms) => (ms.length ? r1(sum(ms, "pv_kwh")) : null)), labels: [..."JFMAMJJASOND"] };
  } else {
    const dates = Array.from({ length: days.length }, (_, i) => addDays(from, i));
    daily = {
      from: dayLabel(from), to: dayLabel(to), values: days,
      labels: period === "week" ? dates.map((d) => fmtDay(d, { weekday: "short" })) : dates.map((_, i) => (i % 7 === 0 ? String(i + 1) : "")),
      titles: dates.map((d, i) => `${dayLabel(d)}: ${days[i] == null ? "no data" : days[i] + " kWh"}`),
    };
  }
  const hasPrev = prev.length > 0;
  // History that starts after the period starts gets a note (SOLAR-273).
  const first = cur.reduce((d, r) => (r.period < d ? r.period : d), to);
  return {
    ...(first > from ? { partialFrom: fmtDay(first, { day: "numeric", month: "short" }), partialWhy: start > from ? "added" as const : "history" as const } : {}),
    plantId: p.id, period, label, prevLabel, plant: p.name,
    madeKwh: made, homeKwh: home, importKwh: hasGrid ? imp : null, exportKwh: null,
    independencePct: independence(home, imp), savedRand: tariff > 0 ? saved(home, imp) : null,
    change: hasPrev ? {
      made: pct(made, pMade), home: pct(home, pHome), import: pct(imp, pImp),
      independence: pct(independence(home, imp), independence(pHome, pImp)),
      ...(tariff > 0 ? { saved: pct(saved(home, imp), saved(pHome, pImp)) } : {}),
    } : {},
    ...(hasPrev ? { was: { made: pMade, home: pHome, import: pImp, independence: independence(pHome, pImp),
                           ...(tariff > 0 ? { saved: saved(pHome, pImp) } : {}) } } : {}),
    bestDay: best(cur, "pv_kwh", dayLabel), highestUse: best(cur, "load_kwh", dayLabel), daily,
  };
}

/** A report waits while the plant's history is still loading or the user's 60-days
 *  email hasn't gone, so it isn't built from a few days (SOLAR-273). Two days on it
 *  goes anyway: a plant whose history never finishes still gets its reports. */
async function historyPending(row: Row): Promise<boolean> {
  if (!row.user_id || !row.plant_id || local(row.tz).date > addDays(row.data.today, 2)) return false;
  const [{ data: link }, { data: cfg }, { count }] = await Promise.all([
    db.from("plant_users").select("linked_at").eq("user_id", row.user_id).eq("plant_id", row.plant_id).maybeSingle(),
    db.from("plant_config").select("backfill_next").eq("plant_id", row.plant_id).maybeSingle(),
    db.from("email_queue").select("id", { count: "exact", head: true }).eq("user_id", row.user_id).eq("plant_id", row.plant_id)
      .eq("kind", "history").in("status", ["queued", "sending"]),
  ]);
  // Right after a link the import bookmark isn't set yet and reads as done.
  return (link != null && Date.now() - Date.parse(link.linked_at) < 600e3) || cfg?.backfill_next != null || (count ?? 0) > 0;
}

/** The 60-days email waits for the plant's day totals (plant_energy). Without them
 *  it counts only the 15 days agg_minute covers (SOLAR-522). Two hours after it was
 *  queued it goes anyway. */
export const HISTORY_HOLD_MS = 2 * 3600e3;
export const historyHeld = (dayRows: number, queuedAt: string, now = Date.now()) =>
  dayRows === 0 && now - Date.parse(queuedAt) < HISTORY_HOLD_MS;

async function historyWaits(row: Row): Promise<boolean> {
  const [{ count }, { data: q }] = await Promise.all([
    db.from("plant_energy").select("plant_id", { count: "exact", head: true }).eq("plant_id", row.plant_id).eq("bucket", "day"),
    db.from("email_queue").select("created_at").eq("id", row.id).maybeSingle(),
  ]);
  return !!q && historyHeld(count ?? 0, q.created_at);
}

// The runtime keeps the isolate for this after the response.
const background = (p: Promise<unknown>) => (globalThis as any).EdgeRuntime?.waitUntil?.(p);

/** Runs the day sync again for a plant whose link kick wrote no day totals. */
const resync = (plant: number) => background(
  db.functions.invoke(`sync-plant-energy?plant=${plant}`, { body: {} })
    .then(({ error }) => { if (error) throw error; })
    .catch((e) => noteError("history_resync_failed", e, { plant, hourly: true })));

// ------------------------------------------------------------------- building

export type Row = {
  id: number; user_id: string | null; to_email: string; plant_id: number | null; plant_name: string | null; tz: string;
  kind: string; key: string; data: Record<string, any>; tries: number; switch: string | null; unsub_token: string | null;
  batch_key: string | null;
};

// The page that turns offers and reminders off, by email_claim's token (SOLAR-569).
const unsubOf = (r: Row) => `${APP}/unsubscribe.html?t=${r.unsub_token ?? ""}&k=reminders`;

/** The email for one queued row; null = nothing to say (an empty report), skip it. */
async function build(r: Row): Promise<Email | null> {
  const d = r.data, tz = r.tz;
  const p: Plant = { id: r.plant_id ?? 0, name: r.plant_name || "your plant", tz };
  const ev = (e: PlantEvent, at: number | null) => plantEvent(p.name, p.id, e, at == null ? "today" : dayOf(at, tz));
  switch (r.kind) {
    case "grid_down": return ev({ kind: "grid_down", at: hhmm(d.since, tz), from: d.from == null ? undefined : hhmm(d.from, tz), chargePct: d.chargePct ?? undefined }, d.since);
    case "grid_back": return ev({ kind: "grid_back", since: hhmm(d.since, tz), at: hhmm(d.at, tz), lasted: lasted(d.since, d.at),
      chargePct: (await socAt(p.id, d.at)) ?? undefined }, d.at);
    case "batt_hot":
      // Counted only when the email goes: a 30-day scan, not one per minute while it stays hot.
      return ev({ kind: "batt_hot", at: hhmm(d.at, tz), tempC: d.tempC, hotDays: await rpc<number>("email_hot_days", { p_plant: p.id }) }, d.at);
    // Kept in the app's bell, no email (SOLAR-415).
    case "batt_hot_back": case "bank_drift_back": return null;
    case "bank_drift": return ev({ kind: "bank_drift", banks: d.banks }, null);
    case "string_back": return ev({ kind: "string_back", string: d.string, inverter: d.inverter, since: hhmm(d.since, tz), at: hhmm(d.at, tz), lasted: lasted(d.since, d.at) }, d.at);
    case "string_dead": return ev({ kind: "string_dead", string: d.string, inverter: d.inverter, since: hhmm(d.since, tz) }, d.since);
    case "logger_stale": {
      // Every inverter by serial with its last reading, so the owner sees which one stopped
      // (SOLAR-415, 0162). The whole plant's alert shows each one's own last time.
      const invs = await rpc<{ sn: string; last_dev: number | null }[]>("email_plant_inverters", { p_plant: p.id });
      const stale = d.inverter ? String(r.key).split(":")[2] : null; // logger_stale:<plant>:<sn>:<last_dev>
      // One stopped: the others send ("null"). The whole plant stopped: each its own last time.
      // the one that stopped by serial, as in the list and its Readings back (SOLAR-560)
      return ev({ kind: "logger_stale", since: hhmm(d.since, tz), inverter: stale ? `Inverter ${stale}` : undefined,
        inverters: invs.map((i) => ({ name: `Inverter ${i.sn}`,
          last: stale ? (i.sn === stale ? hhmm(d.since, tz) : null) : hhmm(i.last_dev ?? d.since, tz) })) }, d.since);
    }
    case "logger_back": {
      const sn = d.inverter ? String(r.key).split(":")[2] : null; // logger_back:<plant>:<sn>:<last_dev>
      return ev({ kind: "logger_back", since: hhmm(d.since, tz), at: hhmm(d.at, tz), lasted: lasted(d.since, d.at),
        inverter: sn ? `Inverter ${sn}` : undefined }, d.at);
    }
    // one email per login, naming it and every plant on it (0158); old rows have neither
    case "needs_relink": return loginEvent({ kind: "needs_relink", plants: d.plants ?? (r.plant_name ? [r.plant_name] : []),
      at: d.since == null ? undefined : hhmm(d.since, tz) }, p.id, d.since == null ? "today" : dayOf(d.since, tz));
    case "relinked": return loginEvent({ kind: "relinked", plants: d.plants ?? [], since: d.since == null ? undefined : hhmm(d.since, tz), at: hhmm(d.at, tz),
      lasted: lasted(d.since, d.at) }, p.id, dayOf(d.at, tz));
    case "share_removed": return loginEvent({ kind: "share_removed", plants: d.plants ?? [] }, p.id);
    case "plant_off_login": return loginEvent({ kind: "plant_off_login", plants: d.plants ?? [], login: d.login ?? undefined }, p.id);
    case "share_down": return loginEvent({ kind: "share_down", plants: d.plants ?? [], at: hhmm(d.since, tz) }, p.id, dayOf(d.since, tz));
    case "share_back": return loginEvent({ kind: "share_back", plants: d.plants ?? [], since: hhmm(d.since, tz), at: hhmm(d.at, tz),
      lasted: lasted(d.since, d.at) }, p.id, dayOf(d.at, tz));
    case "sunsynk_down": return sunsynkDown(p.name, p.id, hhmm(d.since, tz), dayOf(d.since, tz));
    case "sunsynk_back": return sunsynkBack(p.name, p.id, hhmm(d.since, tz), hhmm(d.at, tz), lasted(d.since, d.at), dayOf(d.at, tz));
    case "welcome": return welcome();
    case "history": { const h = await buildHistory(p); return h && historySynced(h); }
    case "report_week": case "report_month": case "report_year": {
      const { data: pu } = await db.from("plant_users").select("linked_at").eq("user_id", r.user_id).eq("plant_id", r.plant_id).maybeSingle();
      const linkedOn = pu?.linked_at ? new Date(pu.linked_at).toLocaleDateString("en-CA", { timeZone: tz }) : undefined;
      const free = d.freeWeekEnds === true;
      const rep = await buildReport(p, r.kind.slice(7) as Period, d.today, linkedOn, free ? d.from : undefined);
      // The free week's day-7 report (0114) says the week has ended (SOLAR-475).
      if (!free) return rep && report(rep);
      const fw = await pickedPlan(d.plants, r.user_id);
      // No readings in the free week: the notice still goes, without the report. It sits
      // behind Offers and reminders (0214), so the plan and the link always go in.
      const end = { price: fw, unsub: unsubOf(r) };
      return rep ? report({ ...rep, freeWeekEnds: end }) : freeWeekEnded(end);
    }
    case "free_week_soon":
      return freeWeekEndsSoon(new Date(d.endsAt * 1000).toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "short", timeZone: tz }).replace(/\bSept\b/, "Sep"),
        await pickedPlan(d.plants, r.user_id), unsubOf(r));
    case "unpaid_reminder": case "unpaid_last": case "unpaid_deleted": {
      const u = { price: await pickedPlan(d.plants, r.user_id), paid: d.paid === true,
        unsub: unsubOf(r) };
      if (r.kind === "unpaid_deleted") return unpaidDeleted(u);
      const k = { ...u, since: dayMonth(local(tz, new Date(d.since * 1000)).date), deleteOn: dayMonth(local(tz, new Date(d.deleteAt * 1000)).date) };
      return r.kind === "unpaid_reminder" ? unpaidReminder(k) : unpaidLast(k);
    }
    case "free_week_setup": return d.steps?.length ? freeWeekSetup(d.steps, r.plant_id ?? undefined, d.battery !== false) : null;
    case "account_deleted": return accountDeleted(r.to_email);
    // Billing (0116): amounts in whole rand, dates as "2026-11-01".
    case "bill_paid":
      return paymentReceived({
        plan: d.plan, period: d.period, amount: d.amount, date: day(d.date), card: d.card, reference: d.reference,
        covers: covers(d.date, addDays(d.nextDate, -1)),
        extraPlants: d.extra > 0 ? { n: d.extra, each: d.extraEach } : undefined,
        next: { amount: d.nextAmount, date: day(d.nextDate) },
      });
    case "bill_upgraded":
      // Extra plants left pricing (SOLAR-371): an old extra-plants row sends nothing.
      if (d.from === d.to) return null;
      return planUpgraded({
        from: d.from, to: d.to, period: d.period, addedPlants: d.from === d.to ? d.added : undefined,
        paidNow: d.amount, daysLeft: d.daysLeft, credit: d.credit ?? undefined, next: { amount: d.nextAmount, date: day(d.nextDate) },
        card: (await billFacts(r.user_id))?.card ?? undefined, reference: d.reference,
      });
    case "bill_switched":
      return planSwitched({
        plan: d.plan, period: "yearly", amount: d.amount, date: day(d.date), card: d.card, reference: d.reference,
        extraPlants: d.extra > 0 ? { n: d.extra, each: d.extraEach } : undefined,
        startsOn: day(d.startsOn), next: { amount: d.nextAmount, date: day(d.nextDate) },
        covers: covers(d.startsOn, addDays(d.nextDate, -1)),
      });
    case "bill_change": {
      // The plants that stay: the user's others still collecting (SOLAR-415); stopped ones are not kept (SOLAR-488).
      const { data: pus } = await db.from("plant_users").select("plant_name").eq("user_id", r.user_id)
        .in("plant_id", await chosenPlants(r.user_id)).order("linked_at");
      const keep = (pus ?? []).map((x) => x.plant_name ?? "").filter((n) => n && !(d.removePlants ?? []).includes(n));
      return planChangeBooked({ keepPlants: keep,
        from: d.from, to: d.to, fromPeriod: d.fromPeriod, toPeriod: d.toPeriod, on: day(d.on),
        removePlants: d.removePlants, deleteOn: d.deleteOn ? day(d.deleteOn) : undefined, next: d.to === "free" ? undefined : { amount: d.nextAmount },
        days: (await historyOf(r.user_id, d.removePlants ?? [])).days,
        // Cancel to Free: history is deleted on the end date (SOLAR-495).
        history: d.to === "free" ? await historyAt(r.user_id).then((h) => h ? { ...h, on: day(d.on) } : undefined) : undefined,
      });
    }
    case "bill_kept": {
      // What was undone: the change booked last, from its own email (SOLAR-415).
      const booked = await lastMail(r.user_id, "bill_change", r.id);
      return planKept({ plan: d.plan, period: d.period, next: { amount: d.nextAmount, date: day(d.on) },
        undone: booked ? { to: booked.to, toPeriod: booked.toPeriod } : undefined });
    }
    case "bill_failed":
      return paymentFailed({
        plan: d.plan, period: d.period, amount: d.amount,
        nextTry: d.nextTry ? day(d.nextTry) : undefined, freeOn: day(d.freeOn), payUrl: PAY_URL,
        disputed: d.disputed ? day(d.disputed) : undefined,
      });
    case "bill_refund":
      return paymentRefunded({ amount: Number(d.amount), date: day(d.date), reference: d.reference,
        why: d.why === "price" || d.why === "hand" ? d.why : "changed", paid: d.paid ?? undefined,
        card: (await billFacts(r.user_id))?.card ?? undefined });
    case "bill_mail_failed":
      return billMailFailed({ kind: String(d.kind), key: String(d.key), user: String(d.user ?? ""), error: String(d.error ?? "") });
    case "bill_free":
      return movedToFree({ from: d.from, deleteOn: day(d.deleteOn),
        amount: (await lastMail(r.user_id, "bill_failed", r.id))?.amount ?? undefined,
        price: { ...await priceOf(d.from, r.user_id), plants: d.plants } });
    case "bill_removal_soon": {
      // The next plan up keeps them: no plan to Home if 2 plants fit, else Family.
      const plan = (await billFacts(r.user_id))?.plan;
      const up = plan === "free" ? (d.plants.length + 1 <= 2 ? "home" : "family") : plan === "home" ? "family" : null;
      return plantsRemovalSoon(d.plants, day(d.on), plan, up ? await priceOf(up, r.user_id) : undefined, (await historyOf(r.user_id, d.plants)).days);
    }
    case "bill_renewal_notice":
      return renewalNotice({ plan: d.plan, amount: d.amount, on: day(d.on), card: (await billFacts(r.user_id))?.card ?? undefined,
        change: d.changed ? "Your plan changes on that date, as you booked." : undefined });
    case "bill_offer_ends":
      return offerEnds({ plan: d.plan, period: d.period, was: d.was, amount: d.amount, on: day(d.on), card: d.card ?? undefined });
    // SOLAR-406 (0161)
    case "bill_card_changed":
      return cardChanged({ card: d.card, was: d.was ?? undefined, at: d.at ? `${dayOf(d.at, tz) === "today" ? "Today" : dayOf(d.at, tz)} at ${hhmm(d.at, tz)}` : undefined,
        next: d.nextDate ? { amount: d.nextAmount, date: day(d.nextDate) } : undefined });
    case "bill_card_expiring":
      return cardExpiring({ card: d.card, on: day(d.on), final: d.final === true,
        days: Math.round((Date.parse(d.on) - Date.parse(local("Africa/Johannesburg").date)) / 86400e3), next: { amount: d.nextAmount, date: day(d.nextDate) } });
    case "winback": {
      // every plant still reading loses its history, not only the first (d.days, 0206; SOLAR-616)
      const h = await historyOf(r.user_id);
      return winback({ from: d.from, plant: h.plants[0], plants: h.plants.length, days: h.days, price: await priceOf(d.from, r.user_id),
        deleteOn: d.deleteOn ? dayMonth(d.deleteOn) : undefined, unsub: unsubOf(r) });
    }
    case "bill_cancel_soon":
      return cancelEndsSoon({ from: d.from, on: day(d.on), ...await historyOf(r.user_id).then((h) => ({ days: h.days, plants: h.plants.length })),
        deleteOn: dayMonth(addDays(d.on, 30)) });
    case "need_a_hand": return needAHand(d.choose === true);
    case "feedback":
      return feedback({ email: String(d.email ?? ""), message: String(d.message ?? ""), page: String(d.page ?? ""),
        version: String(d.version ?? ""), user: String(d.user ?? ""), image: !!d.image });
  }
  throw new Error(`unknown kind ${r.kind}`);
}

// ------------------------------------------------------------------- sending

export type Out = { row: Row; mail: Email };
type Done = {
  id: number; status: "sent" | "queued" | "failed" | "skipped"; error?: string; retry_s?: number;
  batch_key?: string; refund?: boolean;
};

// Temporary failures wait 1, 2, 4 ... 60 minutes; after MAX_TRIES the row fails.
const MAX_TRIES = 8;
const retry = (row: Row, error: string, batch_key?: string): Done =>
  row.tries >= MAX_TRIES ? { id: row.id, status: "failed", error }
    : { id: row.id, status: "queued", error, retry_s: Math.min(3600, 60 * 2 ** (row.tries - 1)), batch_key };
// Not tried at all (the run ran out of time): back at once, not counted as a try.
const later = (row: Row): Done => ({ id: row.id, status: "queued", error: "run out of time", retry_s: 0, refund: true });
// Resend: 400 and 422 are the email itself (bad address, bad field), so it will
// never pass. Anything else (429, 5xx, a network failure, and our own 401/403/404
// from a bad key or address) is retried, and fails only after MAX_TRIES.
const refused = (status: number) => status === 400 || status === 422;

// Feedback (SOLAR-428): a reply goes to the user who sent it, with their screenshot attached.
const fb = (o: Out) => o.row.kind === "feedback";
const payload = (o: Out) => {
  return { from: senderFor(o.row.kind), reply_to: fb(o) && o.row.data.email ? o.row.data.email : REPLY_TO, to: [o.row.to_email],
           subject: o.mail.subject, html: o.mail.html, text: o.mail.text,
           ...(fb(o) && o.row.data.image ? { attachments: [{ filename: "screenshot.jpg", content: o.row.data.image }] } : {}) };
};

async function post(url: string, body: unknown, key: string): Promise<{ status: number; error?: string; retryAfter?: string | null }> {
  // A network failure comes back as a status too, so the rows are retried.
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json", "Idempotency-Key": key },
      body: JSON.stringify(body),
    });
    return res.ok ? { status: res.status } : { status: res.status, error: `resend ${res.status}: ${(await res.text()).slice(0, 200)}`,
                                               retryAfter: res.headers.get("Retry-After") };
  } catch (e) {
    return { status: 0, error: `resend: ${e instanceof Error ? e.message : e}` };
  }
}

// Resend allows a few calls a second; batches of up to 100 keep a burst inside it. One pace
// for every Resend call in a run; a 429 holds them all until its Retry-After (SOLAR-645).
const pacer = new Pacer(PACE_MS);

/** One batch call. When Resend refuses it, each half again, down to the one email
 *  it refuses, so a bad address fails only itself and costs ~14 calls, not 100. */
export async function sendBatch(outs: Out[], deadline: number, reuse?: string): Promise<Done[]> {
  if (!outs.length) return [];
  if (Date.now() > deadline) return outs.map((o) => later(o.row));
  // A retry goes under the key its batch had: if Resend took that batch before the
  // answer was lost, it answers from that and sends nothing twice.
  const ids = new TextEncoder().encode(outs.map((o) => o.row.id).join("."));
  const key = reuse ?? "q-" + [...new Uint8Array(await crypto.subtle.digest("SHA-256", ids))].map((b) => b.toString(16).padStart(2, "0")).join("");
  // Resend's batch call takes no attachments, so feedback goes on its own (one per group, see run).
  const one = outs.length === 1 && fb(outs[0]);
  if (!await pacer.slot(deadline)) return outs.map((o) => later(o.row));
  const res = await (one ? post(RESEND_URL, payload(outs[0]), key) : post(`${RESEND_URL}/batch`, outs.map(payload), key));
  if (!res.error) return outs.map((o) => ({ id: o.row.id, status: "sent" }));
  // Too many calls: nothing was sent. Back after Retry-After, under the same key, not counted as a try.
  if (res.status === 429) {
    pacer.hold(res.retryAfter);
    noteError("resend_429", new Error(res.error), { hourly: true });
    const retry_s = Math.ceil(retryAfterMs(res.retryAfter, Date.now()) / 1000);
    return outs.map((o) => ({ id: o.row.id, status: "queued", error: res.error, retry_s, batch_key: key, refund: true }));
  }
  // 409: the old key was used with a different body (the batch changed since); a fresh one.
  if (res.status === 409 && reuse) return await sendBatch(outs, deadline);
  // A refusal ends as a failed row, which run() reports as email_failed: one report, not two (SOLAR-471).
  if (!refused(res.status)) {
    noteError(`resend_${res.status || "network"}`, new Error(res.error), { hourly: true });
    return outs.map((o) => retry(o.row, res.error!, key));
  }
  if (outs.length === 1) return [{ id: outs[0].row.id, status: "failed", error: res.error }];
  const half = Math.ceil(outs.length / 2);
  return [...await sendBatch(outs.slice(0, half), deadline), ...await sendBatch(outs.slice(half), deadline)];
}

// ------------------------------------------------------------------- pop-ups

type PushRow = {
  id: number; kind: string; plant_id: number; title: string; body: string; tab: string; day: string | null;
  subs: { endpoint: string; p256dh: string; auth: string }[];
};

let pushServer: Promise<webpush.ApplicationServer> | null = null;
// A key that fails to load is tried again next run, not kept as a failure.
const server = () => pushServer ??= webpush.importVapidKeys(JSON.parse(VAPID_KEYS)).then((vapidKeys) =>
  webpush.ApplicationServer.new({ contactInformation: "mailto:hello@princesolarhub.co.za", vapidKeys }))
  .catch((e) => { pushServer = null; throw e; });

// The push services browsers issue addresses on; the same test as push_subs_endpoint_ok (0194).
const PUSH_HOST =
  /^https:\/\/(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)\/\S+$/;

/** One pop-up to one browser: "ok", "gone" (delete it), or "failed" (left as is). */
async function pushOne(r: PushRow, s: PushRow["subs"][number]): Promise<"ok" | "gone" | "failed"> {
  // A row saved before 0194 can hold any address: never call it, and remove it.
  if (!PUSH_HOST.test(s.endpoint)) return "gone";
  // data is fields, not a link, so the phone apps can map them to their own screens.
  // tag: a Grid back replaces its Grid down on screen, per plant.
  const msg = JSON.stringify({
    title: r.title, body: r.body, tag: `${r.plant_id}:${r.kind === "relinked" ? "needs" : r.kind.split("_")[0]}`,
    // a login's pop-up opens Account on the logins, where Reconnect is (SOLAR-380)
    data: { id: r.id, tab: r.tab, plant: r.plant_id, day: r.day, section: r.tab === "account" ? "logins" : undefined },
  });
  try {
    // An alert an hour late is no longer news: the push service drops it after that.
    await (await server()).subscribe({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } })
      .pushTextMessage(msg, { ttl: 3600, urgency: webpush.Urgency.High });
    return "ok";
  } catch (e) {
    if (e instanceof webpush.PushMessageError && [404, 410].includes(e.response.status)) return "gone";
    console.error("push failed:", e instanceof webpush.PushMessageError ? e.toString() : e);
    // Status only: the push service's answer names the browser's endpoint.
    noteError("push_failed", e instanceof webpush.PushMessageError ? new Error(`push service ${e.response.status}`) : e,
      { plant: r.plant_id, hourly: true });
    return "failed";
  }
}

export async function pushPass(deadline: number) {
  const count = { ok: 0, gone: 0, failed: 0 };
  // Bad keys stop here, before push_claim marks anything done.
  await server();
  while (Date.now() < deadline) {
    const rows = await rpc<PushRow[]>("push_claim", { p_limit: 200 });
    if (!rows.length) break;
    const jobs = rows.flatMap((r) => r.subs.map((s) => [r, s] as const));
    const ok: string[] = [], gone: string[] = [];
    for (let i = 0; i < jobs.length; i += PUSH_AT_ONCE) {
      const res = await Promise.all(jobs.slice(i, i + PUSH_AT_ONCE).map(([r, s]) => pushOne(r, s)));
      res.forEach((x, j) => {
        count[x]++;
        if (x === "ok") ok.push(jobs[i + j][1].endpoint);
        if (x === "gone") gone.push(jobs[i + j][1].endpoint);
      });
    }
    await rpc("push_done", { p_ok: ok, p_gone: gone });
  }
  return count;
}

// Pop-ups through the outbox (SOLAR-645 step 3, 0261): msg_push_take hands over one send per
// device under a claim; msg_push_done takes each push service status back. The database
// decides from it: 2xx sent, 404/410 device removed, 429/5xx/0 tried again inside the hour.
export type PushSend = {
  id: number; claim: string; event_id: number; kind: string; plant_id: number; title: string; body: string;
  tab: string; day: string | null; endpoint: string; p256dh: string; auth: string;
};
export type PushResult = { id: number; code: number; retry_s?: number; error?: string };
type Deliver = (s: PushSend, msg: string) => Promise<unknown>;

const deliver: Deliver = async (s, msg) =>
  (await server()).subscribe({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } })
    .pushTextMessage(msg, { ttl: 3600, urgency: webpush.Urgency.High });

/** One send: the push service's status (0 = no answer), and its Retry-After in seconds. */
export async function pushSend(s: PushSend, send: Deliver = deliver): Promise<PushResult> {
  if (!PUSH_HOST.test(s.endpoint)) return { id: s.id, code: 410, error: "bad address" };
  const msg = JSON.stringify({
    title: s.title, body: s.body, tag: `${s.plant_id}:${s.kind === "relinked" ? "needs" : s.kind.split("_")[0]}`,
    data: { id: s.event_id, tab: s.tab, plant: s.plant_id, day: s.day, section: s.tab === "account" ? "logins" : undefined },
  });
  try {
    await send(s, msg);
    return { id: s.id, code: 201 };
  } catch (e) {
    if (!(e instanceof webpush.PushMessageError)) {
      noteError("push_failed", e, { plant: s.plant_id, hourly: true });
      return { id: s.id, code: 0, error: String(e instanceof Error ? e.message : e).slice(0, 200) };
    }
    const code = e.response.status;
    if (code !== 404 && code !== 410) {
      noteError("push_failed", new Error(`push service ${code}`), { plant: s.plant_id, hourly: true });
    }
    const after = e.response.headers.get("retry-after");
    return { id: s.id, code, error: `push service ${code}`,
             ...(after ? { retry_s: Math.ceil(retryAfterMs(after, Date.now()) / 1000) } : {}) };
  }
}

type Rpc = <T>(fn: string, args?: Record<string, unknown>) => Promise<T>;
export async function outboxPushPass(deadline: number, call: Rpc = rpc, send: Deliver = deliver) {
  const count = { ok: 0, gone: 0, again: 0, failed: 0 };
  if (send === deliver) await server();   // bad keys stop here, before anything is leased
  while (Date.now() < deadline) {
    const rows = await call<PushSend[]>("msg_push_take", { p_limit: 200 });
    if (!rows.length) break;
    const res: PushResult[] = [];
    for (let i = 0; i < rows.length; i += PUSH_AT_ONCE) {
      res.push(...await Promise.all(rows.slice(i, i + PUSH_AT_ONCE).map((s) => pushSend(s, send))));
    }
    for (const r of res) {
      const k = r.code >= 200 && r.code < 300 ? "ok" : r.code === 404 || r.code === 410 ? "gone"
        : r.code === 0 || r.code === 429 || r.code >= 500 ? "again" : "failed";
      count[k]++;
    }
    await call("msg_push_done", { p_claim: rows[0].claim, p_results: res });
  }
  return count;
}

// ------------------------------------------------------------------- billing outbox (SOLAR-641)

// billing.outbox (0247): billing, free-week and history emails. outbox_take hands over the rows
// due with the account's state read now (stale ones are dropped there by each kind's guard);
// the words come from the text catalog; a receipt reads its frozen bill.
type OutboxRow = MailInput & { id: number; user: string; email: string; unsub_token: string | null; reminder: boolean };
const OUTBOX_BATCH = 50;
/** Takes due rows while before `until`; sends until `deadline`. */
export async function outboxPass(until: number, deadline = until) {
  const count = { sent: 0, failed: 0, retried: 0 };
  await rpc("billing_jobs", { p_cmd: "outbox_sweep" }).catch((e) => noteError("outbox_sweep_failed", e, { hourly: true }));
  while (Date.now() < until) {
    const rows = await rpc<OutboxRow[]>("billing_jobs", { p_cmd: "outbox_take", p_args: { limit: OUTBOX_BATCH } });
    if (!rows.length) break;
    const outs: { row: OutboxRow; payload: Record<string, unknown> }[] = [];
    for (const row of rows) {
      const m = accountMail(row);
      if (!m) {
        await rpc("billing_jobs", { p_cmd: "outbox_done", p_args: { id: row.id, ok: false, error: "nothing to say" } });
        count.failed++;
        continue;
      }
      const unsub = row.unsub_token ? `${APP}/unsubscribe.html?t=${row.unsub_token}&k=reminders` : undefined;
      const e = outboxMail(m, unsub);
      outs.push({ row, payload: { from: row.reminder ? FROM_HELLO : FROM_BILLING, reply_to: REPLY_TO, to: [row.email],
        subject: e.subject, html: e.html, text: e.text,
        ...(row.reminder && unsub ? { headers: { "List-Unsubscribe": `<${unsub}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" } } : {}) } });
    }
    // One call per email under its row's own key: a retry after a lost answer, whatever else
    // is due then, is answered from the first send and sends nothing twice.
    let stop = false;
    for (const o of outs) {
      // left leased: sent on a later pass. No slot (a 429 held past the deadline): take no more.
      if (stop) break;
      if (!await pacer.slot(deadline)) { stop = true; break; }
      const res = await sendOutboxOne(post, RESEND_URL, { id: o.row.id, payload: o.payload });
      const limited = res.status === 429;
      if (limited) pacer.hold(res.retryAfter);
      const ok = !res.error;
      // Resend refused the email itself (400, 422): given up; a 429 after its Retry-After, not
      // counted as a try (0257); anything else in 5 minutes
      const retry_s = ok || refused(res.status) ? null : limited ? Math.ceil(retryAfterMs(res.retryAfter, Date.now()) / 1000) : 300;
      await rpc("billing_jobs", { p_cmd: "outbox_done", p_args: { id: o.row.id, ok, error: res.error ?? null, retry_s, refund: limited } });
      if (ok) {
        count.sent++;
        await track("account_email_sent_done", o.row.user, `outbox:${o.row.id}`, new Date().toISOString(), { kind: o.row.key }).catch(() => {});
      } else if (retry_s) count.retried++;
      else { count.failed++; noteError("email_failed", new Error(`outbox ${o.row.key} ${o.row.id}: ${res.error}`), { user: o.row.user, hourly: true }); }
      if (res.error && !refused(res.status)) stop = true;
    }
    if (stop) break;
  }
  return count;
}

// ------------------------------------------------------------------- alert emails, outbox (SOLAR-645 step 4)

// msg_email_take (0262) leases due rows under one claim, after the guard at send time, with
// the event row's fields; the email is built by build(), as on the old path. Up to 100 go in
// one Resend batch call, its key saved on the rows first (msg_email_bind): a retry after a lost
// answer, or after this worker died, sends the same rows under the same key, and Resend answers
// from the first send. A row alone goes in its own call under ms-<id>. msg_email_done takes
// each answer back; the database decides from it.
export type MsgEmail = {
  id: number; claim: string; tries: number; batch_key: string | null; event_id: number; user_id: string | null;
  to_email: string; plant_id: number | null; plant_name: string | null; tz: string; kind: string; key: string;
  data: Record<string, any>;
};
export type MsgResult = {
  id: number; code?: number; retry_s?: number; error?: string; untried?: boolean; skip?: string; keep?: boolean;
};
const MSG_BATCH = 100;
let msgMissingNoted = false;
/** The RPC isn't there yet: the functions went out before the migration. */
export const missingRpc = (e: unknown) => /Could not find the function|PGRST202/.test(String((e as Error)?.message ?? e));

type Built = { m: MsgEmail; row: Row; mail: Email };
type Ctx = { stop: boolean; deadline: number; call: Rpc; postFn: Post; make: (r: Row) => Promise<Email | null>; newKey: () => string };

const rowOf = (m: MsgEmail): Row => ({ id: m.event_id, user_id: m.user_id, to_email: m.to_email, plant_id: m.plant_id,
  plant_name: m.plant_name, tz: m.tz, kind: m.kind, key: m.key, data: m.data ?? {}, tries: m.tries, switch: null,
  unsub_token: null, batch_key: null });

/** One Resend answer for the rows of one call. A 429 holds the pace; Resend in trouble (not a
 *  refusal, nor a 409 still in progress) stops the pass. keep: the call may have gone. */
function answer(ctx: Ctx, ids: number[], out: Awaited<ReturnType<Post>>, keep: boolean, what: string,
                user: string | null = null): MsgResult[] {
  if (!out.error) return ids.map((id) => ({ id, code: out.status }));
  if (out.status === 429) {
    pacer.hold(out.retryAfter);
    noteError("resend_429", new Error(out.error), { hourly: true });
  } else if (refused(out.status)) noteError("email_failed", new Error(`${what}: ${out.error}`), { user, hourly: true });
  else noteError(`resend_${out.status || "network"}`, new Error(out.error), { hourly: true });
  if (!refused(out.status) && out.status !== 409) ctx.stop = true;
  const retry_s = out.retryAfter ? Math.ceil(retryAfterMs(out.retryAfter, Date.now()) / 1000) : undefined;
  return ids.map((id) => ({ id, code: out.status, error: out.error, ...(retry_s !== undefined ? { retry_s } : {}),
                            ...(keep ? { keep: true } : {}) }));
}

/** A row alone, under ms-<id>. */
async function sendAlone(ctx: Ctx, b: Built): Promise<MsgResult> {
  if (ctx.stop || !await pacer.slot(ctx.deadline)) { ctx.stop = true; return { id: b.m.id, untried: true }; }
  const out = await sendOutboxOne(ctx.postFn, RESEND_URL, { id: b.m.id, payload: payload(b) }, msgKey(b.m.id));
  return answer(ctx, [b.m.id], out, false, `${b.m.kind} outbox ${b.m.id}`, b.m.user_id)[0];
}

/** One group: new rows (key null), or rows bound to `key` by an earlier call. A bound row
 *  only ever goes under its key, alone or with what is left of its group: Resend answers from
 *  the first send if it reached it (a smaller body gets 409 invalid_idempotent_request,
 *  counted as sent), else it is a first send. */
async function sendGroup(ctx: Ctx, g: MsgEmail[], key: string | null): Promise<MsgResult[]> {
  const bound = key !== null;
  const back = (ms: MsgEmail[]) => ms.map((m) => ({ id: m.id, untried: true, ...(bound ? { keep: true } : {}) }));
  if (ctx.stop || Date.now() > ctx.deadline) return back(g);
  const res: MsgResult[] = [], built: Built[] = [];
  for (const m of g) {
    const row = rowOf(m);
    let mail: Email | null;
    try {
      mail = await ctx.make(row);
    } catch (e) {
      noteError("email_build_failed", e, { user: m.user_id, hourly: true });
      const error = `build: ${e instanceof Error ? e.message : e}`.slice(0, 200);
      // tried again later; a bound row keeps its key and goes under it then
      res.push({ id: m.id, code: 0, error, ...(bound ? { keep: true } : {}) });
      continue;
    }
    if (!mail) { res.push({ id: m.id, skip: "nothing to say" }); continue; }
    built.push({ m, row, mail });
  }
  if (!built.length) return res;
  if (Date.now() > ctx.deadline) return [...res, ...back(built.map((b) => b.m))];
  // a bound row alone still goes in a batch call under its key, never under ms-<id>
  if (!bound && built.length === 1) return [...res, await sendAlone(ctx, built[0])];
  if (!await pacer.slot(ctx.deadline)) { ctx.stop = true; return [...res, ...back(built.map((b) => b.m))]; }
  const ids = built.map((b) => b.m.id);
  const k = key ?? ctx.newKey();
  if (!bound) {
    try {
      await ctx.call("msg_email_bind", { p_claim: g[0].claim, p_key: k, p_ids: ids });
    } catch (e) {
      noteError("msg_email_bind_failed", e, { hourly: true });
      return [...res, ...back(built.map((b) => b.m))];
    }
  }
  const out = await sendOutboxOne(ctx.postFn, `${RESEND_URL}/batch`, { id: ids[0], payload: built.map(payload) }, k);
  // Refused: Resend sent none of them. Each alone, so a bad address fails only itself.
  if (refused(out.status)) {
    const one: MsgResult[] = [];
    for (const b of built) one.push(await sendAlone(ctx, b));
    return [...res, ...one];
  }
  return [...res, ...answer(ctx, ids, out, true, `batch ${k}`)];
}

export async function msgEmailPass(until: number, deadline = until, call: Rpc = rpc, postFn: Post = post,
                                   make: (r: Row) => Promise<Email | null> = build,
                                   newKey = () => `mb-${crypto.randomUUID()}`) {
  const count = { sent: 0, again: 0, failed: 0, dropped: 0 };
  const ctx: Ctx = { stop: false, deadline, call, postFn, make, newKey };
  while (Date.now() < until) {
    let rows: MsgEmail[];
    try {
      rows = await call<MsgEmail[]>("msg_email_take", { p_limit: MSG_BATCH, p_lane: "urgent" });
    } catch (e) {
      if (!missingRpc(e)) throw e;
      if (!msgMissingNoted) noteError("msg_email_take_missing", e, { hourly: true });
      msgMissingNoted = true;
      return { ...count, missing: true };
    }
    if (!rows.length) break;
    // rows bound to a key go again together; new rows in calls of up to 100
    const groups = new Map<string, MsgEmail[]>(), fresh: MsgEmail[] = [];
    for (const m of rows) m.batch_key ? groups.set(m.batch_key, [...(groups.get(m.batch_key) ?? []), m]) : fresh.push(m);
    const res: MsgResult[] = [];
    for (const [key, g] of groups) res.push(...await sendGroup(ctx, g, key));
    for (let i = 0; i < fresh.length; i += MSG_BATCH) res.push(...await sendGroup(ctx, fresh.slice(i, i + MSG_BATCH), null));
    await call("msg_email_done", { p_claim: rows[0].claim, p_results: res });
    for (const r of res) {
      const c = r.code ?? 0;
      count[r.untried ? "again" : r.skip ? "dropped" : c >= 200 && c < 300 ? "sent" : refused(c) ? "failed" : "again"]++;
    }
    if (ctx.stop) break;
  }
  return count;
}

/** What only the clock can tell: no readings, SunSynk, reports. */
export const sweep = () => rpc<Record<string, unknown>>("email_sweep").catch((e) => {
  noteError("email_sweep_failed", e, { hourly: true });
  return { error: String(e?.message ?? e) };
});

/** Sends email_queue rows of one lane (0257: "urgent" = alerts, "bulk" = the rest, null =
 *  all) while claiming before `until`; what isn't sent by `deadline` goes back untouched. */
export async function emailPass(lane: "urgent" | "bulk" | null, until: number, deadline: number, dry: boolean, withHtml = false) {
  const lines: Record<string, unknown>[] = [];
  const count = { sent: 0, queued: 0, failed: 0, skipped: 0 };
  while (Date.now() < until) {
    // no lane: the old two-argument call, so the old notify works before and after 0257
    const rows = await rpc<Row[]>("email_claim", { p_limit: BATCH, p_peek: dry, ...(lane ? { p_lane: lane } : {}) });
    if (!rows.length) break;
    const outs: Out[] = [], done: Done[] = [];
    for (const row of rows) {
      // Reports cost two reads each; what isn't built in time goes back untouched.
      if (Date.now() > deadline) { done.push(later(row)); continue; }
      try {
        // The free week's report doesn't wait: it goes on the day the week ends (0182).
        if (row.kind.startsWith("report_") && row.data.freeWeekEnds !== true && !dry && await historyPending(row)) {
          done.push({ id: row.id, status: "queued", error: "waits for history", retry_s: 600, refund: true });
          continue;
        }
        // Checked every 10 minutes; each check runs the day sync again (SOLAR-522).
        if (row.kind === "history" && row.plant_id && await historyWaits(row)) {
          if (dry) lines.push({ kind: row.kind, key: row.key, held: "waits for day totals" });
          else {
            resync(row.plant_id);
            done.push({ id: row.id, status: "queued", error: "waits for day totals", retry_s: 600, refund: true });
          }
          continue;
        }
        const mail = await build(row);
        if (!mail) {
          // History waits for the day sync (plant_energy) to land: try again hourly.
          // An empty report is final.
          done.push(row.kind === "history" && row.tries < MAX_TRIES
            ? { id: row.id, status: "queued", error: "nothing to say yet", retry_s: 3600 }
            : { id: row.id, status: "skipped", error: "nothing to say" });
          continue;
        }
        outs.push({ row, mail });
        lines.push({ kind: row.kind, key: row.key, to: row.to_email, subject: mail.subject, ...(withHtml ? { html: mail.html } : {}) });
      } catch (e) {
        // One email that can't be built stops nothing else.
        done.push(retry(row, `build: ${e instanceof Error ? e.message : e}`));
        noteError("email_build_failed", e, { user: row.user_id, hourly: true });
      }
    }
    if (dry) break;  // a peek claims nothing, so the next read would be the same rows
    // Retries go in the batch they went in before, under its key; new rows in fresh batches.
    const groups = new Map<string, Out[]>();
    for (const o of outs) {
      const g = o.row.batch_key ?? (fb(o) ? `fb-${o.row.id}` : "");
      groups.set(g, [...(groups.get(g) ?? []), o]);
    }
    for (const [key, group] of groups) done.push(...await sendBatch(group, deadline, key || undefined));
    for (const x of done) count[x.status]++;
    // Given up for good: Resend refused it, or it failed MAX_TRIES times.
    for (const x of done.filter((d) => d.status === "failed")) {
      const row = rows.find((r) => r.id === x.id);
      noteError("email_failed", new Error(`${row?.kind ?? "email"} ${x.id}: ${x.error ?? ""}`), { user: row?.user_id ?? null, hourly: true });
    }
    await rpc("email_done", { p_results: done });
    // SOLAR-328: counted once it has gone, by user id only.
    for (const x of done) {
      const row = x.status === "sent" ? rows.find((r) => r.id === x.id) : undefined;
      if (row?.kind === "winback" && row.user_id) {
        await track("winback_email_sent_done", row.user_id, String(row.id), new Date().toISOString(), { plan: row.data.from });
      }
      // SOLAR-243: a paid plan ended. Each email goes once per end: a cancel that ran
      // out (winback, 0144) or a failed payment that ended it (bill_free).
      if ((row?.kind === "winback" || row?.kind === "bill_free") && row.user_id) {
        await track("plan_cancelled", row.user_id, String(row.id), new Date().toISOString(),
          { plan: row.data.from, reason: row.kind === "winback" ? "cancelled" : "unpaid" });
      }
      // SOLAR-475
      if (row?.kind === "report_week" && row.data.freeWeekEnds === true && row.user_id) {
        await track("free_week_ended_email_sent_done", row.user_id, String(row.id), new Date().toISOString(), {});
      }
      // SOLAR-552, SOLAR-559
      if (row?.kind.startsWith("unpaid_") && row.user_id) {
        await track(`${row.kind}_email_sent_done`, row.user_id, String(row.id), new Date().toISOString(), {});
      }
      // SOLAR-319
      if (row?.kind === "need_a_hand" && row.user_id) {
        await track("need_a_hand_email_sent_done", row.user_id, String(row.id), new Date().toISOString(), { choose: row.data?.choose === true });
      }
    }
    // Rows handed back unsent (out of time, or a 429 held past the deadline): claiming
    // again would only build the same rows again.
    if (done.some((x) => x.error === "run out of time")) break;
  }
  return { ...count, due: lines };
}

// The old single run (cron email-notify until 0257): kept so the switch can go back.
async function run(dry: boolean, withHtml: boolean, push: boolean) {
  const started = Date.now();
  const swept = dry ? null : await sweep();
  const { due, ...count } = await emailPass(null, started + BUDGET_MS, started + BUDGET_MS + 5_000, dry, withHtml);
  // alert emails routed to the outbox (0262), so going back to this run sends them too
  const alerts = dry ? null : await msgEmailPass(started + BUDGET_MS, started + BUDGET_MS + 5_000).catch((e) => {
    noteError("msg_email_pass_failed", e, { hourly: true });
    return { error: String(e?.message ?? e) };
  });
  const outbox = dry ? null : await outboxPass(started + BUDGET_MS + 5_000).catch((e) => {
    noteError("outbox_pass_failed", e, { hourly: true });
    return { error: String(e?.message ?? e) };
  });
  // The cron call times out at 55 s.
  const pushed = push ? await pushPass(started + 47_000).catch((e) => {
    noteError("push_pass_failed", e, { hourly: true });
    return { error: String(e?.message ?? e) };
  }) : null;
  // pop-ups routed to the outbox (0261), so going back to this run sends them too
  const pushedOutbox = push ? await outboxPushPass(started + 50_000).catch((e) => {
    noteError("push_outbox_failed", e, { hourly: true });
    return { error: String(e?.message ?? e) };
  }) : null;
  return { live: !dry, swept, ...count, alerts, outbox, pushed, pushedOutbox, due };
}

// Every template from one plant's real numbers; event values are samples.
async function renderAll(plantId: number, today?: string) {
  const { data: pu } = await db.from("plant_users").select("plant_name").eq("plant_id", plantId).limit(1).maybeSingle();
  if (!pu) throw new Error(`no users on plant ${plantId}`);
  const p: Plant = { id: plantId, name: pu.plant_name || "your plant", tz: await rpc<string>("plant_tz", { p_plant: plantId }) };
  const now = Math.floor(Date.now() / 1000);
  const out: Record<string, Email> = { welcome: welcome(), "need-a-hand-choose": needAHand(true), "account-deleted": accountDeleted("you@example.com") };
  const h = await buildHistory(p);
  if (h) out["history-synced"] = historySynced(h);
  today ??= local(p.tz).date;
  for (const period of ["week", "month", "year"] as Period[]) {
    const r = await buildReport(p, period, today);
    if (r) out[`report-${period}`] = report(r);
  }
  out["sunsynk-down"] = sunsynkDown(p.name, p.id, hhmm(now - 1500, p.tz));
  out["sunsynk-back"] = sunsynkBack(p.name, p.id, hhmm(now - 1500, p.tz), hhmm(now, p.tz), lasted(now - 1500, now));
  const ev: [string, PlantEvent][] = [
    ["grid-down", { kind: "grid_down", at: hhmm(now - 240, p.tz), chargePct: 62 }],
    ["grid-down-in-gap", { kind: "grid_down", from: hhmm(now - 3720, p.tz), at: hhmm(now - 240, p.tz), chargePct: 62 }],
    ["grid-back", { kind: "grid_back", since: hhmm(now - 5580, p.tz), at: hhmm(now, p.tz), lasted: lasted(now - 5580, now), chargePct: 41 }],
    ["battery-hot", { kind: "batt_hot", at: hhmm(now, p.tz), tempC: 47, hotDays: 3 }],
    ["batteries-uneven", { kind: "bank_drift", banks: [{ name: "Inverter 1", chargePct: 72 }, { name: "Inverter 2", chargePct: 60 }] }],
    ["panels-stopped", { kind: "string_dead", string: "String 3", inverter: "Inverter 1", since: hhmm(now - 1200, p.tz) }],
    ["panels-back", { kind: "string_back", string: "String 3", inverter: "Inverter 1", since: hhmm(now - 7800, p.tz), at: hhmm(now, p.tz), lasted: lasted(now - 7800, now) }],
    ["no-readings", { kind: "logger_stale", since: hhmm(now - 1200, p.tz) }],
    ["readings-back", { kind: "logger_back", since: hhmm(now - 6420, p.tz), at: hhmm(now, p.tz), lasted: lasted(now - 6420, now) }],
    ["inverter-no-readings", { kind: "logger_stale", since: hhmm(now - 1200, p.tz), inverter: "Inverter 2",
      inverters: [{ name: "Inverter 1", last: null }, { name: "Inverter 2", last: hhmm(now - 1200, p.tz) }] }],
  ];
  for (const [name, e] of ev) out[name] = plantEvent(p.name, p.id, e);
  out["reconnect"] = loginEvent({ kind: "needs_relink", plants: [p.name, "Second plant"], at: hhmm(now - 1500, p.tz) }, p.id);
  out["reconnected"] = loginEvent({ kind: "relinked", plants: [p.name, "Second plant"], since: hhmm(now - 7500, p.tz), at: hhmm(now, p.tz), lasted: lasted(now - 7500, now) }, p.id);
  out["sharing-stopped"] = loginEvent({ kind: "share_removed", plants: [p.name] }, p.id);
  out["plant-off-login"] = loginEvent({ kind: "plant_off_login", plants: [p.name], login: "you@example.com" }, p.id);
  out["share-no-readings"] = loginEvent({ kind: "share_down", plants: [p.name], at: hhmm(now - 1500, p.tz) }, p.id);
  out["share-readings-back"] = loginEvent({ kind: "share_back", plants: [p.name], since: hhmm(now - 7500, p.tz), at: hhmm(now, p.tz), lasted: lasted(now - 7500, now) }, p.id);
  // The free week's two emails (0122); steps are a sample.
  out["free-week-setup"] = freeWeekSetup(["size", "reserve", "panels"]);
  out["free-week-ends-soon"] = freeWeekEndsSoon("Monday 10 Nov", await priceOf("home", null), `${APP}/unsubscribe.html?t=&k=reminders`);
  return out;
}

if (import.meta.main) serve("notify", async (req) => {
  const denied = denyUnlessServer(req);
  if (denied) return denied;
  const url = new URL(req.url);
  try {
    if (url.searchParams.get("render") === "all") return json(await renderAll(Number(url.searchParams.get("plant")), url.searchParams.get("today") ?? undefined));
    const dryParam = url.searchParams.get("dry") === "1";
    const dry = !LIVE || !RESEND_KEY || dryParam;
    return json(await run(dry, url.searchParams.get("html") === "1", !!VAPID_KEYS && LIVE && !dryParam));
  } catch (e) {
    await reportError("notify", e);
    console.error("notify failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
