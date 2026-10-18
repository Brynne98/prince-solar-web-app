// Preview every email with sample data, or send them as test mail.
//
//   node scripts/email-preview.mts <out-dir>
//     Writes each email as <name>.html and <name>-dark.html (the dark scheme forced on),
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
  confirmEmailChange, confirmSignup, FROM_ACCOUNT, FROM_NOTICE, plantEvent,
  renderAuthTemplates, report, resetPassword, SITE,
}: typeof import("../supabase/functions/_shared/email.ts") = await import(copy);

const PLANT = "Home";
const UNSUB = `${SITE}/?unsubscribe=sample`;
const LINK = `${SITE}/#sample-link`;

const base = {
  plant: PLANT, madeKwh: 812.4, homeKwh: 905.2, importKwh: 214.7, exportKwh: null,
  independencePct: 76, savedRand: 2140, gapDays: 0, unsubscribeUrl: UNSUB,
};

const mails: Record<string, [from: string, mail: Email]> = {
  "confirm-signup": [FROM_ACCOUNT, confirmSignup(LINK)],
  "reset-password": [FROM_ACCOUNT, resetPassword(LINK)],
  "confirm-email-change": [FROM_ACCOUNT, confirmEmailChange(LINK, "new@example.com")],
  "report-month": [FROM_NOTICE, report({
    ...base, period: "month", label: "October 2026", prevLabel: "September",
    change: { made: 12, home: -3, import: -21, independence: 6, saved: 9 },
    bestDay: { label: "14 Oct", kwh: 34.6 }, gapDays: 2,
  })],
  "report-week": [FROM_NOTICE, report({
    ...base, period: "week", label: "Week of 6 Oct", prevLabel: "last week",
    madeKwh: 191.3, homeKwh: 208.9, importKwh: 47.2, independencePct: 77, savedRand: 495,
    change: { made: 4, home: 1, import: -8, independence: 2, saved: 5 },
    bestDay: { label: "Thu 9 Oct", kwh: 33.1 },
  })],
  "report-year": [FROM_NOTICE, report({
    ...base, period: "year", label: "2026", prevLabel: "2025",
    madeKwh: 9420, homeKwh: 10870, importKwh: 2710, exportKwh: 310, independencePct: 75, savedRand: 25300,
    change: {}, bestDay: { label: "3 Jan", kwh: 41.2 },
  })],
  "event-grid-down": [FROM_NOTICE, plantEvent(PLANT, { kind: "grid_down", at: "14:32", chargePct: 62 }, UNSUB)],
  "event-grid-back": [FROM_NOTICE, plantEvent(PLANT, { kind: "grid_back", at: "16:05", lasted: "1 h 33 min" }, UNSUB)],
  "event-grid-seen": [FROM_NOTICE, plantEvent(PLANT, { kind: "grid_seen", at: "09:12" }, UNSUB)],
  "event-battery-low": [FROM_NOTICE, plantEvent(PLANT, { kind: "soc_overnight", at: "04:40", chargePct: 12 }, UNSUB)],
  "event-battery-hot": [FROM_NOTICE, plantEvent(PLANT, { kind: "batt_hot", at: "13:20", tempC: 48 }, UNSUB)],
  "event-banks-drift": [FROM_NOTICE, plantEvent(PLANT, { kind: "bank_drift", bank: "Bank 2", other: "Bank 1", diffPct: 18 }, UNSUB)],
  "event-string-dead": [FROM_NOTICE, plantEvent(PLANT, { kind: "string_dead", string: "String 3", inverter: "Inverter 2", from: "11:00", to: "14:00" }, UNSUB)],
  "event-inverter-silent": [FROM_NOTICE, plantEvent(PLANT, { kind: "logger_stale", inverter: "Inverter 1", since: "08:15" }, UNSUB)],
  "event-inverter-back": [FROM_NOTICE, plantEvent(PLANT, { kind: "logger_back", inverter: "Inverter 1", at: "10:02", lasted: "1 h 47 min" }, UNSUB)],
  "event-relink": [FROM_NOTICE, plantEvent(PLANT, { kind: "needs_relink" }, UNSUB)],
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
  const forceDark = (h: string) => h.replace("@media (prefers-color-scheme:dark){", "@media all{");
  const items: string[] = [];
  for (const [name, [from, m]] of Object.entries(mails)) {
    writeFileSync(join(out, `${name}.html`), m.html);
    writeFileSync(join(out, `${name}-dark.html`), forceDark(m.html));
    writeFileSync(join(out, `${name}.txt`), m.text);
    items.push(`<li><a href="${name}.html">${name}</a> · <a href="${name}-dark.html">dark</a> · <a href="${name}.txt">text</a> — ${from.replace(/</g, "&lt;")} — ${m.subject}</li>`);
  }
  writeFileSync(join(out, "index.html"), `<!doctype html><meta charset="utf-8"><title>Emails</title><ul style="font:14px/1.8 system-ui">${items.join("")}</ul>`);
  const tpl = new URL("../supabase/templates/", import.meta.url);
  mkdirSync(tpl, { recursive: true });
  for (const [name, m] of Object.entries(renderAuthTemplates())) writeFileSync(new URL(`${name}.html`, tpl), m.html);
  console.log(`${Object.keys(mails).length} emails written to ${out}; auth templates in supabase/templates/`);
}
