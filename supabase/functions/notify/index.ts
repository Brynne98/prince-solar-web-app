// `notify` — sends the emails Supabase Auth doesn't (SOLAR-157, SOLAR-183), and the
// billing emails (SOLAR-208, 0116).
//
// pg_cron fires this every minute (migration 0092). The emails are already queued
// when their cause happens (0102): poll steps each plant's state and queues grid,
// battery, string and readings emails; triggers queue welcome, history, Reconnect
// and account deleted. Each run here first calls email_sweep() for what only the
// clock can tell (no readings for 15 min, SunSynk down/back, daily reminders,
// reports due today), then sends the queue: claim up to BATCH rows (skip locked,
// so runs can overlap), build each email, send them in one Resend batch call,
// and mark each row sent, skipped, failed, or queued again with a growing wait.
// It keeps going until the queue is empty or BUDGET_MS is spent.
//
// email_claim skips rows whose switch is off (email_wanted, 0091), whose plant the
// user no longer has, and "back" emails whose "down" never went. needs_relink,
// welcome, history and account deleted have no switch.
//
// Nothing is sent unless the NOTIFY_LIVE secret is "1". Otherwise, and with ?dry=1,
// the run writes nothing (no sweep, no claim) and returns the next BATCH it would
// send. ?render=all&plant=<id> returns every template built from that plant's data,
// for checking by eye.
import { db, denyUnlessServer } from "../_shared/sunsynk.ts";
import { reportError, serve } from "../_shared/errors.ts";
import {
  accountDeleted, type Email, FROM_ACCOUNT, FROM_NOTICE, type History, freeWeekEndsSoon, historySynced, movedToFree,
  PAY_URL, paymentFailed, paymentReceived, type Period, planChangeBooked, plantEvent, type PlantEvent, plantsRemovalSoon,
  planUpgraded, renewalNotice, report, type Report, sunsynkBack, sunsynkDown, welcome,
} from "../_shared/email.ts";

const LIVE = Deno.env.get("NOTIFY_LIVE") === "1";
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
// Local tests point this at a stand-in server.
const RESEND_URL = Deno.env.get("RESEND_URL") ?? "https://api.resend.com/emails";
const UNSUB = `${Deno.env.get("SUPABASE_URL")}/functions/v1/unsubscribe`;
// Resend's batch call takes up to 100 emails.
const BATCH = 100;
// The cron call times out at 55 s; stop claiming before that, the rest goes next minute.
const BUDGET_MS = 40_000;
// Resend's default limit is 2 calls a second.
const PACE_MS = 550;

type Plant = { id: number; name: string; tz: string };

