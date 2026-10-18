// Every email Prince Solar Hub sends, as { subject, html, text }.
//
// Plain TypeScript with no Deno or Node APIs, so an Edge Function can import it and
// scripts/email-preview.ts can run it under Node to preview and send test mail.
//
// Senders (SOLAR-84): account mail comes from noreply@, reports and plant events from
// hello@ so a reply reaches the support inbox (SOLAR-114).
//
// Account mail is sent by Supabase Auth, not by us: renderAuthTemplates() fills the
// links with Supabase's Go placeholders ({{ .ConfirmationURL }}) and the output is
// pasted into Dashboard -> Authentication -> Emails.
//
// Look: DESIGN.md. Dark only, like the app (decided 2026-10-18, SOLAR-117); colour
// goes on the value, never the card.

export const SITE = "https://princesolarhub.com";
// Email choices are per person, so they belong on Account (logins, delete) rather
// than Settings (plant, tariff, battery). Relink is on Account too.
const PREFS = `${SITE}/?tab=account`;
export const FROM_ACCOUNT = "Prince Solar Hub <noreply@princesolarhub.com>";
export const FROM_NOTICE = "Prince Solar Hub <hello@princesolarhub.com>";

export type Email = { subject: string; html: string; text: string };

const C = {
  solar: "#3ddc84",
  home: "#f87171",
  grid: "#facc15",
  cyan: "#22d3ee",
  batt: "#a78bfa",
} as const;
type Tone = keyof typeof C;

const esc = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

const SANS = "'Space Grotesk',-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";
const MONO = "'JetBrains Mono',ui-monospace,Menlo,Consolas,monospace";

const STYLE = `
:root{color-scheme:dark;supported-color-schemes:dark}
body{margin:0;padding:0;background:#0a0d12}
a{color:inherit}
@media (max-width:520px){.tile{display:block!important;width:auto!important;margin-bottom:8px!important}.pad{padding:24px 20px!important}}
`;

type Part =
  | { p: string } // a paragraph; may hold <b> set by us, never user text unescaped
  | { button: { label: string; href: string } }
  | { link: string } // the raw link under a button, for clients that drop buttons
  | { stats: { label: string; value: string; unit?: string; tone?: Tone; sub?: string }[] }
  | { note: string }
  | { steps: string[] } // numbered how-to; may hold <b> set by us
  | { bars: { values: (number | null)[]; from: string; to: string } }; // daily solar kWh; null = no data

type Body = { title: string; sub?: string; parts: Part[]; footer: string[] };

