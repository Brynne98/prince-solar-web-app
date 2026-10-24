// `notify` — sends the 17 emails Supabase Auth doesn't (SOLAR-157).
//
// pg_cron fires this every minute (migration 0092). Each run works out what is due:
// plant events from email_plant_events, SunSynk down/back from email_sunsynk_state,
// dead logins from email_relinks, welcome, history synced, account deleted (the
// email_outbox row api_account_delete leaves), and the weekly, monthly and yearly
// reports at 07:00 local on Monday, the 1st and 1 January.
//
// A send happens once: the row in email_sent (unique per user and key) is claimed
// before the mail goes to Resend and dropped again if Resend refuses it, so the next
// minute retries. grid_down, logger_stale and sunsynk_down rows stay open until their
// "back" email closes them; a user with an open one gets no second "down".
// Switched-off kinds are skipped with email_wanted (0091); needs_relink, welcome,
// history and account deleted have no switch.
//
// Nothing is sent unless the NOTIFY_LIVE secret is "1". Otherwise, and with ?dry=1,
// the run writes nothing and returns what it would send. ?render=all&plant=<id>
// returns every template built from that plant's data, for checking by eye.
import { db, denyUnlessServer } from "../_shared/sunsynk.ts";
import {
  accountDeleted, type Email, FROM_ACCOUNT, FROM_NOTICE, type History, historySynced, type Period,
  plantEvent, type PlantEvent, report, type Report, sunsynkBack, sunsynkDown, welcome,
} from "../_shared/email.ts";

const LIVE = Deno.env.get("NOTIFY_LIVE") === "1";
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
// Local tests point this at a stand-in server.
const RESEND_URL = Deno.env.get("RESEND_URL") ?? "https://api.resend.com/emails";
const UNSUB = `${Deno.env.get("SUPABASE_URL")}/functions/v1/unsubscribe`;
// A bug can't spend the Resend quota in one run; whatever is left goes next minute.
const MAX_SENDS = 40;
const DOWN_KINDS = ["grid_down", "logger_stale", "sunsynk_down"];
// email_wanted's switch for each kind; absent = always sent.
const SWITCH: Record<string, string> = {
  grid_down: "grid", grid_back: "grid", batt_hot: "battery", bank_drift: "battery", string_dead: "panels",
  logger_stale: "readings", logger_back: "readings", sunsynk_down: "sunsynk", sunsynk_back: "sunsynk",
  report_week: "weekly", report_month: "monthly", report_year: "yearly",
};

type UserRow = {
  user_id: string; email: string; confirmed: boolean; plant_id: number | null; plant_name: string | null;
  account_id: string | null; linked_at: string | null; tz: string;
};
type Plant = { id: number; name: string; tz: string; users: UserRow[] };
// Each user names the plant their own way (plant_users.plant_name).
const named = (p: Plant, u: UserRow): Plant => ({ ...p, name: u.plant_name || p.name });
type Out = {
  user_id: string | null; plant_id: number | null; kind: string; key: string; data: Record<string, unknown>;
  // Built only once the email is known to be due, wanted and unsent; null = nothing to say, skip.
  to: string; from: string; build: (unsubscribe: string) => Email | null | Promise<Email | null>; closes?: number;
};
type OpenRow = { id: number; user_id: string; plant_id: number | null; kind: string; data: Record<string, number>; sent_at: string };

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
// en-GB writes "Sept"; the app and the mock write "Sep".
const fmtDay = (d: string, o: Intl.DateTimeFormatOptions) =>
  new Intl.DateTimeFormat("en-GB", { timeZone: "UTC", ...o }).format(new Date(d + "T00:00:00Z")).replace("Sept", "Sep");
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