const json = (b: unknown, status = 200) =>
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
const hhmm = (epoch: number, tz: string) =>
  new Intl.DateTimeFormat("en-GB", { timeZone: tz, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date(epoch * 1000));
/** "today", or the event's date when it was on another local day ("Tue 21 Oct"). */
function dayOf(epoch: number, tz: string): string {
  const d = local(tz, new Date(epoch * 1000)).date;
  return d === local(tz).date ? "today" : fmtDay(d, { weekday: "short", day: "numeric", month: "short" });
}
function lasted(fromEpoch: number, toEpoch: number): string {
  const m = Math.max(1, Math.round((toEpoch - fromEpoch) / 60));
  return m >= 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m} min`;
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
async function buildReport(p: Plant, period: Period, today: string): Promise<Omit<Report, "unsubscribeUrl"> | null> {
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
  const cur = all.filter((r) => r.period >= from && hasData(r)), prev = all.filter((r) => r.period <= pTo && hasData(r));
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
  return {
    plantId: p.id, period, label, prevLabel, plant: p.name,
    madeKwh: made, homeKwh: home, importKwh: hasGrid ? imp : null, exportKwh: null,
    independencePct: independence(home, imp), savedRand: tariff > 0 ? saved(home, imp) : null,
    change: hasPrev ? {
      made: pct(made, pMade), home: pct(home, pHome), import: pct(imp, pImp),
      independence: pct(independence(home, imp), independence(pHome, pImp)),
      ...(tariff > 0 ? { saved: pct(saved(home, imp), saved(pHome, pImp)) } : {}),
    } : {},
    bestDay: best(cur, "pv_kwh", dayLabel), highestUse: best(cur, "load_kwh", dayLabel), daily,
  };
}

// ------------------------------------------------------------------- building

type Row = {
  id: number; user_id: string | null; to_email: string; plant_id: number | null; plant_name: string | null; tz: string;
  kind: string; key: string; data: Record<string, any>; tries: number; switch: string | null; unsub_token: string | null;
  batch_key: string | null;
};

/** The email for one queued row; null = nothing to say (an empty report), skip it. */
async function build(r: Row, unsub: string): Promise<Email | null> {
  const d = r.data, tz = r.tz;
  const p: Plant = { id: r.plant_id ?? 0, name: r.plant_name || "your plant", tz };
  const ev = (e: PlantEvent, at: number | null) => plantEvent(p.name, p.id, e, unsub, at == null ? "today" : dayOf(at, tz));
  switch (r.kind) {
    case "grid_down": return ev({ kind: "grid_down", at: hhmm(d.since, tz), chargePct: d.chargePct ?? undefined }, d.since);
    case "grid_back": return ev({ kind: "grid_back", at: hhmm(d.at, tz), lasted: lasted(d.since, d.at) }, d.at);
    case "batt_hot":
      // Counted only when the email goes: a 30-day scan, not one per minute while it stays hot.
      return ev({ kind: "batt_hot", at: hhmm(d.at, tz), tempC: d.tempC, hotDays: await rpc<number>("email_hot_days", { p_plant: p.id }) }, d.at);
    case "bank_drift": return ev({ kind: "bank_drift", banks: d.banks }, null);
    case "string_dead": return ev({ kind: "string_dead", string: d.string, inverter: d.inverter, since: hhmm(d.since, tz) }, d.since);
    case "logger_stale": return ev({ kind: "logger_stale", since: hhmm(d.since, tz), inverter: d.inverter ?? undefined }, d.since);
    case "logger_back": return ev({ kind: "logger_back", at: hhmm(d.at, tz), lasted: lasted(d.since, d.at), inverter: d.inverter ?? undefined }, d.at);
    case "needs_relink": return plantEvent(p.name, p.id, { kind: "needs_relink" }, "");
    case "sunsynk_down": return sunsynkDown(p.name, p.id, hhmm(d.since, tz), unsub, dayOf(d.since, tz));
    case "sunsynk_back": return sunsynkBack(p.name, p.id, hhmm(d.at, tz), lasted(d.since, d.at), unsub, dayOf(d.at, tz));
    case "welcome": return welcome();
    case "history": { const h = await buildHistory(p); return h && historySynced(h); }
    case "report_week": case "report_month": case "report_year": {
      const rep = await buildReport(p, r.kind.slice(7) as Period, d.today);
      // The day-7 report of a Free account's first week (0114) says the week ends.
      return rep && report({ ...rep, freeWeekEnds: d.freeWeekEnds === true, unsubscribeUrl: unsub });
    }
    case "free_week_soon":
      return freeWeekEndsSoon(new Date(d.endsAt * 1000).toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "short", timeZone: tz }));
    case "account_deleted": return accountDeleted(r.to_email);
    // Billing (0116): amounts in whole rand, dates as "2026-11-01".
    case "bill_paid":
      return paymentReceived({
        plan: d.plan, period: d.period, amount: d.amount, date: day(d.date), card: d.card, reference: d.reference,
        extraInverters: d.extra > 0 ? { n: d.extra, each: d.extraEach } : undefined,
        next: { amount: d.nextAmount, date: day(d.nextDate) },
      });
    case "bill_upgraded":
      return planUpgraded({
        from: d.from, to: d.to, period: d.period, addedInverters: d.from === d.to ? d.added : undefined,
        paidNow: d.amount, daysLeft: d.daysLeft, next: { amount: d.nextAmount, date: day(d.nextDate) },
      });
    case "bill_change":
      return planChangeBooked({
        from: d.from, to: d.to, fromPeriod: d.fromPeriod, toPeriod: d.toPeriod, on: day(d.on),
        removePlants: d.removePlants, next: d.to === "free" ? undefined : { amount: d.nextAmount },
      });
    case "bill_failed":
      return paymentFailed({
        plan: d.plan, period: d.period, amount: d.amount, card: d.card,
        nextTry: d.nextTry ? day(d.nextTry) : undefined, freeOn: day(d.freeOn), payUrl: PAY_URL,
      });
    case "bill_free":
      return movedToFree({ from: d.from, kept: d.kept, stopped: d.stopped, deleteOn: day(d.deleteOn), payUrl: PAY_URL });
    case "bill_removal_soon": return plantsRemovalSoon(d.plants, day(d.on));
    case "bill_renewal_notice":
      return renewalNotice({ plan: d.plan, amount: d.amount, on: day(d.on), change: d.changed ? "Your plan changes on that date, as you booked." : undefined });
  }
  throw new Error(`unknown kind ${r.kind}`);
}

// ------------------------------------------------------------------- sending

type Out = { row: Row; mail: Email };
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

const payload = (o: Out) => {
  const headers: Record<string, string> = {};
  if (o.mail.unsubscribe) {
    headers["List-Unsubscribe"] = `<${o.mail.unsubscribe}>`;
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click";
  }
  return { from: o.row.kind === "account_deleted" ? FROM_ACCOUNT : FROM_NOTICE, to: [o.row.to_email],
           subject: o.mail.subject, html: o.mail.html, text: o.mail.text, headers };
};

async function post(url: string, body: unknown, key: string): Promise<{ status: number; error?: string }> {
  // A network failure comes back as a status too, so the rows are retried.
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json", "Idempotency-Key": key },
      body: JSON.stringify(body),
    });
    return res.ok ? { status: res.status } : { status: res.status, error: `resend ${res.status}: ${(await res.text()).slice(0, 200)}` };
  } catch (e) {
    return { status: 0, error: `resend: ${e instanceof Error ? e.message : e}` };
  }
}

// Resend allows a few calls a second; batches of up to 100 keep a burst inside it.
let lastCall = 0;
async function paced<T>(f: () => Promise<T>): Promise<T> {
  const wait = lastCall + PACE_MS - Date.now();
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  lastCall = Date.now();
  return await f();
}

/** One batch call. When Resend refuses it, each half again, down to the one email
 *  it refuses, so a bad address fails only itself and costs ~14 calls, not 100. */
async function sendBatch(outs: Out[], deadline: number, reuse?: string): Promise<Done[]> {
  if (!outs.length) return [];
  if (Date.now() > deadline) return outs.map((o) => later(o.row));
  // A retry goes under the key its batch had: if Resend took that batch before the
  // answer was lost, it answers from that and sends nothing twice.
  const ids = new TextEncoder().encode(outs.map((o) => o.row.id).join("."));
  const key = reuse ?? "q-" + [...new Uint8Array(await crypto.subtle.digest("SHA-256", ids))].map((b) => b.toString(16).padStart(2, "0")).join("");
  const res = await paced(() => post(`${RESEND_URL}/batch`, outs.map(payload), key));
  if (!res.error) return outs.map((o) => ({ id: o.row.id, status: "sent" }));
  // 409: the old key was used with a different body (the batch changed since); a fresh one.
  if (res.status === 409 && reuse) return await sendBatch(outs, deadline);
  if (!refused(res.status)) return outs.map((o) => retry(o.row, res.error!, key));
  if (outs.length === 1) return [{ id: outs[0].row.id, status: "failed", error: res.error }];
  const half = Math.ceil(outs.length / 2);
  return [...await sendBatch(outs.slice(0, half), deadline), ...await sendBatch(outs.slice(half), deadline)];
}

async function run(dry: boolean, withHtml: boolean) {
  const started = Date.now();
  // What only the clock can tell: no readings, SunSynk, daily reminders, reports.
  const swept = dry ? null : await rpc<Record<string, unknown>>("email_sweep").catch((e) => ({ error: String(e?.message ?? e) }));
  const lines: Record<string, unknown>[] = [];
  const count = { sent: 0, queued: 0, failed: 0, skipped: 0 };

  const deadline = started + BUDGET_MS + 5_000;
  while (Date.now() - started < BUDGET_MS) {
    const rows = await rpc<Row[]>("email_claim", { p_limit: BATCH, p_peek: dry });
    if (!rows.length) break;
    const outs: Out[] = [], done: Done[] = [];
    for (const row of rows) {
      // Reports cost two reads each; what isn't built in time goes back untouched.
      if (Date.now() > deadline) { done.push(later(row)); continue; }
      try {
        const unsub = row.switch ? `${UNSUB}?t=${dry ? "dry" : row.unsub_token}&k=${row.switch}` : "";
        const mail = await build(row, unsub);
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
      }
    }
    if (dry) break;  // a peek claims nothing, so the next read would be the same rows
    // Retries go in the batch they went in before, under its key; new rows in fresh batches.
    const groups = new Map<string, Out[]>();
    for (const o of outs) {
      const g = o.row.batch_key ?? "";
      groups.set(g, [...(groups.get(g) ?? []), o]);
    }
    for (const [key, group] of groups) done.push(...await sendBatch(group, deadline, key || undefined));
    for (const x of done) count[x.status]++;
    await rpc("email_done", { p_results: done });
  }
  return { live: !dry, swept, ...count, due: lines };
}

// Every template from one plant's real numbers; event values are samples.
async function renderAll(plantId: number, today?: string) {
  const { data: pu } = await db.from("plant_users").select("plant_name").eq("plant_id", plantId).limit(1).maybeSingle();
  if (!pu) throw new Error(`no users on plant ${plantId}`);
  const p: Plant = { id: plantId, name: pu.plant_name || "your plant", tz: await rpc<string>("plant_tz", { p_plant: plantId }) };
  const now = Math.floor(Date.now() / 1000), unsub = `${UNSUB}?t=sample&k=grid`;
  const out: Record<string, Email> = { welcome: welcome(), "account-deleted": accountDeleted("you@example.com") };
  const h = await buildHistory(p);
  if (h) out["history-synced"] = historySynced(h);
  today ??= local(p.tz).date;
  for (const period of ["week", "month", "year"] as Period[]) {
    const r = await buildReport(p, period, today);
    if (r) out[`report-${period}`] = report({ ...r, unsubscribeUrl: unsub });
  }
  out["sunsynk-down"] = sunsynkDown(p.name, p.id, hhmm(now - 1500, p.tz), unsub);
  out["sunsynk-back"] = sunsynkBack(p.name, p.id, hhmm(now, p.tz), lasted(now - 1500, now), unsub);
  const ev: [string, PlantEvent][] = [
    ["grid-down", { kind: "grid_down", at: hhmm(now - 240, p.tz), chargePct: 62 }],
    ["grid-back", { kind: "grid_back", at: hhmm(now, p.tz), lasted: lasted(now - 5580, now) }],
    ["battery-hot", { kind: "batt_hot", at: hhmm(now, p.tz), tempC: 47, hotDays: 3 }],
    ["batteries-uneven", { kind: "bank_drift", banks: [{ name: "Inverter 1", chargePct: 72 }, { name: "Inverter 2", chargePct: 60 }] }],
    ["panels-stopped", { kind: "string_dead", string: "String 3", inverter: "Inverter 1", since: hhmm(now - 1200, p.tz) }],
    ["no-readings", { kind: "logger_stale", since: hhmm(now - 1200, p.tz) }],
    ["readings-back", { kind: "logger_back", at: hhmm(now, p.tz), lasted: lasted(now - 6420, now) }],
    ["inverter-no-readings", { kind: "logger_stale", since: hhmm(now - 1200, p.tz), inverter: "Inverter 2" }],
    ["inverter-readings-back", { kind: "logger_back", at: hhmm(now, p.tz), lasted: lasted(now - 6420, now), inverter: "Inverter 2" }],
    ["reconnect", { kind: "needs_relink" }],
  ];
  for (const [name, e] of ev) out[name] = plantEvent(p.name, p.id, e, e.kind === "needs_relink" ? "" : unsub);
  return out;
}

serve("notify", async (req) => {
  const denied = denyUnlessServer(req);
  if (denied) return denied;
  const url = new URL(req.url);
  try {
    if (url.searchParams.get("render") === "all") return json(await renderAll(Number(url.searchParams.get("plant")), url.searchParams.get("today") ?? undefined));
    const dry = !LIVE || !RESEND_KEY || url.searchParams.get("dry") === "1";
    return json(await run(dry, url.searchParams.get("html") === "1"));
  } catch (e) {
    await reportError("notify", e);
    console.error("notify failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