function html(subject: string, b: Body): string {
  const rows = b.parts.map((x) => {
    if ("p" in x) return `<p class="t" style="margin:0 0 16px;font:400 15px/1.55 ${SANS};color:#e7ecf2">${x.p}</p>`;
    if ("note" in x) return `<p class="m" style="margin:0 0 16px;font:400 13px/1.5 ${SANS};color:#9aa5b3">${x.note}</p>`;
    if ("steps" in x)
      return `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 0 16px">${x.steps.map((s, i) =>
        `<tr><td style="vertical-align:top;padding:0 12px 12px 0"><div style="width:24px;height:24px;border-radius:12px;background:#141a22;border:1px solid rgba(255,255,255,.12);font:700 12px/24px ${MONO};color:#3ddc84;text-align:center">${i + 1}</div></td>` +
        `<td style="vertical-align:top;padding:2px 0 12px;font:400 15px/1.5 ${SANS};color:#e7ecf2">${s}</td></tr>`).join("")}</table>`;
    if ("bars" in x) {
      // A bar per day, drawn with table cells so it survives email clients that drop SVG
      // and images. A day with no data is a gap, never a zero bar.
      const max = Math.max(1, ...x.bars.values.map((v) => v ?? 0));
      const w = (100 / x.bars.values.length).toFixed(3);
      const cells = x.bars.values.map((v) => `<td width="${w}%" style="vertical-align:bottom;padding:0 1px">${v == null
        ? `<div style="height:2px;background:rgba(255,255,255,.07)"></div>`
        : `<div style="height:${Math.max(2, Math.round((v / max) * 64))}px;background:#3ddc84;border-radius:1px"></div>`}</td>`).join("");
      return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:4px 0 6px;height:64px"><tr style="height:64px">${cells}</tr></table>` +
        `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 18px"><tr><td style="font:400 12px/1 ${SANS};color:#7f8da0">${esc(x.bars.from)}</td><td align="right" style="font:400 12px/1 ${SANS};color:#7f8da0">${esc(x.bars.to)}</td></tr></table>`;
    }
    if ("link" in x)
      return `<p class="d" style="margin:0 0 8px;font:400 12px/1.5 ${SANS};color:#7f8da0;word-break:break-all">Or open this link: <a href="${x.link}" style="color:inherit">${x.link}</a></p>`;
    if ("button" in x)
      return `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 20px"><tr><td style="border-radius:8px;background:#3ddc84"><a href="${x.button.href}" style="display:inline-block;padding:12px 22px;font:600 15px/1 ${SANS};color:#0a0d12;text-decoration:none;border-radius:8px">${esc(x.button.label)}</a></td></tr></table>`;
    const cells = x.stats.map((s) => `<td class="tile" width="50%" style="padding:14px 16px;background:#141a22;border-radius:8px;vertical-align:top">
<div class="m" style="font:500 11px/1 ${SANS};letter-spacing:.12em;text-transform:uppercase;color:#9aa5b3">${esc(s.label)}</div>
<div class="${s.tone ?? "t"}" style="margin-top:8px;font:700 24px/1.1 ${MONO};font-variant-numeric:tabular-nums;color:${s.tone ? C[s.tone] : "#e7ecf2"}">${esc(s.value)}${s.unit ? `<span style="font-size:14px;opacity:.85"> ${esc(s.unit)}</span>` : ""}</div>
${s.sub ? `<div class="d" style="margin-top:6px;font:400 12px/1.4 ${SANS};color:#7f8da0">${esc(s.sub)}</div>` : ""}</td>`);
    const pairs: string[] = [];
    for (let i = 0; i < cells.length; i += 2)
      pairs.push(`<tr>${cells[i]}<td width="8" style="width:8px"></td>${cells[i + 1] ?? '<td class="tile" width="50%"></td>'}</tr><tr><td colspan="3" height="8" style="height:8px"></td></tr>`);
    return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:4px 0 12px">${pairs.join("")}</table>`;
  });

  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark"><meta name="supported-color-schemes" content="dark"><title>${esc(subject)}</title>
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=JetBrains+Mono:wght@700&display=swap" rel="stylesheet">
<style>${STYLE}</style></head>
<body class="bg" style="margin:0;padding:0;background:#0a0d12">
<table role="presentation" class="bg" width="100%" cellpadding="0" cellspacing="0" style="background:#0a0d12"><tr><td align="center" style="padding:28px 12px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px">
<tr><td style="padding:0 4px 16px"><a href="${SITE}" style="text-decoration:none"><img src="${SITE}/icon-192.png" width="28" height="28" alt="" style="vertical-align:middle;border:0;border-radius:6px"> <span class="t" style="vertical-align:middle;font:700 17px/1 ${SANS};color:#e7ecf2">Prince Solar Hub</span></a></td></tr>
<tr><td class="card pad" style="background:#11161d;border:1px solid rgba(255,255,255,.07);border-radius:12px;padding:32px 32px 20px">
<h1 class="t" style="margin:0 0 ${b.sub ? 4 : 16}px;font:700 22px/1.25 ${SANS};letter-spacing:-.02em;color:#e7ecf2">${esc(b.title)}</h1>
${b.sub ? `<p class="m" style="margin:0 0 20px;font:400 14px/1.4 ${SANS};color:#9aa5b3">${esc(b.sub)}</p>` : ""}
${rows.join("\n")}
</td></tr>
<tr><td style="padding:16px 4px 0">${b.footer.map((f) => `<p class="d" style="margin:0 0 6px;font:400 12px/1.5 ${SANS};color:#7f8da0">${f}</p>`).join("")}</td></tr>
</table></td></tr></table></body></html>`;
}

const strip = (s: string) => s.replace(/<[^>]+>/g, "").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"');

function text(b: Body): string {
  const out = [b.title, b.sub ?? "", ""];
  for (const x of b.parts) {
    if ("p" in x) out.push(strip(x.p), "");
    else if ("note" in x) out.push(strip(x.note), "");
    else if ("steps" in x) out.push(...x.steps.map((s, i) => `${i + 1}. ${strip(s)}`), "");
    else if ("button" in x) out.push(`${x.button.label}: ${x.button.href}`, "");
    else if ("stats" in x) out.push(...x.stats.map((s) => `${s.label}: ${s.value}${s.unit ? " " + s.unit : ""}${s.sub ? ` (${s.sub})` : ""}`), "");
  }
  out.push("--", ...b.footer.map(strip));
  return out.filter((l, i, a) => !(l === "" && a[i - 1] === "")).join("\n");
}

const make = (subject: string, b: Body): Email => ({ subject, html: html(subject, b), text: text(b) });

const COMPANY = "Theron and Prince Solutions (Pty) Ltd, South Africa";

// ---------------------------------------------------------------- account mail

function account(subject: string, title: string, lead: string, label: string, url: string, ignore: string): Email {
  return make(subject, {
    title,
    parts: [{ p: lead }, { button: { label, href: url } }, { link: url }],
    footer: [ignore, COMPANY],
  });
}

export const confirmSignup = (url: string) =>
  account("Confirm your email", "Confirm your email", "Tap the button to finish setting up Prince Solar Hub.",
    "Confirm email", url, "Didn't sign up? Ignore this email.");

export const resetPassword = (url: string) =>
  account("Reset your password", "Reset your password", "Tap the button to choose a new password.",
    "Reset password", url, "Didn't ask for this? Ignore this email. Your password stays the same.");

export const confirmEmailChange = (url: string, newEmail: string) =>
  account("Confirm your new email", "Confirm your new email", `Tap the button to use <b>${esc(newEmail)}</b> for Prince Solar Hub.`,
    "Confirm new email", url, "Didn't ask for this? Ignore this email.");

// Security notices: sent at once, after the change, so there is nothing to confirm.
// Common practice: say when and from what device, and give a "This wasn't me" button
// on our own domain. It lands on sign-in for now; opening "Forgot password?" directly
// needs an app change when these are wired (SOLAR-117).
type Where = { at: string; device?: string }; // "18 Oct 2026, 14:32"; "Chrome on Mac"
const when = (w: Where) => `<b>${esc(w.at)}</b>${w.device ? `, from ${esc(w.device)}` : ""}`;
const notYou = [
  { p: "Not you? Reset your password now, so only you can sign in." },
  { button: { label: "This wasn't me", href: SITE } },
  { note: `You can also open princesolarhub.com yourself and choose "Forgot password?".` },
];

export const passwordChanged = (email: string, w: Where) =>
  make("Your password was changed", {
    title: "Your password was changed",
    parts: [{ p: `The password for <b>${esc(email)}</b> was changed on ${when(w)}.` }, ...notYou],
    footer: [COMPANY],
  });

export const emailChanged = (oldEmail: string, newEmail: string, w: Where) =>
  make("Your email was changed", {
    title: "Your email was changed",
    parts: [{ p: `Prince Solar Hub now uses <b>${esc(newEmail)}</b> instead of ${esc(oldEmail)}. Changed on ${when(w)}.` },
      { p: "This is the last email to this address." }, ...notYou],
    footer: [`Questions? Write to <a href="mailto:hello@princesolarhub.com">hello@princesolarhub.com</a>.`, COMPANY],
  });

export const accountDeleted = (email: string) =>
  make("Your account is deleted", {
    title: "Your account is deleted",
    parts: [{ p: `The Prince Solar Hub account for <b>${esc(email)}</b> is deleted, with its settings and SunSynk logins. Plant readings go too, unless someone else shares the plant.` },
      { p: "Your SunSynk account and your inverter are not affected." },
      { note: "You can sign up again any time. Only the last 60 days of history come back from SunSynk." }],
    footer: [COMPANY],
  });

// Supabase Auth fills these placeholders itself; they must reach it unescaped.
export function renderAuthTemplates(): Record<string, Email> {
  const URL = "{{ .ConfirmationURL }}";
  const e = confirmEmailChange(URL, "NEWEMAIL");
  return {
    confirmation: confirmSignup(URL),
    recovery: resetPassword(URL),
    email_change: { ...e, html: e.html.replace("NEWEMAIL", "{{ .NewEmail }}"), text: e.text.replace("NEWEMAIL", "{{ .NewEmail }}") },
  };
}

// ------------------------------------------------------------- getting started

const NOTICE_FOOTER = (plant: string, what: string, unsubscribeUrl?: string) => [
  `${what} for ${esc(plant)}. Change which emails you get in <a href="${PREFS}">Account</a>.`,
  unsubscribeUrl ? `<a href="${unsubscribeUrl}">Unsubscribe</a> · ${COMPANY}` : COMPANY,
];

// Sent once the email is confirmed, before any inverter is connected. The Connect
// card opens on Live when a user has no plant, so the button goes straight there.
// Wording matches link.jsx ("Connect your inverter", "Use the login from the
// SunSynk Connect app", "We never keep your password").
export const welcome = () =>
  make("Welcome to Prince Solar Hub", {
    title: "Welcome to Prince Solar Hub",
    parts: [
      { p: "One step left: connect your inverter." },
      { steps: [
        "Open Prince Solar Hub and sign in.",
        "Enter the email and password you use in the <b>SunSynk Connect</b> app.",
        "Live readings start at once. The last 60 days of history follow; we'll email when they're in.",
      ] },
      { button: { label: "Connect your inverter", href: SITE } },
      { note: "We never keep your SunSynk password. It's swapped for a key, then dropped." },
    ],
    footer: ["Questions? Reply to this email.", COMPANY],
  });

export type History = {
  plant: string;
  days: number;
  from: string; // "19 Aug"
  to: string; // "17 Oct"
  daily: (number | null)[]; // solar kWh per day, oldest first; null = SunSynk had nothing
  madeKwh: number;
  homeKwh: number;
  independencePct: number;
  importKwh: number | null; // null: no grid
  bestDay: { label: string; kwh: number };
  firstReport: string; // "1 Nov"
};

export const historySynced = (h: History) => {
  const [mv, mu] = kwh(h.madeKwh);
  const gaps = h.daily.filter((d) => d == null).length;
  return make(`${h.plant}: your last ${h.days} days are in`, {
    title: `Your last ${h.days} days are in`,
    sub: `${h.plant} · ${h.from} to ${h.to}`,
    parts: [
      { stats: [
        { label: "Made", value: mv, unit: mu, tone: "solar" },
        { label: "Home", value: kwh(h.homeKwh)[0], unit: kwh(h.homeKwh)[1], tone: "home" },
        ...(h.importKwh != null ? [{ label: "Imported", value: kwh(h.importKwh)[0], unit: kwh(h.importKwh)[1], tone: "grid" as Tone }] : []),
        { label: "Independence", value: `${Math.round(h.independencePct)}%`, tone: "cyan" },
      ] },
      { p: "Solar each day:" },
      { bars: { values: h.daily, from: h.from, to: h.to } },
      { p: `Best day: <b>${esc(h.bestDay.label)}</b>, ${kwh(h.bestDay.kwh).join(" ")} of solar.` },
      ...(gaps > 0 ? [{ note: `SunSynk had nothing for ${gaps} ${gaps === 1 ? "day" : "days"}, shown as ${gaps === 1 ? "a gap" : "gaps"}.` }] : []),
      { p: `Your first monthly report comes on ${esc(h.firstReport)}. Pick weekly or yearly in Account.` },
      { button: { label: "Open Prince Solar Hub", href: SITE } },
    ],
    footer: NOTICE_FOOTER(h.plant, "Sent once"),
  });
};

// SunSynk's own service is down: every plant is affected, not one inverter.
export const sunsynkDown = (plant: string, since: string, unsubscribeUrl: string) =>
  make("SunSynk is not answering", {
    title: "SunSynk is not answering",
    parts: [
      { p: `SunSynk's service stopped answering at <b>${since}</b>, so no new readings are arriving for ${esc(plant)}.` },
      { p: "Your inverter keeps running as normal. Once SunSynk is back, missing minutes are filled from SunSynk where it kept them." },
    ],
    footer: NOTICE_FOOTER(plant, "Plant event", unsubscribeUrl),
  });