/** The 60 days SunSynk lets us backfill, ending yesterday. Null when there is nothing in them. */
async function buildHistory(p: Plant): Promise<History | null> {
  const today = local(p.tz).date;
  const from = addDays(today, -60), to = addDays(today, -1);
  const rows = (await dayEnergy(p.id, from, to)).filter(hasData);
  if (!rows.length) return null;
  const { hasGrid } = await plantCfg(p.id);
  const home = sum(rows, "load_kwh"), imp = sum(rows, "imp_kwh");
  const short = (d: string) => fmtDay(d, { day: "numeric", month: "short" });
  return {
    plant: p.name, plantId: p.id, days: 60, from: short(from), to: short(to),
    daily: perDay(rows, from, to, "pv_kwh"), madeKwh: sum(rows, "pv_kwh"), homeKwh: home,
    independencePct: independence(home, imp), importKwh: hasGrid ? imp : null,
    bestDay: best(rows, "pv_kwh", short)!, highestUse: best(rows, "load_kwh", short),
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
  const { tariff } = await plantCfg(p.id);
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
    madeKwh: made, homeKwh: home, importKwh: imp, exportKwh: null,
    independencePct: independence(home, imp), savedRand: tariff > 0 ? saved(home, imp) : null,
    change: hasPrev ? {
      made: pct(made, pMade), home: pct(home, pHome), import: pct(imp, pImp),
      independence: pct(independence(home, imp), independence(pHome, pImp)),
      ...(tariff > 0 ? { saved: pct(saved(home, imp), saved(pHome, pImp)) } : {}),
    } : {},
    bestDay: best(cur, "pv_kwh", dayLabel), highestUse: best(cur, "load_kwh", dayLabel), daily,
  };
}

// ------------------------------------------------------------------- what's due

