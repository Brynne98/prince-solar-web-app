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
  accountDeleted, confirmSignup, FROM_ACCOUNT, FROM_NOTICE, historySynced, movedToFree,
  passwordChanged, paymentFailed, paymentReceived, planChangeBooked, plantEvent, plantsRemovalSoon, planUpgraded,
  renderAuthTemplates, report, resetPassword, SITE, APP, sunsynkBack, sunsynkDown, welcome,
}: typeof import("../supabase/functions/_shared/email.ts") = await import(copy);

const PLANT = "Home";
const PLANT_ID = 538820;
const UNSUB = `${APP}/?unsubscribe=sample`;
const LINK = `${APP}/#sample-link`;

const base = {
  plant: PLANT, plantId: PLANT_ID, madeKwh: 812.4, homeKwh: 905.2, importKwh: 214.7, exportKwh: null,
  independencePct: 76, savedRand: 2140, unsubscribeUrl: UNSUB,
};

const mails: Record<string, [from: string, mail: Email]> = {
  "confirm-signup": [FROM_ACCOUNT, confirmSignup(LINK)],
  "reset-password": [FROM_ACCOUNT, resetPassword(LINK)],
  "password-changed": [FROM_ACCOUNT, passwordChanged("you@example.com")],
  "account-deleted": [FROM_ACCOUNT, accountDeleted("you@example.com")],
  "welcome": [FROM_NOTICE, welcome()],
  "history-synced": [FROM_NOTICE, historySynced({
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
  "event-sunsynk-down": [FROM_NOTICE, sunsynkDown(PLANT, PLANT_ID, "09:10", UNSUB)],
  "event-sunsynk-back": [FROM_NOTICE, sunsynkBack(PLANT, PLANT_ID, "11:42", "2 h 32 min", UNSUB)],
  "report-month": [FROM_NOTICE, report({
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
  "report-week": [FROM_NOTICE, report({
    ...base, period: "week", label: "6 – 12 Oct 2026", prevLabel: "last week",
    madeKwh: 191.3, homeKwh: 208.9, importKwh: 47.2, independencePct: 77, savedRand: 495,
    change: { made: 4, home: 1, import: -8, independence: 2, saved: 5 },
    bestDay: { label: "Thu 9 Oct", kwh: 33.1 }, highestUse: { label: "Sat 11 Oct", kwh: 38.4 },
    daily: { from: "Mon 6 Oct", to: "Sun 12 Oct", values: [27.4, 29.8, 18.2, 33.1, 30.6, 24.9, 27.3],
      labels: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
      titles: ["Mon 6 Oct: 27.4 kWh", "Tue 7 Oct: 29.8 kWh", "Wed 8 Oct: 18.2 kWh", "Thu 9 Oct: 33.1 kWh", "Fri 10 Oct: 30.6 kWh", "Sat 11 Oct: 24.9 kWh", "Sun 12 Oct: 27.3 kWh"] },
  })],
  "report-year": [FROM_NOTICE, report({
    ...base, period: "year", label: "2026", prevLabel: "2025",
    madeKwh: 9420, homeKwh: 10870, importKwh: 2710, exportKwh: null, independencePct: 75, savedRand: 25300,
    change: { made: 6, home: 2, import: -9, independence: 3, saved: 11 }, bestDay: { label: "3 Jan", kwh: 41.2 }, highestUse: { label: "21 Jun", kwh: 52.3 },
    daily: { from: "Jan", to: "Dec", values: [1040, 930, 890, 720, 610, 520, 560, 680, 790, 880, 920, 880], labels: ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"] },
  })],
  "report-week-free-ends": [FROM_NOTICE, report({
    ...base, period: "week", label: "6 – 12 Oct 2026", prevLabel: "last week", freeWeekEnds: true,
    madeKwh: 191.3, homeKwh: 208.9, importKwh: 47.2, independencePct: 77, savedRand: 495, change: {},
    bestDay: { label: "Thu 9 Oct", kwh: 33.1 }, highestUse: { label: "Sat 11 Oct", kwh: 38.4 },
    daily: { from: "Mon 6 Oct", to: "Sun 12 Oct", values: [27.4, 29.8, 18.2, 33.1, 30.6, 24.9, 27.3], labels: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] },
  })],
  // Billing (SOLAR-208)
  "billing-receipt": [FROM_NOTICE, paymentReceived({ plan: "family", period: "monthly", amount: 228, date: "1 Nov 2026", card: "Visa ending 4081",
    reference: "PSH-7Q2K9X", extraInverters: 1, next: { amount: 228, date: "1 Dec" } })],
  "billing-upgraded": [FROM_NOTICE, planUpgraded({ from: "home", to: "family", period: "monthly", paidNow: 43, daysLeft: 16, next: { amount: 179, date: "1 Dec" } })],
  "billing-inverters-added": [FROM_NOTICE, planUpgraded({ from: "family", to: "family", period: "monthly", addedInverters: 2, paidNow: 52, daysLeft: 16, next: { amount: 277, date: "1 Dec" } })],
  "billing-downgrade-booked": [FROM_NOTICE, planChangeBooked({ from: "family", to: "home", fromPeriod: "monthly", on: "1 Dec", removePlants: ["Cabin", "Office"], next: { amount: 99 } })],
  "billing-cancel-booked": [FROM_NOTICE, planChangeBooked({ from: "home", to: "free", fromPeriod: "monthly", on: "1 Dec", removePlants: [] })],
  "billing-switch-booked": [FROM_NOTICE, planChangeBooked({ from: "home", to: "home", fromPeriod: "monthly", toPeriod: "yearly", on: "1 Dec", removePlants: [], next: { amount: 999 } })],
  "billing-failed-1": [FROM_NOTICE, paymentFailed({ plan: "family", period: "monthly", amount: 179, card: "Visa ending 4081", nextTry: "3 Dec", freeOn: "8 Dec", payUrl: `${APP}/#pay` })],
  "billing-failed-last": [FROM_NOTICE, paymentFailed({ plan: "family", period: "monthly", amount: 179, card: "Visa ending 4081", freeOn: "8 Dec", payUrl: `${APP}/#pay` })],
  "billing-moved-to-free": [FROM_NOTICE, movedToFree({ from: "family", kept: "Home", stopped: ["Cabin", "Office"], deleteOn: "7 Jan", payUrl: `${APP}/#pay` })],
  "billing-removal-soon": [FROM_NOTICE, plantsRemovalSoon(["Cabin", "Office"], "7 Jan")],
  "event-grid-down": [FROM_NOTICE, plantEvent(PLANT, PLANT_ID, { kind: "grid_down", at: "14:32", chargePct: 62 }, UNSUB)],
  "event-grid-back": [FROM_NOTICE, plantEvent(PLANT, PLANT_ID, { kind: "grid_back", at: "16:05", lasted: "1 h 33 min" }, UNSUB)],
  "event-battery-hot": [FROM_NOTICE, plantEvent(PLANT, PLANT_ID, { kind: "batt_hot", at: "13:20", tempC: 42, hotDays: 3 }, UNSUB)],
  "event-battery-hot-first": [FROM_NOTICE, plantEvent(PLANT, PLANT_ID, { kind: "batt_hot", at: "13:20", tempC: 42, hotDays: 1 }, UNSUB)],
  "event-banks-drift": [FROM_NOTICE, plantEvent(PLANT, PLANT_ID, { kind: "bank_drift", banks: [{ name: "Inverter 2508290475", chargePct: 72 }, { name: "Inverter 2512082438", chargePct: 60 }] }, UNSUB)],
  "event-string-dead": [FROM_NOTICE, plantEvent(PLANT, PLANT_ID, { kind: "string_dead", string: "String 3", inverter: "Inverter 2512082438", since: "11:40" }, UNSUB)],
  "event-inverter-silent": [FROM_NOTICE, plantEvent(PLANT, PLANT_ID, { kind: "logger_stale", since: "08:15" }, UNSUB)],
  "event-inverter-back": [FROM_NOTICE, plantEvent(PLANT, PLANT_ID, { kind: "logger_back", at: "10:02", lasted: "1 h 47 min" }, UNSUB)],
  "event-relink": [FROM_NOTICE, plantEvent(PLANT, PLANT_ID, { kind: "needs_relink" }, UNSUB)],
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
      body: JSON.stringify({ from, to, subject: `[Test] ${m.subject}`, html: m.html, text: m.text }),
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