export const sunsynkBack = (plant: string, at: string, lasted: string, refilled: boolean, unsubscribeUrl: string) =>
  make("SunSynk is back", {
    title: "SunSynk is back",
    parts: [
      { p: `Readings for ${esc(plant)} resumed at <b>${at}</b>, after ${lasted}.` },
      { p: refilled ? "The gap is filled from SunSynk's records." : "SunSynk kept nothing for that time, so it stays as a gap." },
      { button: { label: "Open Prince Solar Hub", href: SITE } },
    ],
    footer: NOTICE_FOOTER(plant, "Plant event", unsubscribeUrl),
  });

// --------------------------------------------------------------------- reports

export type Period = "week" | "month" | "year";

export type Report = {
  period: Period;
  label: string; // "October 2026", "Week of 6 Oct", "2026"
  prevLabel: string; // "September", "last week", "2025"
  plant: string;
  madeKwh: number;
  homeKwh: number;
  importKwh: number;
  exportKwh: number | null; // null: the plant doesn't export, so the tile is left out
  independencePct: number;
  savedRand: number | null; // null: no tariff set
  change: { made?: number; home?: number; import?: number; independence?: number; saved?: number }; // % vs prevLabel
  bestDay?: { label: string; kwh: number };
  yearSoFarKwh?: number; // solar made since 1 Jan; left out of the yearly report
  gapDays: number;
  unsubscribeUrl: string;
};