async function due(users: UserRow[], plants: Map<number, Plant>, open: OpenRow[], openFor: (u: string, p: number | null, k: string) => OpenRow | undefined) {
  const out: Out[] = [];
  const closeOnly: number[] = [];
  const firstPlant = new Map<string, Plant>();
  for (const u of users) if (u.plant_id != null && !firstPlant.has(u.user_id)) firstPlant.set(u.user_id, plants.get(u.plant_id)!);
  const ev = (p: Plant, u: UserRow, kind: string, key: string, data: Record<string, unknown>, e: PlantEvent, at: number | null, closes?: number) =>
    out.push({ user_id: u.user_id, plant_id: p.id, kind, key, data, to: u.email, from: FROM_NOTICE, closes,
      build: async (unsub) => {
        // Counted only when the email goes: a 30-day scan, not one per minute while it stays hot.
        if (e.kind === "batt_hot") e.hotDays = await rpc<number>("email_hot_days", { p_plant: p.id });
        return plantEvent(named(p, u).name, p.id, e, unsub, at == null ? "today" : dayOf(at, p.tz));
      } });

  // Account deleted: the address is all that's left of the user.
  const { data: outbox } = await db.from("email_outbox").select("id, email");
  for (const o of outbox ?? []) {
    out.push({ user_id: null, plant_id: null, kind: "account_deleted", key: `outbox:${o.id}`, data: { outbox: o.id },
      to: o.email, from: FROM_ACCOUNT, build: () => accountDeleted(o.email) });
  }

  // Welcome: confirmed, no inverter yet. Users from before 0092 are marked as sent.
  for (const u of users) {
    if (u.confirmed && u.plant_id == null) {
      out.push({ user_id: u.user_id, plant_id: null, kind: "welcome", key: "welcome", data: {}, to: u.email, from: FROM_NOTICE, build: () => welcome() });
    }
  }

  // History synced: the walk is done and the link is over 10 minutes old, so the
  // bookmarks were seeded before we read them.
  const done = new Set(await rpc<number[]>("email_history_done"));
  for (const p of plants.values()) {
    if (!done.has(p.id)) continue;
    for (const u of p.users) {
      if (!u.linked_at || Date.parse(u.linked_at) > Date.now() - 600e3) continue;
      out.push({ user_id: u.user_id, plant_id: p.id, kind: "history", key: `history:${p.id}`, data: {}, to: u.email, from: FROM_NOTICE,
        build: async () => { const h = await buildHistory(named(p, u)); return h && historySynced(h); } });
    }
  }

  // Plant events.
  for (const p of plants.values()) {
    const events = await rpc<{ kind: string; key: string; data: Record<string, any> }[]>("email_plant_events", { p_plant: p.id });
    for (const { kind, key, data: d } of events) {
      for (const u of p.users) {
        switch (kind) {
          case "grid_down":
            if (!openFor(u.user_id, p.id, kind)) ev(p, u, kind, key, d, { kind, at: hhmm(d.since, p.tz), chargePct: d.chargePct ?? undefined }, d.since);
            break;
          case "grid_on": {
            const o = openFor(u.user_id, p.id, "grid_down");
            if (!o) break;
            const at = Math.max(d.since ?? 0, o.data.since);
            ev(p, u, "grid_back", `grid_back:${p.id}:${o.data.since}`, { since: o.data.since, at }, { kind: "grid_back", at: hhmm(at, p.tz), lasted: lasted(o.data.since, at) }, at, o.id);
            break;
          }
          case "batt_hot":
            ev(p, u, kind, key, d, { kind, at: hhmm(d.at, p.tz), tempC: d.tempC }, d.at);
            break;
          case "bank_drift":
            ev(p, u, kind, key, d, { kind, banks: d.banks }, null);
            break;
          case "string_dead":
            ev(p, u, kind, key, d, { kind, string: d.string, inverter: d.inverter, since: hhmm(d.since, p.tz) }, d.since);
            break;
          case "logger_stale":
            if (!openFor(u.user_id, p.id, kind)) ev(p, u, kind, key, d, { kind, since: hhmm(d.since, p.tz) }, d.since);
            break;
          case "logger_ok": {
            const o = openFor(u.user_id, p.id, "logger_stale");
            if (!o) break;
            ev(p, u, "logger_back", `logger_back:${p.id}:${o.data.since}`, { since: o.data.since, at: d.at }, { kind: "logger_back", at: hhmm(d.at, p.tz), lasted: lasted(o.data.since, d.at) }, d.at, o.id);
            break;
          }
        }
      }
    }
  }

  // SunSynk down or back: one email per user, about their first plant.
  const ss = await rpc<{ since: number; down: boolean; up: boolean } | null>("email_sunsynk_state");
  for (const [uid, p] of firstPlant) {
    const u = p.users.find((x) => x.user_id === uid)!;
    const o = openFor(uid, null, "sunsynk_down");
    if (ss?.down && !o) {
      out.push({ user_id: uid, plant_id: null, kind: "sunsynk_down", key: `sunsynk_down:${ss.since}`, data: { since: ss.since, plant: p.id }, to: u.email, from: FROM_NOTICE,
        build: (unsub) => sunsynkDown(named(p, u).name, p.id, hhmm(ss.since, p.tz), unsub, dayOf(ss.since, p.tz)) });
    } else if (ss?.up && o) {
      const at = ss.since;
      out.push({ user_id: uid, plant_id: null, kind: "sunsynk_back", key: `sunsynk_back:${o.data.since}`, data: { since: o.data.since, at }, to: u.email, from: FROM_NOTICE, closes: o.id,
        build: (unsub) => sunsynkBack(named(p, u).name, p.id, hhmm(at, p.tz), lasted(o.data.since, at), unsub, dayOf(at, p.tz)) });
    }
  }

  // A login that died: the user's first plant on it names the email.
  for (const r of await rpc<{ user_id: string; account_id: string; key: string }[]>("email_relinks")) {
    const u = users.find((x) => x.user_id === r.user_id && x.account_id === r.account_id) ?? users.find((x) => x.user_id === r.user_id && x.plant_id != null);
    if (!u) continue;
    const p = plants.get(u.plant_id!)!;
    out.push({ user_id: u.user_id, plant_id: p.id, kind: "needs_relink", key: r.key, data: { account: r.account_id }, to: u.email, from: FROM_NOTICE,
      build: () => plantEvent(named(p, u).name, p.id, { kind: "needs_relink" }, "") });
  }

  // Reports at 07:00 local: weekly on Monday, monthly on the 1st, yearly on 1 January.
  for (const p of plants.values()) {
    const now = local(p.tz);
    if (now.hour !== 7) continue;
    const periods: Period[] = [];
    if (now.dow === 1) periods.push("week");
    if (now.date.endsWith("-01")) periods.push("month");
    if (now.date.endsWith("-01-01")) periods.push("year");
    for (const period of periods) {
      for (const u of p.users) {
        out.push({ user_id: u.user_id, plant_id: p.id, kind: `report_${period}`, key: `report_${period}:${p.id}:${now.date}`, data: {}, to: u.email, from: FROM_NOTICE,
          build: async (unsub) => { const r = await buildReport(named(p, u), period, now.date); return r && report({ ...r, unsubscribeUrl: unsub }); } });
      }
    }
  }

  // A "down" nobody closed in 3 days (plant unlinked, data gone): close it quietly.
  for (const o of open) if (Date.parse(o.sent_at) < Date.now() - 3 * 86400e3) closeOnly.push(o.id);
  return { out, closeOnly };
}

