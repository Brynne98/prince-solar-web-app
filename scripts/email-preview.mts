// Preview every email with sample data, or send them as test mail.
//
//   node scripts/email-preview.mts <out-dir>
//     Writes each email as <name>.html and <name>.txt,
//     plus index.html listing them, and the three Supabase Auth templates into
//     supabase/templates/ for pasting into Dashboard -> Authentication -> Emails.
//
//   node --env-file=.env.local scripts/email-preview.mts --send you@example.com [name]
//     Sends every email (or just <name>) through Resend. Needs RESEND_API_KEY.
//     Subjects are prefixed "[Test]".
import { copyFileSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Email } from "../supabase/functions/_shared/email.ts";

// package.json has no "type": "module", so Node loads a .ts file as CommonJS and the
// exports vanish. A copy named .mts loads as an ES module; the Edge Functions keep the .ts.
const copy = join(mkdtempSync(join(tmpdir(), "email-")), "email.mts");
copyFileSync(new URL("../supabase/functions/_shared/email.ts", import.meta.url), copy);
const {
  accountDeleted, cardChanged, cardExpiring, confirmSignup, FROM_ACCOUNT, FROM_ALERTS, FROM_BILLING, FROM_HELLO, FROM_REPORTS, PAY_URL, REPLY_TO, freeWeekEndsSoon, freeWeekSetup, historySynced, movedToFree, offerEnds, renewalNotice, winback, needAHand,
  passwordChanged, paymentFailed, paymentReceived, paymentRefunded, planChangeBooked, planKept, plantEvent, loginEvent, plantsRemovalSoon, planSwitched, planUpgraded,
  renderAuthTemplates, report, resetPassword, SITE, APP, sunsynkBack, sunsynkDown, welcome,
}: typeof import("../supabase/functions/_shared/email.ts") = await import(copy);

const PLANT = "Home";
const PLANT_ID = 538820;
const LINK = `${APP}/#sample-link`;

const base = {
  plant: PLANT, plantId: PLANT_ID, madeKwh: 812.4, homeKwh: 905.2, importKwh: 214.7, exportKwh: null,
  independencePct: 76, savedRand: 2140,
};