const kwh = (n: number): [string, string] => (n >= 1000 ? [(n / 1000).toFixed(2), "MWh"] : [n.toFixed(n < 100 ? 1 : 0), "kWh"]);
const pct = (n: number | undefined, prev: string) =>
  n == null || !isFinite(n) ? undefined : `${n > 0 ? "+" : n < 0 ? "−" : ""}${Math.abs(Math.round(n))}% on ${prev}`;
const rand = (n: number) => "R" + Math.round(n).toLocaleString("en-ZA").replace(/,/g, " ");
const EVERY: Record<Period, string> = { week: "Weekly", month: "Monthly", year: "Yearly" };

export function report(r: Report): Email {
  const [mv, mu] = kwh(r.madeKwh);
  const stats: Extract<Part, { stats: unknown }>["stats"] = [
    { label: "Made", value: mv, unit: mu, tone: "solar", sub: pct(r.change.made, r.prevLabel) },
    { label: "Home", value: kwh(r.homeKwh)[0], unit: kwh(r.homeKwh)[1], tone: "home", sub: pct(r.change.home, r.prevLabel) },
    { label: "Imported", value: kwh(r.importKwh)[0], unit: kwh(r.importKwh)[1], tone: "grid", sub: pct(r.change.import, r.prevLabel) },
    ...(r.exportKwh != null ? [{ label: "Exported", value: kwh(r.exportKwh)[0], unit: kwh(r.exportKwh)[1], tone: "grid" as Tone }] : []),
    { label: "Independence", value: `${Math.round(r.independencePct)}%`, tone: "cyan", sub: pct(r.change.independence, r.prevLabel) },
    ...(r.savedRand != null ? [{ label: "Est. saved", value: rand(r.savedRand), tone: "batt" as Tone, sub: pct(r.change.saved, r.prevLabel) }] : []),
  ];
  const parts: Part[] = [{ stats }];
  if (r.bestDay) parts.push({ p: `Best day: <b>${esc(r.bestDay.label)}</b>, ${kwh(r.bestDay.kwh).join(" ")} of solar.` });
  if (r.yearSoFarKwh != null && r.period !== "year") parts.push({ p: `Year so far: <b>${kwh(r.yearSoFarKwh).join(" ")}</b> of solar.` });
  if (r.gapDays > 0) parts.push({ note: `${r.gapDays} ${r.gapDays === 1 ? "day has" : "days have"} gaps in the readings, so totals may be low.` });
  parts.push({ button: { label: "Open Prince Solar Hub", href: SITE } });
  return make(`${r.label}: ${mv} ${mu} of solar`, {
    title: r.label,
    sub: r.plant,
    parts,
    footer: [
      `${EVERY[r.period]} report for ${esc(r.plant)}. Change how often, or switch it off, in <a href="${PREFS}">Account</a>.`,
      `<a href="${r.unsubscribeUrl}">Unsubscribe</a> · ${COMPANY}`,
    ],
  });
}

