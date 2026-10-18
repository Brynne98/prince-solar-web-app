// Every email Prince Solar sends, as { subject, html, text }.
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
export const FROM_ACCOUNT = "Prince Solar <noreply@princesolarhub.com>";
export const FROM_NOTICE = "Prince Solar <hello@princesolarhub.com>";

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
  | { note: string };

type Body = { title: string; sub?: string; parts: Part[]; footer: string[] };

function html(subject: string, b: Body): string {
  const rows = b.parts.map((x) => {
    if ("p" in x) return `<p class="t" style="margin:0 0 16px;font:400 15px/1.55 ${SANS};color:#e7ecf2">${x.p}</p>`;
    if ("note" in x) return `<p class="m" style="margin:0 0 16px;font:400 13px/1.5 ${SANS};color:#9aa5b3">${x.note}</p>`;
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
<tr><td style="padding:0 4px 16px"><a href="${SITE}" style="text-decoration:none"><img src="${SITE}/icon-192.png" width="28" height="28" alt="" style="vertical-align:middle;border:0;border-radius:6px"> <span class="t" style="vertical-align:middle;font:700 17px/1 ${SANS};color:#e7ecf2">Prince Solar</span></a></td></tr>
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
  account("Confirm your email", "Confirm your email", "Tap the button to finish setting up Prince Solar.",
    "Confirm email", url, "Didn't sign up? Ignore this email.");

export const resetPassword = (url: string) =>
  account("Reset your password", "Reset your password", "Tap the button to choose a new password.",
    "Reset password", url, "Didn't ask for this? Ignore this email. Your password stays the same.");

export const confirmEmailChange = (url: string, newEmail: string) =>
  account("Confirm your new email", "Confirm your new email", `Tap the button to use <b>${esc(newEmail)}</b> for Prince Solar.`,
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
    parts: [{ p: `Prince Solar now uses <b>${esc(newEmail)}</b> instead of ${esc(oldEmail)}. Changed on ${when(w)}.` },
      { p: "This is the last email to this address." }, ...notYou],
    footer: [`Questions? Write to <a href="mailto:hello@princesolarhub.com">hello@princesolarhub.com</a>.`, COMPANY],
  });

export const accountDeleted = (email: string) =>
  make("Your account is deleted", {
    title: "Your account is deleted",
    parts: [{ p: `The Prince Solar account for <b>${esc(email)}</b> is deleted, with all its readings and settings.` },
      { p: "Your SunSynk account and your inverter are not affected." },
      { note: "You can sign up again any time. History comes back only as far as SunSynk still keeps it." }],
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
  `${what} for ${esc(plant)}. Change which emails you get in <a href="${SITE}/?tab=settings">Settings</a>.`,
  unsubscribeUrl ? `<a href="${unsubscribeUrl}">Unsubscribe</a> · ${COMPANY}` : COMPANY,
];

export const welcome = (plant: string) =>
  make(`${plant} is connected`, {
    title: `${plant} is connected`,
    parts: [
      { p: "Live readings start now. Older history is syncing; we'll email when it's in." },
      { p: "A monthly report comes on the 1st. Pick weekly or yearly in Settings." },
      { button: { label: "Open Prince Solar", href: SITE } },
    ],
    footer: NOTICE_FOOTER(plant, "Sent once"),
  });

export const historySynced = (plant: string, days: number, from: string, madeKwh: number, gapDays: number) => {
  const [v, u] = kwh(madeKwh);
  return make(`${plant}: your history is in`, {
    title: "Your history is in",
    sub: plant,
    parts: [
      { stats: [
        { label: "Days", value: String(days), sub: `From ${from}` },
        { label: "Made", value: v, unit: u, tone: "solar", sub: "In that time" },
      ] },
      { p: "Trends, battery health and your best days now cover all of it." },
      ...(gapDays > 0 ? [{ note: `SunSynk had nothing for ${gapDays} ${gapDays === 1 ? "day" : "days"}. Those stay as gaps.` }] : []),
      { button: { label: "See trends", href: `${SITE}/?tab=trends` } },
    ],
    footer: NOTICE_FOOTER(plant, "Sent once"),
  });
};

// SunSynk's own service is down: every plant is affected, not one inverter.
export const sunsynkDown = (plant: string, since: string, unsubscribeUrl: string) =>
  make("SunSynk is not answering", {
    title: "SunSynk is not answering",
    parts: [
      { p: `SunSynk's service stopped answering at <b>${since}</b>, so no new readings are arriving for ${esc(plant)}.` },
      { p: "Your inverter keeps running as normal. Once SunSynk is back, we fill the gap from what SunSynk kept." },
    ],
    footer: NOTICE_FOOTER(plant, "Plant event", unsubscribeUrl),
  });

export const sunsynkBack = (plant: string, at: string, lasted: string, refilled: boolean, unsubscribeUrl: string) =>
  make("SunSynk is back", {
    title: "SunSynk is back",
    parts: [
      { p: `Readings for ${esc(plant)} resumed at <b>${at}</b>, after ${lasted}.` },
      { p: refilled ? "The gap is filled from SunSynk's records." : "SunSynk kept nothing for that time, so it stays as a gap." },
      { button: { label: "Open Prince Solar", href: SITE } },
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
  parts.push({ button: { label: "Open Prince Solar", href: `${SITE}/?tab=trends` } });
  return make(`${r.label}: ${mv} ${mu} of solar`, {
    title: r.label,
    sub: r.plant,
    parts,
    footer: [
      `${EVERY[r.period]} report for ${esc(r.plant)}. Change how often, or switch it off, in <a href="${SITE}/?tab=settings">Settings</a>.`,
      `<a href="${r.unsubscribeUrl}">Unsubscribe</a> · ${COMPANY}`,
    ],
  });
}

// ---------------------------------------------------------------- plant events

// Kinds match api_alerts_due (migrations 0016-0057), plus the "back" and relink mails.
export type PlantEvent =
  | { kind: "grid_down"; at: string; chargePct: number | null }
  | { kind: "grid_back"; at: string; lasted: string }
  | { kind: "grid_seen"; at: string }
  | { kind: "soc_overnight"; at: string; chargePct: number }
  | { kind: "batt_hot"; at: string; tempC: number }
  | { kind: "bank_drift"; bank: string; other: string; diffPct: number }
  | { kind: "string_dead"; string: string; inverter: string; from: string; to: string }
  | { kind: "logger_stale"; inverter: string; since: string }
  | { kind: "logger_back"; inverter: string; at: string; lasted: string }
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
        return [`Grid back at ${plant}`, `Grid power returned at <b>${e.at}</b>, after ${e.lasted}.`];
      case "grid_seen":
        return [`Grid power seen at ${plant}`, `${P} is set as off-grid, but the inverter saw grid power at <b>${e.at}</b>.`];
      case "soc_overnight":
        return [`Battery low overnight at ${plant}`, `Charge fell to ${e.chargePct}% at <b>${e.at}</b>, before solar started.`];
      case "batt_hot":
        return [`Battery hot at ${plant}`, `Battery temperature reached ${e.tempC} °C at <b>${e.at}</b>.`];
      case "bank_drift":
        return [`Batteries out of step at ${plant}`, `${esc(e.bank)} reads ${e.diffPct}% less charge than ${esc(e.other)}.`];
      case "string_dead":
        return [`Panel string not producing at ${plant}`, `${esc(e.string)} on ${esc(e.inverter)} made nothing from ${e.from} to ${e.to}, while the others did.`];
      case "logger_stale":
        return [`Inverter not reporting at ${plant}`, `No readings from ${esc(e.inverter)} since <b>${e.since}</b>.`];
      case "logger_back":
        return [`Inverter reporting again at ${plant}`, `Readings from ${esc(e.inverter)} resumed at <b>${e.at}</b>, after ${e.lasted}. The gap stays in your history.`];
      case "needs_relink":
        return ["Reconnect your SunSynk login", "SunSynk stopped accepting the saved login, so new readings aren't arriving. Sign in again to resume."];
    }
  })();
  const relink = e.kind === "needs_relink";
  return make(title, {
    title,
    parts: [{ p: lead }, { button: relink ? { label: "Reconnect", href: `${SITE}/?tab=settings` } : { label: "Open Prince Solar", href: SITE } }],
    footer: [
      `Plant event for ${P}. Switch these off in <a href="${SITE}/?tab=settings">Settings</a>.`,
      `<a href="${unsubscribeUrl}">Unsubscribe</a> · ${COMPANY}`,
    ],
  });
}
