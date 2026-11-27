// `notify`: builds and sends the emails Supabase Auth doesn't (SOLAR-157, SOLAR-183) and the
// pop-ups (SOLAR-244), from the message outbox (SOLAR-645).
//
// Cron calls notify-email and notify-push (0257), which use the passes exported here. This
// function's own run does all of it in one call: the sweep, alert emails, the billing outbox,
// the rest, then the pop-ups.
//
// Events are written to email_queue when their cause happens (poll, triggers, email_sweep);
// msg.outbox holds one row per event and channel (0261-0263), checked again at send time
// (msg.email_guard, msg.push_guard). The old queue path (email_claim, push_claim) is gone (0265).
//
// Nothing is sent unless the NOTIFY_LIVE secret is "1". Otherwise, and with ?dry=1, the run
// writes nothing. ?render=all&plant=<id> returns every template built from that plant's data,
// for checking by eye.
import { db } from "../_shared/db.ts";
import { denyUnlessServer } from "../_shared/server.ts";
import { noteError, reportError, serve, track } from "../_shared/errors.ts";
import {
  accountDeleted, type Email, type History, historySynced, type Period, plantEvent, type PlantEvent, loginEvent,
  REPLY_TO, report, type Report, senderFor, sunsynkBack, sunsynkDown, welcome, needAHand, addPlantReminder, feedback, APP,
} from "../_shared/email.ts";
import { outboxMail, FROM_BILLING, FROM_HELLO } from "../_shared/email.ts";
import { msgKey, type Post, sendOutboxOne } from "../_shared/outbox.ts";
import { alertLine, alertPush, clock as hhmm, lasted, mail as accountMail, type MailInput } from "../_shared/text.ts";
import { Pacer, readRate, retryAfterMs } from "../_shared/pace.ts";
import * as webpush from "jsr:@negrel/webpush@0.5.0";

export const LIVE = Deno.env.get("NOTIFY_LIVE") === "1";
export const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
// Local tests point this at a stand-in server.
const RESEND_URL = Deno.env.get("RESEND_URL") ?? "https://api.resend.com/emails";
// The cron call times out at 55 s; stop taking before that, the rest goes next minute.
export const BUDGET_MS = 40_000;
// The gap before the first reply's rate-limit headers set it (SOLAR-679 F14).
const START_GAP_MS = 550;
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
/** "today", or the event's date when it was on another local day ("Tue 21 Oct"). */
function dayOf(epoch: number, tz: string): string {
  const d = local(tz, new Date(epoch * 1000)).date;
  return d === local(tz).date ? "today" : fmtDay(d, { weekday: "short", day: "numeric", month: "short" });
}
/** Battery % at an instant: the newest reading in the 10 minutes before it, as grid_down's
 *  chargePct (0151). Null when none. */
const socAt = (plant: number, at: number) => rpc<number | null>("soc_at", { p_plant: plant, p_at: at });   // R23

// ------------------------------------------------------------------- energy

type DayRow = { period: string; pv_kwh: number | null; load_kwh: number | null; imp_kwh: number | null };
const dayEnergy = (plant: number, from: string, to: string) =>
  rpc<DayRow[]>("_plant_day_energy", { p_plant: plant, p_from: from, p_to: to });
const sum = (rows: DayRow[], k: keyof DayRow) => rows.reduce((n, r) => n + (Number(r[k]) || 0), 0);
// A house always uses something; a day of zeros is SunSynk's filler for a day with no readings.
const hasData = (r: DayRow) => (Number(r.load_kwh) || 0) > 0 || (Number(r.pv_kwh) || 0) > 0;
const pct = (cur: number, prev: number) => (prev > 0 ? ((cur - prev) / prev) * 100 : undefined);
// A span's made, home, bought and independence: the app's figures, from the database (R23)
type Span = { made_kwh: number; home_kwh: number; import_kwh: number; independence_pct: number };
const spanFigures = (plant: number, from: string, to: string) =>
  rpc<Span>("span_figures", { p_plant: plant, p_from: from, p_to: to });
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
  const { data: rows } = await db.rpc("plant_cfg", { p_plant: plant });
  const data = (rows as any[] | null)?.[0];
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
  const fig = await spanFigures(p.id, addDays(today, -60), to);
  const home = fig.home_kwh, imp = fig.import_kwh;
  const short = (d: string) => fmtDay(d, { day: "numeric", month: "short" });
  return {
    plant: p.name, plantId: p.id, days: Math.round((Date.parse(to) - Date.parse(from)) / 86400e3) + 1, from: short(from), to: short(to),
    daily: perDay(rows, from, to, "pv_kwh"), madeKwh: fig.made_kwh, homeKwh: home,
    independencePct: fig.independence_pct, importKwh: hasGrid ? imp : null,
    bestDay, highestUse: best(rows, "load_kwh", short),
  };
}