// ------------------------------------------------------------------- sending

async function send(o: Out, mail: Email): Promise<string | null> {
  const headers: Record<string, string> = {};
  if (mail.unsubscribe) {
    headers["List-Unsubscribe"] = `<${mail.unsubscribe}>`;
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click";
  }
  // A network failure must come back as an error too, so the claim is dropped and retried.
  try {
    const res = await fetch(RESEND_URL, {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: o.from, to: [o.to], subject: mail.subject, html: mail.html, text: mail.text, headers }),
    });
    return res.ok ? null : `resend ${res.status}: ${(await res.text()).slice(0, 200)}`;
  } catch (e) {
    return `resend: ${e instanceof Error ? e.message : e}`;
  }
}

async function run(dry: boolean, withHtml: boolean) {
  const users = await rpc<UserRow[]>("email_users");
  const plants = new Map<number, Plant>();
  for (const u of users) {
    if (u.plant_id == null) continue;
    const p = plants.get(u.plant_id) ?? { id: u.plant_id, name: u.plant_name || "your plant", tz: u.tz, users: [] };
    if (!p.users.some((x) => x.user_id === u.user_id)) p.users.push(u);
    plants.set(u.plant_id, p);
  }
  const { data: openRows, error } = await db.from("email_sent").select("id, user_id, plant_id, kind, data, sent_at").in("kind", DOWN_KINDS).is("closed_at", null);
  if (error) throw new Error(`email_sent: ${error.message}`);
  const open = (openRows ?? []) as OpenRow[];
  const openFor = (u: string, p: number | null, k: string) => open.find((o) => o.user_id === u && o.kind === k && (o.plant_id ?? null) === p);

  const { out, closeOnly } = await due(users, plants, open, openFor);
  const wanted = new Map<string, boolean>();
  const lines: Record<string, unknown>[] = [];
  let sent = 0;

  for (const o of out) {
    if (sent >= MAX_SENDS) { lines.push({ kind: o.kind, key: o.key, skipped: "run cap" }); continue; }
    // Already sent: the outbox row is its own record; everything else is in email_sent.
    if (o.user_id) {
      const { data: had } = await db.from("email_sent").select("id").eq("user_id", o.user_id).eq("key", o.key).maybeSingle();
      if (had) continue;
    }
    const sw = SWITCH[o.kind];
    if (sw && o.user_id) {
      const k = `${o.user_id}:${sw}`;
      if (!wanted.has(k)) wanted.set(k, await rpc<boolean>("email_wanted", { p_user: o.user_id, p_kind: sw }));
      if (!wanted.get(k)) {
        // A "back" for someone who switched the kind off since the "down": close it, send nothing.
        if (o.closes && !dry) await db.from("email_sent").update({ closed_at: new Date().toISOString() }).eq("id", o.closes);
        continue;
      }
    }
    const unsub = sw && o.user_id ? (dry ? `${UNSUB}?t=dry&k=${sw}` : `${UNSUB}?t=${await rpc<string>("email_unsub_token", { p_user: o.user_id })}&k=${sw}`) : "";
    const mail = await o.build(unsub);
    if (!mail) continue;
    const line: Record<string, unknown> = { kind: o.kind, key: o.key, to: o.to, subject: mail.subject };
    if (withHtml) line.html = mail.html;
    lines.push(line);
    if (dry) continue;

    let claimed: number | null = null;
    if (o.user_id) {
      const { data: row } = await db.from("email_sent")
        .upsert({ user_id: o.user_id, plant_id: o.plant_id, kind: o.kind, key: o.key, data: o.data,
                  closed_at: DOWN_KINDS.includes(o.kind) ? null : new Date().toISOString() },
                { onConflict: "user_id,key", ignoreDuplicates: true })
        .select("id").maybeSingle();
      if (!row) { line.skipped = "claimed by another run"; continue; }
      claimed = row.id;
    }
    const err = await send(o, mail);
    if (err) {
      line.error = err;
      if (claimed) await db.from("email_sent").delete().eq("id", claimed);
      continue;
    }
    sent++;
    if (o.closes) await db.from("email_sent").update({ closed_at: new Date().toISOString() }).eq("id", o.closes);
    if (o.kind === "account_deleted") await db.from("email_outbox").delete().eq("id", o.data.outbox as number);
  }
  if (!dry && closeOnly.length) await db.from("email_sent").update({ closed_at: new Date().toISOString() }).in("id", closeOnly);
  return { live: !dry, sent, due: lines };
}