// ---------------------------------------------------------------- plant events

// Kinds and wording follow api_alerts_due_raw (0057) and its wrapper (0042):
//  grid_down     3 known minutes with no grid (>100 V); SQL gives no charge, the sender
//                may add the latest batt_soc
//  grid_back     grid present again after >=3 absent minutes; SQL gives no duration
//  grid_seen     a plant marked off-grid shows grid voltage on any phase
//  soc_overnight 18:00-06:00, at the current draw the battery reaches its reserve
//                before 06:00 (a forecast, not a low reading)
//  batt_hot      battery temperature above 35 C
//  bank_drift    charge % differs by 5 points or more between inverters' batteries
//  string_dead   11:00-14:59, a string dead for 15 min while another string on the
//                same inverter makes over 200 W
//  logger_stale  no new reading for the whole plant for 15 min
// logger_back and needs_relink have no SQL alert yet; the poller sets needs_relink.
export type PlantEvent =
  | { kind: "grid_down"; at: string; chargePct?: number }
  | { kind: "grid_back"; at: string; lasted?: string }
  | { kind: "grid_seen"; at: string }
  | { kind: "soc_overnight"; runOutAt: string; reservePct: number }
  | { kind: "batt_hot"; at: string; tempC: number }
  | { kind: "bank_drift"; banks: { name: string; chargePct: number }[] }
  | { kind: "string_dead"; string: string; inverter: string; since: string }
  | { kind: "logger_stale"; since: string }
  | { kind: "logger_back"; at: string; lasted: string }
  | { kind: "needs_relink" };