/** The finished week, month or year before `today`, against the one before it. Null when it has no readings. */
async function buildReport(p: Plant, period: Period, today: string, linkedOn?: string): Promise<Report | null> {
  let from: string, to: string, pFrom: string, pTo: string, label: string, prevLabel: string;
  const [y, m] = today.split("-").map(Number);
  if (period === "week") {
    to = addDays(today, -((new Date(today + "T00:00:00Z").getUTCDay() + 6) % 7 + 1)); from = addDays(to, -6);
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
  const fig = await spanFigures(p.id, start, to);
  const pfig = prev.length ? await spanFigures(p.id, pFrom, pTo) : { made_kwh: 0, home_kwh: 0, import_kwh: 0, independence_pct: 0 };
  const made = fig.made_kwh, home = fig.home_kwh, imp = fig.import_kwh;
  const pMade = pfig.made_kwh, pHome = pfig.home_kwh, pImp = pfig.import_kwh;
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
    independencePct: fig.independence_pct, savedRand: tariff > 0 ? saved(home, imp) : null,
    change: hasPrev ? {
      made: pct(made, pMade), home: pct(home, pHome), import: pct(imp, pImp),
      independence: pct(fig.independence_pct, pfig.independence_pct),
      ...(tariff > 0 ? { saved: pct(saved(home, imp), saved(pHome, pImp)) } : {}),
    } : {},
    ...(hasPrev ? { was: { made: pMade, home: pHome, import: pImp, independence: pfig.independence_pct,
                           ...(tariff > 0 ? { saved: saved(pHome, pImp) } : {}) } } : {}),
    bestDay: best(cur, "pv_kwh", dayLabel), highestUse: best(cur, "load_kwh", dayLabel), daily,
  };
}

/** A report waits while the plant's history is still loading or the user's 60-days
 *  email hasn't gone, so it isn't built from a few days (SOLAR-273). Two days on it
 *  goes anyway: a plant whose history never finishes still gets its reports. */
async function historyPending(row: Row): Promise<boolean> {
  if (!row.user_id || !row.plant_id || local(row.tz).date > addDays(row.data.today, 2)) return false;
  const [{ data: link }, { data: cfg }, open] = await Promise.all([
    db.rpc("plant_link", { p_user: row.user_id, p_plant: row.plant_id }),
    db.rpc("history_jobs", { p_cmd: "loading", p_args: { plant: row.plant_id } }),
    historyOpen(row.user_id, row.plant_id),
  ]);
  // Right after a link the import isn't queued yet and reads as done.
  return (link != null && Date.now() - Date.parse(link.linked_at) < 600e3) || cfg === true || open;
}

/** The plant's 60-days email is still on its way (0263). */
const historyOpen = (user: string, plant: number) => rpc<boolean>("email_history_open", { p_user: user, p_plant: plant });

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

/** Asks History for a plant's kWh totals again when its link wrote none (SOLAR-686 H2). */
const resync = (plant: number) => background((async () => {
  const { error } = await db.rpc("history_jobs", { p_cmd: "totals_now", p_args: { plant } });
  if (error) noteError("history_resync_failed", new Error(error.message), { plant, hourly: true });
})());

// ------------------------------------------------------------------- building