// Every template from one plant's real numbers; event values are samples.
async function renderAll(plantId: number, today?: string) {
  const users = (await rpc<UserRow[]>("email_users")).filter((u) => u.plant_id === plantId);
  if (!users.length) throw new Error(`no users on plant ${plantId}`);
  const p: Plant = { id: plantId, name: users[0].plant_name || "your plant", tz: users[0].tz, users };
  const now = Math.floor(Date.now() / 1000), unsub = `${UNSUB}?t=sample&k=grid`;
  const out: Record<string, Email> = { welcome: welcome(), "account-deleted": accountDeleted(users[0].email) };
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
    ["battery-hot", { kind: "batt_hot", at: hhmm(now, p.tz), tempC: 42, hotDays: 3 }],
    ["batteries-uneven", { kind: "bank_drift", banks: [{ name: "Inverter 1", chargePct: 72 }, { name: "Inverter 2", chargePct: 60 }] }],
    ["panels-stopped", { kind: "string_dead", string: "String 3", inverter: "Inverter 1", since: hhmm(now - 1200, p.tz) }],
    ["no-readings", { kind: "logger_stale", since: hhmm(now - 1200, p.tz) }],
    ["readings-back", { kind: "logger_back", at: hhmm(now, p.tz), lasted: lasted(now - 6420, now) }],
    ["reconnect", { kind: "needs_relink" }],
  ];
  for (const [name, e] of ev) out[name] = plantEvent(p.name, p.id, e, e.kind === "needs_relink" ? "" : unsub);
  return out;
}

Deno.serve(async (req) => {
  const denied = denyUnlessServer(req);
  if (denied) return denied;
  const url = new URL(req.url);
  try {
    if (url.searchParams.get("render") === "all") return json(await renderAll(Number(url.searchParams.get("plant")), url.searchParams.get("today") ?? undefined));
    const dry = !LIVE || !RESEND_KEY || url.searchParams.get("dry") === "1";
    return json(await run(dry, url.searchParams.get("html") === "1"));
  } catch (e) {
    console.error("notify failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