export function plantEvent(plant: string, e: PlantEvent, unsubscribeUrl: string): Email {
  const P = esc(plant);
  const [title, lead]: [string, string] = (() => {
    switch (e.kind) {
      case "grid_down":
        return [`Grid down at ${plant}`, e.chargePct == null
          ? `No grid power since <b>${e.at}</b>.`
          : `No grid power since <b>${e.at}</b>. The battery is running the house at ${e.chargePct}% charge.`];
      case "grid_back":
        return [`Grid back at ${plant}`, `Grid power returned at <b>${e.at}</b>${e.lasted ? `, after ${e.lasted}` : ""}.`];
      case "grid_seen":
        return [`Grid power seen at ${plant}`, `${P} is marked off-grid, but grid power showed up at <b>${e.at}</b>.`];
      case "soc_overnight":
        return [`Battery may run low tonight at ${plant}`, `At the current draw, the battery reaches its ${e.reservePct}% reserve around <b>${e.runOutAt}</b>, before 06:00.`];
      case "batt_hot":
        return [`Battery hot at ${plant}`, `Battery temperature reached ${e.tempC} °C at <b>${e.at}</b>.`];
      case "bank_drift":
        return [`Batteries out of step at ${plant}`, `Their charge has moved apart: ${e.banks.map((b) => `${esc(b.name)} ${b.chargePct}%`).join(", ")}.`];
      case "string_dead":
        return [`Panel string not producing at ${plant}`, `${esc(e.string)} on ${esc(e.inverter)} has made nothing since <b>${e.since}</b>, while another string on it is producing.`];
      case "logger_stale":
        return [`No readings from ${plant}`, `No new readings since <b>${e.since}</b>.`];
      case "logger_back":
        return [`Readings back at ${plant}`, `Readings resumed at <b>${e.at}</b>, after ${e.lasted}. Missing minutes are filled from SunSynk where it kept them.`];
      case "needs_relink":
        return ["Reconnect your SunSynk login", "SunSynk stopped accepting the saved login, so new readings aren't arriving. Enter your SunSynk password again in Account to resume."];
    }
  })();
  const relink = e.kind === "needs_relink";
  return make(title, {
    title,
    parts: [{ p: lead }, { button: relink ? { label: "Reconnect", href: PREFS } : { label: "Open Prince Solar Hub", href: SITE } }],
    footer: [
      `Plant event for ${P}. Switch these off in <a href="${PREFS}">Account</a>.`,
      `<a href="${unsubscribeUrl}">Unsubscribe</a> · ${COMPANY}`,
    ],
  });
}