export type Row = {
  id: number; user_id: string | null; to_email: string; plant_id: number | null; plant_name: string | null; tz: string;
  kind: string; key: string; data: Record<string, any>; tries: number; switch: string | null; unsub_token: string | null;
  batch_key: string | null;
};

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
      const stale = d.inverter ? String(r.key).split(":").slice(2, -1).join(":") : null; // logger_stale:<plant>:<sn>:<last_dev>
      // One stopped: the others send ("null"). The whole plant stopped: each its own last time.
      // the one that stopped by serial, as in the list and its Readings back (SOLAR-560)
      return ev({ kind: "logger_stale", since: hhmm(d.since, tz), inverter: stale ? `Inverter ${stale}` : undefined,
        inverters: invs.map((i) => ({ name: `Inverter ${i.sn}`,
          last: stale ? (i.sn === stale ? hhmm(d.since, tz) : null) : hhmm(i.last_dev ?? d.since, tz) })) }, d.since);
    }
    case "logger_back": {
      const sn = d.inverter ? String(r.key).split(":").slice(2, -1).join(":") : null; // logger_back:<plant>:<sn>:<last_dev>
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
      const { data: pu } = await db.rpc("plant_link", { p_user: r.user_id, p_plant: r.plant_id });
      const linkedOn = pu?.linked_at ? new Date(pu.linked_at).toLocaleDateString("en-CA", { timeZone: tz }) : undefined;
      const rep = await buildReport(p, r.kind.slice(7) as Period, d.today, linkedOn);
      return rep && report(rep);
    }
    case "account_deleted": return accountDeleted(r.to_email);
    case "need_a_hand": return needAHand(d.choose === true);
    case "add_plant_reminder": return addPlantReminder();
    case "feedback":
      return feedback({ email: String(d.email ?? ""), message: String(d.message ?? ""), page: String(d.page ?? ""),
        version: String(d.version ?? ""), user: String(d.user ?? ""), image: !!d.image });
  }
  throw new Error(`unknown kind ${r.kind}`);
}

// ------------------------------------------------------------------- sending

// Resend: 400 and 422 are the email itself (bad address, bad field), so it will
// never pass. Anything else (429, 5xx, a network failure, and our own 401/403/404
// from a bad key or address) is tried again.
const refused = (status: number) => status === 400 || status === 422;

// Feedback (SOLAR-428): a reply goes to the user who sent it, with their screenshot attached.
type Out = { row: Row; mail: Email };
const fb = (o: Out) => o.row.kind === "feedback";
const payload = (o: Out) => {
  return { from: senderFor(o.row.kind), reply_to: fb(o) && o.row.data.email ? o.row.data.email : REPLY_TO, to: [o.row.to_email],
           subject: o.mail.subject, html: o.mail.html, text: o.mail.text,
           ...(fb(o) && o.row.data.image ? { attachments: [{ filename: "screenshot.jpg", content: o.row.data.image }] } : {}) };
};

async function post(url: string, body: unknown, key: string): ReturnType<Post> {
  // A network failure comes back as a status too, so the rows are retried.
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json", "Idempotency-Key": key },
      body: JSON.stringify(body),
    });
    const rate = readRate(res.headers);
    return res.ok ? { status: res.status, rate } : { status: res.status, error: `resend ${res.status}: ${(await res.text()).slice(0, 200)}`,
                                                     retryAfter: res.headers.get("Retry-After"), rate };
  } catch (e) {
    return { status: 0, error: `resend: ${e instanceof Error ? e.message : e}` };
  }
}

// Resend allows a few calls a second; batches of up to 100 keep a burst inside it. One pace
// for every Resend call in a run; a 429 holds them all until its Retry-After (SOLAR-645).
const pacer = new Pacer(START_GAP_MS);

/** One call under the run's pace: each reply's rate-limit headers set the gap to the next
 *  call (F14); a 429 holds every lane until its Retry-After. */
async function paced(postFn: Post, url: string, o: { id: number; payload: unknown }, key?: string) {
  const out = await sendOutboxOne(postFn, url, o, key);
  pacer.learn(out.rate);
  if (out.status === 429) pacer.hold(out.retryAfter);
  return out;
}