const mails: Record<string, [from: string, mail: Email]> = {
  "confirm-signup": [FROM_ACCOUNT, confirmSignup(LINK, "you@example.com")],
  "reset-password": [FROM_ACCOUNT, resetPassword(LINK, "you@example.com")],
  "password-changed": [FROM_ACCOUNT, passwordChanged("you@example.com")],
  "account-deleted": [FROM_ACCOUNT, accountDeleted("you@example.com")],
  "welcome": [FROM_HELLO, welcome()],
  "history-synced": [FROM_HELLO, historySynced({
    plant: PLANT, plantId: PLANT_ID, days: 60, from: "19 Aug", to: "17 Oct", madeKwh: 1484, homeKwh: 1702, importKwh: 431, independencePct: 75,
    // A plausible spring: rising with the season, cloudy dips, three days SunSynk lost.
    ...(() => {
      const daily = Array.from({ length: 60 }, (_, i) => [17, 18, 41].includes(i) ? null : Math.round((16 + i * 0.22 + (i % 7 === 3 ? -9 : 0) + (i % 11 === 5 ? -6 : 0) + ((i * 37) % 5)) * 10) / 10);
      // Best day from the same values, 19 Aug being day 0.
      const top = Math.max(...daily.map((v) => v ?? -1));
      const d = new Date(Date.UTC(2026, 7, 19 + daily.indexOf(top)));
      return { daily, highestUse: { label: "4 Sep", kwh: 44.7 }, bestDay: { label: `${d.getUTCDate()} ${d.toLocaleString("en-GB", { month: "short", timeZone: "UTC" })}`, kwh: top } };
    })(),
  })],
  "event-sunsynk-down": [FROM_ALERTS, sunsynkDown(PLANT, PLANT_ID, "09:10")],
  "event-sunsynk-back": [FROM_ALERTS, sunsynkBack(PLANT, PLANT_ID, "09:10", "11:42", "2h 32m")],
  "report-month": [FROM_REPORTS, report({
    ...base, period: "month", label: "October 2026", prevLabel: "September",
    change: { made: 12, home: -3, import: -21, independence: 6, saved: 9 },
    highestUse: { label: "18 Oct", kwh: 41.0 },
    ...(() => {
      const values = Array.from({ length: 31 }, (_, i) => [8, 9].includes(i) ? null : Math.round((22 + i * 0.25 + (i % 6 === 2 ? -10 : 0) + ((i * 37) % 5)) * 10) / 10);
      // Best day comes from the same values, as the real report will.
      const top = Math.max(...values.map((v) => v ?? -1));
      return { bestDay: { label: `${values.indexOf(top) + 1} Oct`, kwh: top }, daily: { from: "1 Oct", to: "31 Oct", values,
        labels: values.map((_, i) => (i % 7 === 0 ? String(i + 1) : "")),
        titles: values.map((v, i) => `${i + 1} Oct: ${v == null ? "no data" : v + " kWh"}`) } };
    })(),
  })],
  "report-month-partial": [FROM_REPORTS, report({
    ...base, period: "month", label: "October 2026", prevLabel: "September", partialFrom: "20 Oct",
    madeKwh: 301.6, homeKwh: 338.4, importKwh: 79.5, independencePct: 77, savedRand: 790, change: {},
    bestDay: { label: "27 Oct", kwh: 31.2 }, highestUse: { label: "25 Oct", kwh: 36.8 },
    daily: { from: "1 Oct", to: "31 Oct", values: Array.from({ length: 31 }, (_, i) => i < 19 ? null : [26.1, 27.4, 24.0, 28.8, 19.5, 30.2, 25.7, 31.2, 29.0, 27.9, 22.6, 29.2][i - 19]),
      labels: Array.from({ length: 31 }, (_, i) => (i % 7 === 0 ? String(i + 1) : "")) },
  })],
  // A plant added on Thursday: counts from then, nothing to compare (SOLAR-305).
  "report-week-added": [FROM_REPORTS, report({
    ...base, period: "week", label: "2 – 8 Nov 2026", prevLabel: "last week", partialFrom: "5 Nov", partialWhy: "added",
    madeKwh: 108.4, homeKwh: 121.7, importKwh: 13.3, independencePct: 89, savedRand: 270, change: {},
    bestDay: { label: "Sat 7 Nov", kwh: 30.1 }, highestUse: { label: "Sun 8 Nov", kwh: 34.0 },
    daily: { from: "Mon 2 Nov", to: "Sun 8 Nov", values: [null, null, null, 26.2, 24.9, 30.1, 27.2],
      labels: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] },
  })],
  "report-week": [FROM_REPORTS, report({
    ...base, period: "week", label: "6 – 12 Oct 2026", prevLabel: "last week",
    madeKwh: 191.3, homeKwh: 208.9, importKwh: 47.2, independencePct: 77, savedRand: 495,
    change: { made: 4, home: 1, import: -8, independence: 2, saved: 5 },
    bestDay: { label: "Thu 9 Oct", kwh: 33.1 }, highestUse: { label: "Sat 11 Oct", kwh: 38.4 },
    daily: { from: "Mon 6 Oct", to: "Sun 12 Oct", values: [27.4, 29.8, 18.2, 33.1, 30.6, 24.9, 27.3],
      labels: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
      titles: ["Mon 6 Oct: 27.4 kWh", "Tue 7 Oct: 29.8 kWh", "Wed 8 Oct: 18.2 kWh", "Thu 9 Oct: 33.1 kWh", "Fri 10 Oct: 30.6 kWh", "Sat 11 Oct: 24.9 kWh", "Sun 12 Oct: 27.3 kWh"] },
  })],
  "report-year": [FROM_REPORTS, report({
    ...base, period: "year", label: "2026", prevLabel: "2025",
    madeKwh: 9420, homeKwh: 10870, importKwh: 2710, exportKwh: null, independencePct: 75, savedRand: 25300,
    change: { made: 6, home: 2, import: -9, independence: 3, saved: 11 }, bestDay: { label: "3 Jan", kwh: 41.2 }, highestUse: { label: "21 Jun", kwh: 52.3 },
    daily: { from: "Jan", to: "Dec", values: [1040, 930, 890, 720, 610, 520, 560, 680, 790, 880, 920, 880], labels: ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"] },
  })],
  "report-week-free-ends": [FROM_REPORTS, report({
    ...base, period: "week", label: "6 – 12 Oct 2026", prevLabel: "last week", freeWeekEnds: true,
    madeKwh: 191.3, homeKwh: 208.9, importKwh: 47.2, independencePct: 77, savedRand: 495, change: {},
    bestDay: { label: "Thu 9 Oct", kwh: 33.1 }, highestUse: { label: "Sat 11 Oct", kwh: 38.4 },
    daily: { from: "Mon 6 Oct", to: "Sun 12 Oct", values: [27.4, 29.8, 18.2, 33.1, 30.6, 24.9, 27.3], labels: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] },
  })],
  // Billing (SOLAR-208)
  "billing-receipt": [FROM_BILLING, paymentReceived({ plan: "family", period: "monthly", amount: 199, date: "1 Nov 2026", card: "Visa •••• 4081",
    reference: "PSH-7Q2K9X", covers: "1 to 30 Nov", next: { amount: 199, date: "1 Dec" } })],
  "billing-renewal-notice": [FROM_BILLING, renewalNotice({ plan: "family", amount: 1990, on: "1 Feb 2027", card: "Visa •••• 4081" })],
  "billing-offer-ends": [FROM_BILLING, offerEnds({ plan: "home", period: "monthly", was: 49, amount: 99, on: "3 Mar", card: "Visa •••• 4242" })],
  "billing-free-week-ends-soon": [FROM_BILLING, freeWeekEndsSoon("Monday", "Home", 58, 83)],
  "free-week-setup": [FROM_HELLO, freeWeekSetup(["rate", "size", "reserve", "panels"])],
  "winback": [FROM_HELLO, winback({ from: "home", keepUntil: "3 Jan 2027" })],
  "need-a-hand": [FROM_HELLO, needAHand()],
  "billing-switched": [FROM_BILLING, planSwitched({ plan: "home", period: "yearly", amount: 990, date: "1 Nov 2026", card: "Visa •••• 4081",
    reference: "psh_3f9a2c71", startsOn: "1 Dec 2026", covers: "1 Dec 2026 to 30 Nov 2027", next: { amount: 990, date: "1 Dec 2027" } })],
  "billing-upgraded": [FROM_BILLING, planUpgraded({ from: "home", to: "family", period: "monthly", paidNow: 53, daysLeft: 16, covers: "15 to 30 Nov", card: "Visa •••• 4081", next: { amount: 199, date: "1 Dec" } })],
  "billing-downgrade-booked": [FROM_BILLING, planChangeBooked({ from: "family", to: "home", fromPeriod: "monthly", on: "1 Dec", removePlants: ["Cabin", "Office"], keepPlants: ["Home", "Plot"], next: { amount: 99 } })],
  "billing-cancel-booked": [FROM_BILLING, planChangeBooked({ from: "home", to: "free", fromPeriod: "monthly", on: "1 Dec", removePlants: [] })],
  "billing-change-kept": [FROM_BILLING, planKept({ plan: "home", period: "monthly", next: { amount: 99, date: "1 Dec" }, undone: { to: "free" } })],
  "billing-switch-booked": [FROM_BILLING, planChangeBooked({ from: "home", to: "home", fromPeriod: "monthly", toPeriod: "yearly", on: "1 Dec", removePlants: [], next: { amount: 990 } })],
  "billing-failed-1": [FROM_BILLING, paymentFailed({ plan: "family", period: "monthly", amount: 199, card: "Visa •••• 4081", nextTry: "3 Dec", freeOn: "8 Dec", payUrl: PAY_URL })],
  "billing-refund": [FROM_BILLING, paymentRefunded({ amount: 72, date: "3 Dec", reference: "psh_0123", why: "price" })],
  "billing-failed-disputed": [FROM_BILLING, paymentFailed({ plan: "home", period: "monthly", amount: 99, card: "Visa •••• 4081", nextTry: "4 Dec", freeOn: "11 Dec", payUrl: PAY_URL, disputed: "10 Nov" })],
  "billing-failed-last": [FROM_BILLING, paymentFailed({ plan: "family", period: "monthly", amount: 199, card: "Visa •••• 4081", freeOn: "8 Dec", payUrl: PAY_URL })],
  "billing-moved-to-free": [FROM_BILLING, movedToFree({ from: "family", kept: "Home", stopped: ["Cabin", "Office"], deleteOn: "7 Jan", amount: 199 })],
  // SOLAR-406 (0161)
  "billing-card-changed": [FROM_BILLING, cardChanged({ card: "Visa •••• 4081", was: "Mastercard •••• 5520", at: "Today at 09:12", next: { amount: 199, date: "1 Dec" } })],
  "billing-card-expiring": [FROM_BILLING, cardExpiring({ card: "Visa •••• 4081", on: "30 Nov", next: { amount: 199, date: "1 Dec" } })],
  "billing-card-expiring-last": [FROM_BILLING, cardExpiring({ card: "Visa •••• 4081", on: "30 Nov", final: true, next: { amount: 199, date: "1 Dec" } })],
  "billing-removal-soon": [FROM_BILLING, plantsRemovalSoon(["Cabin", "Office"], "7 Jan", "free")],
  "event-grid-down": [FROM_ALERTS, plantEvent(PLANT, PLANT_ID, { kind: "grid_down", at: "14:32", chargePct: 62 })],
  "event-grid-back": [FROM_ALERTS, plantEvent(PLANT, PLANT_ID, { kind: "grid_back", since: "14:32", at: "16:05", lasted: "1h 33m", chargePct: 41 })],
  "event-battery-hot": [FROM_ALERTS, plantEvent(PLANT, PLANT_ID, { kind: "batt_hot", at: "13:20", tempC: 47, hotDays: 3 })],
  "event-battery-hot-first": [FROM_ALERTS, plantEvent(PLANT, PLANT_ID, { kind: "batt_hot", at: "13:20", tempC: 47, hotDays: 1 })],
  "event-banks-drift": [FROM_ALERTS, plantEvent(PLANT, PLANT_ID, { kind: "bank_drift", banks: [{ name: "Inverter 2508290475", chargePct: 72 }, { name: "Inverter 2508290476", chargePct: 60 }] })],
  "event-string-dead": [FROM_ALERTS, plantEvent(PLANT, PLANT_ID, { kind: "string_dead", string: "String 3", inverter: "Inverter 2508290476", since: "11:40" })],
  "event-inverter-silent": [FROM_ALERTS, plantEvent(PLANT, PLANT_ID, { kind: "logger_stale", since: "08:15", inverters: [{ name: "Inverter 2508290475", last: "08:15" }] })],
  "event-inverter-back": [FROM_ALERTS, plantEvent(PLANT, PLANT_ID, { kind: "logger_back", since: "08:15", at: "10:02", lasted: "1h 47m" })],
  "event-relink": [FROM_ALERTS, loginEvent({ kind: "needs_relink", plants: [PLANT, "Cabin"], at: "17:40" }, PLANT_ID)],
  "event-relinked": [FROM_ALERTS, loginEvent({ kind: "relinked", plants: [PLANT, "Cabin"], since: "17:40", at: "19:45", lasted: "2h 5m" }, PLANT_ID)],
  "event-string-back": [FROM_ALERTS, plantEvent(PLANT, PLANT_ID, { kind: "string_back", string: "String 3", inverter: "Inverter 2508290476", since: "11:40", at: "14:05", lasted: "2h 25m" })],
  "event-one-inverter-silent": [FROM_ALERTS, plantEvent(PLANT, PLANT_ID, { kind: "logger_stale", since: "08:15", inverter: "Inverter 2508290476", inverters: [{ name: "Inverter 2508290475", last: null }, { name: "Inverter 2508290476", last: "08:15" }] })],
};