// ------------------------------------------------------------------- pop-ups

// The database sends an alert's facts and the words come from text.ts (SOLAR-645, 0264):
// data, created (epoch s), tz, the plant's name and how many plants the user has.
export type PopupFacts = {
  kind: string; data: Record<string, any> | null; created: number; tz: string; plant_name?: string | null; plants?: number;
};
/** A pop-up's title, body, and the page and day a tap opens. */
export function popup(r: PopupFacts): { title: string | null; body: string | null; tab: string; day: string | null } {
  const t = alertLine({ kind: r.kind, data: r.data, created: Number(r.created), tz: r.tz });
  if (!t) return { title: null, body: null, tab: "live", day: null };
  return { ...alertPush(r.kind, t, r.plant_name ?? null, Number(r.plants ?? 1)), tab: t.tab,
           day: t.tab === "grid" || t.tab === "solar" ? t.day : null };
}

let pushServer: Promise<webpush.ApplicationServer> | null = null;
// A key that fails to load is tried again next run, not kept as a failure.
const server = () => pushServer ??= webpush.importVapidKeys(JSON.parse(VAPID_KEYS)).then((vapidKeys) =>
  webpush.ApplicationServer.new({ contactInformation: "mailto:hello@princesolarhub.co.za", vapidKeys }))
  .catch((e) => { pushServer = null; throw e; });

// The push services browsers issue addresses on; the same test as push_subs_endpoint_ok (0194).
const PUSH_HOST =
  /^https:\/\/(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)\/\S+$/;

// Pop-ups (SOLAR-645 step 3, 0261): msg_push_take hands over one send per
// device under a claim; msg_push_done takes each push service status back. The database
// decides from it: 2xx sent, 404/410 device removed, 429/5xx/0 tried again inside the hour.
export type PushSend = PopupFacts & {
  id: number; claim: string; event_id: number; plant_id: number; endpoint: string; p256dh: string; auth: string;
};
export type PushResult = { id: number; code: number; retry_s?: number; error?: string };
type Deliver = (s: PushSend, msg: string) => Promise<unknown>;

const deliver: Deliver = async (s, msg) =>
  (await server()).subscribe({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } })
    .pushTextMessage(msg, { ttl: 3600, urgency: webpush.Urgency.High });