const args = process.argv.slice(2);

if (args[0] === "--send") {
  const to = args[1];
  const only = args[2];
  const key = process.env.RESEND_API_KEY;
  if (!to || !key) throw new Error("usage: --send <to> [name], with RESEND_API_KEY set");
  for (const [name, [from, m]] of Object.entries(mails)) {
    if (only && name !== only) continue;
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from, reply_to: from === FROM_ACCOUNT ? undefined : REPLY_TO, to, subject: `[Test] ${m.subject}`, html: m.html, text: m.text }),
    });
    console.log(`${res.ok ? "sent" : "FAILED"} ${name}${res.ok ? "" : ": " + (await res.text())}`);
    if (!res.ok) process.exitCode = 1;
    await new Promise((r) => setTimeout(r, 600)); // Resend allows 2 requests a second
  }
} else {
  const out = args[0];
  if (!out) throw new Error("usage: node scripts/email-preview.mts <out-dir>");
  mkdirSync(out, { recursive: true });
  const items: string[] = [];
  for (const [name, [from, m]] of Object.entries(mails)) {
    writeFileSync(join(out, `${name}.html`), m.html);
    writeFileSync(join(out, `${name}.txt`), m.text);
    items.push(`<li><a href="${name}.html">${name}</a> · <a href="${name}.txt">text</a> — ${from.replace(/</g, "&lt;")} — ${m.subject}</li>`);
  }
  writeFileSync(join(out, "index.html"), `<!doctype html><meta charset="utf-8"><title>Emails</title><ul style="font:14px/1.8 system-ui">${items.join("")}</ul>`);
  const tpl = new URL("../supabase/templates/", import.meta.url);
  mkdirSync(tpl, { recursive: true });
  for (const [name, m] of Object.entries(renderAuthTemplates())) writeFileSync(new URL(`${name}.html`, tpl), m.html);
  console.log(`${Object.keys(mails).length} emails written to ${out}; auth templates in supabase/templates/`);
}