/** One send: the push service's status (0 = no answer), and its Retry-After in seconds. */
export async function pushSend(s: PushSend, send: Deliver = deliver): Promise<PushResult> {
  if (!PUSH_HOST.test(s.endpoint)) return { id: s.id, code: 410, error: "bad address" };
  const w = popup(s);
  const msg = JSON.stringify({
    title: w.title, body: w.body, tag: `${s.plant_id}:${s.kind === "relinked" ? "needs" : s.kind.split("_")[0]}`,
    data: { id: s.event_id, tab: w.tab, plant: s.plant_id, day: w.day, section: w.tab === "account" ? "logins" : undefined },
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
      const res = await paced(post, RESEND_URL, { id: o.row.id, payload: o.payload });
      const limited = res.status === 429;
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

// ------------------------------------------------------------------- emails, outbox (SOLAR-645 steps 4, 5)

// msg_email_take (0262) leases due rows of one lane under one claim, after the guard at send
// time, with the event row's fields; the email is built by build(). Up to
// 100 go in one Resend batch call, its key saved on the rows first (msg_email_bind): a retry
// after a lost answer, or after this worker died, sends the same rows under the same key, and
// Resend answers from the first send. A row alone goes in its own call under ms-<id>; feedback
// always goes alone (Resend's batch call takes no attachment). msg_email_done takes each answer
// back; the database decides from it.
// Bulk (SOLAR-645 step 5, 0263): the holds come first (bulkHold): a hold hands the
// row back for a while, the try given back, without building it.
export type MsgEmail = {
  id: number; claim: string; tries: number; batch_key: string | null; event_id: number; user_id: string | null;
  to_email: string; plant_id: number | null; plant_name: string | null; tz: string; kind: string; key: string;
  data: Record<string, any>; unsub_token?: string | null;
};
export type MsgResult = {
  id: number; code?: number; retry_s?: number; error?: string; untried?: boolean; skip?: string; keep?: boolean;
  hold_s?: number;
};
/** Why an email waits before it is built: back in hold_s seconds. null: build it now. */
export type Hold = (row: Row) => Promise<{ hold_s: number; error: string } | null>;
const MSG_BATCH = 100;
let msgMissingNoted = false;
/** The RPC isn't there yet: the functions went out before the migration. */
export const missingRpc = (e: unknown) => /Could not find the function|PGRST202/.test(String((e as Error)?.message ?? e));

type Built = { m: MsgEmail; row: Row; mail: Email };
type Ctx = {
  stop: boolean; deadline: number; call: Rpc; postFn: Post; make: (r: Row) => Promise<Email | null>; newKey: () => string;
  hold: Hold;
};

const rowOf = (m: MsgEmail): Row => ({ id: m.event_id, user_id: m.user_id, to_email: m.to_email, plant_id: m.plant_id,
  plant_name: m.plant_name, tz: m.tz, kind: m.kind, key: m.key, data: m.data ?? {}, tries: m.tries, switch: null,
  unsub_token: m.unsub_token ?? null, batch_key: null });

/** The holds: a report waits for its plant's history (SOLAR-273); the
 *  60-days email waits for the day totals, and each check runs the day sync again (SOLAR-522). */
export const bulkHold: Hold = async (row) => {
  if (row.kind.startsWith("report_") && await historyPending(row)) {
    return { hold_s: 600, error: "waits for history" };
  }
  if (row.kind === "history" && row.plant_id && await historyWaits(row)) {
    resync(row.plant_id);
    return { hold_s: 600, error: "waits for day totals" };
  }
  return null;
};

/** One Resend answer for the rows of one call (paced() has held the pace on a 429). Resend in trouble (not a
 *  refusal, nor a 409 still in progress) stops the pass. keep: the call may have gone. */
function answer(ctx: Ctx, ids: number[], out: Awaited<ReturnType<Post>>, keep: boolean, what: string,
                user: string | null = null): MsgResult[] {
  if (!out.error) return ids.map((id) => ({ id, code: out.status }));
  if (out.status === 429) noteError("resend_429", new Error(out.error), { hourly: true });
  else if (refused(out.status)) noteError("email_failed", new Error(`${what}: ${out.error}`), { user, hourly: true });
  else noteError(`resend_${out.status || "network"}`, new Error(out.error), { hourly: true });
  if (!refused(out.status) && out.status !== 409) ctx.stop = true;
  const retry_s = out.retryAfter ? Math.ceil(retryAfterMs(out.retryAfter, Date.now()) / 1000) : undefined;
  return ids.map((id) => ({ id, code: out.status, error: out.error, ...(retry_s !== undefined ? { retry_s } : {}),
                            ...(keep ? { keep: true } : {}) }));
}

/** A row alone, under ms-<id>. */
async function sendAlone(ctx: Ctx, b: Built): Promise<MsgResult> {
  if (ctx.stop || !await pacer.slot(ctx.deadline)) { ctx.stop = true; return { id: b.m.id, untried: true }; }
  const out = await paced(ctx.postFn, RESEND_URL, { id: b.m.id, payload: payload(b) }, msgKey(b.m.id));
  return answer(ctx, [b.m.id], out, false, `${b.m.kind} outbox ${b.m.id}`, b.m.user_id)[0];
}

/** One group: new rows (key null), or rows bound to `key` by an earlier call. A bound row
 *  only ever goes under its key, alone or with what is left of its group: Resend answers from
 *  the first send if it reached it (a smaller body gets 409 invalid_idempotent_request,
 *  counted as sent), else it is a first send. Holds are for new rows only: a bound row's call
 *  may have gone. */
async function sendGroup(ctx: Ctx, g: MsgEmail[], key: string | null): Promise<MsgResult[]> {
  const bound = key !== null;
  const back = (ms: MsgEmail[]) => ms.map((m) => ({ id: m.id, untried: true, ...(bound ? { keep: true } : {}) }));
  if (ctx.stop || Date.now() > ctx.deadline) return back(g);
  const res: MsgResult[] = [], built: Built[] = [];
  for (const m of g) {
    // reports cost several reads each: a new row not built in time goes back untouched
    if (!bound && Date.now() > ctx.deadline) { res.push(...back([m])); continue; }
    const row = rowOf(m);
    let mail: Email | null;
    try {
      const held = bound ? null : await ctx.hold(row);
      if (held) { res.push({ id: m.id, ...held }); continue; }
      mail = await ctx.make(row);
    } catch (e) {
      noteError("email_build_failed", e, { user: m.user_id, hourly: true });
      const error = `build: ${e instanceof Error ? e.message : e}`.slice(0, 200);
      // tried again later; a bound row keeps its key and goes under it then
      res.push({ id: m.id, code: 0, error, ...(bound ? { keep: true } : {}) });
      continue;
    }
    // History waits for the day sync to land: again in an hour, until its expiry. Anything
    // else with nothing to say (an empty report) is final.
    if (!mail && m.kind === "history" && !bound) { res.push({ id: m.id, hold_s: 3600, error: "nothing to say yet" }); continue; }
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
  const out = await paced(ctx.postFn, `${RESEND_URL}/batch`, { id: ids[0], payload: built.map(payload) }, k);
  // Refused: Resend sent none of them. Each alone, so a bad address fails only itself.
  if (refused(out.status)) {
    const one: MsgResult[] = [];
    for (const b of built) one.push(await sendAlone(ctx, b));
    return [...res, ...one];
  }
  return [...res, ...answer(ctx, ids, out, true, `batch ${k}`)];
}

const newBatchKey = () => `mb-${crypto.randomUUID()}`;
export async function msgEmailPass(until: number, deadline = until, call: Rpc = rpc, postFn: Post = post,
                                   make: (r: Row) => Promise<Email | null> = build, newKey = newBatchKey,
                                   lane: "urgent" | "bulk" = "urgent", hold: Hold = bulkHold) {
  const count = { sent: 0, again: 0, failed: 0, dropped: 0, held: 0 };
  const ctx: Ctx = { stop: false, deadline, call, postFn, make, newKey, hold };
  while (Date.now() < until) {
    let rows: MsgEmail[];
    try {
      rows = await call<MsgEmail[]>("msg_email_take", { p_limit: MSG_BATCH, p_lane: lane });
    } catch (e) {
      if (!missingRpc(e)) throw e;
      if (!msgMissingNoted) noteError("msg_email_take_missing", e, { hourly: true });
      msgMissingNoted = true;
      return { ...count, missing: true };
    }
    if (!rows.length) break;
    // rows bound to a key go again together; feedback alone; new rows in calls of up to 100
    const groups = new Map<string, MsgEmail[]>(), fresh: MsgEmail[] = [], alone: MsgEmail[] = [];
    for (const m of rows) {
      if (m.batch_key) groups.set(m.batch_key, [...(groups.get(m.batch_key) ?? []), m]);
      else (m.kind === "feedback" ? alone : fresh).push(m);
    }
    const res: MsgResult[] = [];
    for (const [key, g] of groups) res.push(...await sendGroup(ctx, g, key));
    for (const m of alone) res.push(...await sendGroup(ctx, [m], null));
    for (let i = 0; i < fresh.length; i += MSG_BATCH) res.push(...await sendGroup(ctx, fresh.slice(i, i + MSG_BATCH), null));
    await call("msg_email_done", { p_claim: rows[0].claim, p_results: res });
    for (const r of res) {
      const c = r.code ?? 0;
      const k = r.untried ? "again" : r.hold_s ? "held" : r.skip ? "dropped" : c >= 200 && c < 300 ? "sent" : refused(c) ? "failed" : "again";
      count[k]++;
      // after the answer is saved: a lost event costs a count, never a second email
      const m = k === "sent" ? rows.find((x) => x.id === r.id) : undefined;
      if (m) await trackSent(rowOf(m)).catch(() => {});
    }
    if (ctx.stop) break;
  }
  return count;
}

/** The bulk lane (0263): welcome, reports, history, feedback, ... */
export const msgBulkPass = (until: number, deadline = until) =>
  msgEmailPass(until, deadline, rpc, post, build, newBatchKey, "bulk", bulkHold);

/** SOLAR-328: counted once an email has gone, by user id only, keyed on its event row. */
export async function trackSent(row: Row, send = track) {
  if (!row.user_id) return;
  const id = String(row.id), at = new Date().toISOString();
  if (row.kind === "winback") await send("winback_email_sent_done", row.user_id, id, at, { plan: row.data.from });
  // SOLAR-243: a paid plan ended. Each email goes once per end: a cancel that ran
  // out (winback, 0144) or a failed payment that ended it (bill_free).
  if (row.kind === "winback" || row.kind === "bill_free") {
    await send("plan_cancelled", row.user_id, id, at, { plan: row.data.from, reason: row.kind === "winback" ? "cancelled" : "unpaid" });
  }
  // SOLAR-475
  if (row.kind === "report_week" && row.data.freeWeekEnds === true) await send("free_week_ended_email_sent_done", row.user_id, id, at, {});
  // SOLAR-552, SOLAR-559
  if (row.kind.startsWith("unpaid_")) await send(`${row.kind}_email_sent_done`, row.user_id, id, at, {});
  // SOLAR-319
  if (row.kind === "need_a_hand") await send("need_a_hand_email_sent_done", row.user_id, id, at, { choose: row.data?.choose === true });
  // SOLAR-474
  if (row.kind === "add_plant_reminder") await send("add_plant_reminder_email_sent_done", row.user_id, id, at, {});
}

/** What only the clock can tell: no readings, SunSynk, reports. */
export const sweep = () => rpc<Record<string, unknown>>("email_sweep").catch((e) => {
  noteError("email_sweep_failed", e, { hourly: true });
  return { error: String(e?.message ?? e) };
});

// All of notify-email and notify-push in one call (the cron job until 0257).
async function run(dry: boolean, push: boolean) {
  const started = Date.now();
  // The cron call times out at 55 s.
  const pushes = () => push ? outboxPushPass(started + 50_000).catch((e) => {
    noteError("push_outbox_failed", e, { hourly: true });
    return { error: String(e?.message ?? e) };
  }) : null;
  // pop-ups don't need Resend: they go in an email dry run too, as notify-push's do
  if (dry) return { live: false, pushed: await pushes() };
  const swept = await sweep();
  const alerts = await msgEmailPass(started + BUDGET_MS, started + BUDGET_MS + 5_000).catch((e) => {
    noteError("msg_email_pass_failed", e, { hourly: true });
    return { error: String(e?.message ?? e) };
  });
  const outbox = await outboxPass(started + BUDGET_MS + 5_000).catch((e) => {
    noteError("outbox_pass_failed", e, { hourly: true });
    return { error: String(e?.message ?? e) };
  });
  const bulk = await msgBulkPass(started + BUDGET_MS + 5_000).catch((e) => {
    noteError("msg_email_bulk_failed", e, { hourly: true });
    return { error: String(e?.message ?? e) };
  });
  return { live: true, swept, alerts, outbox, bulk, pushed: await pushes() };
}

// Every template from one plant's real numbers; event values are samples.
async function renderAll(plantId: number, today?: string) {
  const { data: pu } = await db.rpc("plant_link", { p_user: null, p_plant: plantId });
  if (!pu) throw new Error(`no users on plant ${plantId}`);
  const p: Plant = { id: plantId, name: pu.plant_name || "your plant", tz: await rpc<string>("plant_tz", { p_plant: plantId }) };
  const now = Math.floor(Date.now() / 1000);
  const out: Record<string, Email> = { welcome: welcome(), "need-a-hand-choose": needAHand(true), "add-plant-reminder": addPlantReminder(), "account-deleted": accountDeleted("you@example.com") };
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
    return json(await run(dry, !!VAPID_KEYS && LIVE && !dryParam));
  } catch (e) {
    await reportError("notify", e);
    console.error("notify failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
