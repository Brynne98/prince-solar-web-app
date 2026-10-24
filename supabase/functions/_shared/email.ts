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
// Buttons open the web app; SITE is the showcase and only hosts the logo.
export const APP = "https://app.princesolarhub.com";
// Email choices are per person, so they belong on Account (logins, delete) rather
// than Settings (plant, tariff, battery). Relink is on Account too.
// The footer's "notification settings" link opens Account's Notifications section (SOLAR-158).
const PREFS = `${APP}/?tab=account&section=notifications`;
// Reconnect lands on Account's SunSynk logins section and flashes it, like the app's own
// Reconnect (openSettings('connection')). ?section= needs SOLAR-156.
const LOGINS = `${APP}/?tab=account&section=logins`;
export const FROM_ACCOUNT = "Prince Solar Hub <noreply@princesolarhub.com>";
export const FROM_NOTICE = "Prince Solar Hub <hello@princesolarhub.com>";
// Supabase's link lifetime (Auth -> mailer OTP expiry), default 1 hour.
const LINK_LIFE = "This link works once and expires in 1 hour.";

// unsubscribe: the one-click link for the List-Unsubscribe header the sender adds, so
// mail apps show their own Unsubscribe next to the sender. It isn't in the body; the
// body points to the notification settings instead.
// The one help line every email ends with.
const HELP = `Need help? Email <a href="mailto:hello@princesolarhub.com">hello@princesolarhub.com</a>.`;

export type Email = { subject: string; html: string; text: string; unsubscribe?: string };

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
@media (max-width:520px){.pad{padding:20px 20px var(--pb-m,8px)!important}}
@media (max-width:440px){.flow{width:auto!important;display:block!important;margin-right:0!important}}
@media (max-width:340px){.card{width:auto!important;display:block!important;margin-right:0!important}}
`;

type Part =
  | { p: string } // a paragraph; may hold <b> set by us, never user text unescaped
  | { button: { label: string; href: string } }
  | { stats: { label: string; value: string; unit?: string; tone?: Tone; sub?: string; delta?: Delta }[]; stack?: boolean } // stack: may go full width on a phone (alerts); see below
  | { chart: { title: string; side?: string; bars: Bars; facts: { label: string; value: string; unit?: string; tone?: Tone; sub?: string }[] } }
  | { facts: { label: string; value: string }[] } // label left, value right
  | { callout: string } // a plain-language status line in a coral-edged panel
  | { note: string }
  | { steps: string[] } // numbered how-to; may hold <b> set by us
  | { bars: Bars }; // daily solar kWh; null = no data

// labels: one under each bar (a week); titles: the hover text per bar, where the mail app
// shows it (desktop only). The highest bar is drawn full green, the rest dimmer.
// A change on the previous period: the arrow and percent take the tone, the rest stays grey.
type Delta = { n: number; prev: string; tone?: "good" | "bad" };
type Bars = { values: (number | null)[]; from: string; to: string; labels?: string[]; titles?: string[] };

type Body = { title: string; sub?: string; parts: Part[]; footer: string[] };

function drawBars(b: Bars): string {
  // A bar per day, drawn with table cells so it survives email clients that drop SVG
  // and images. A day with no data is a faint stub, never a zero bar. Only the best
  // bar is green, with its value above it; the rest are grey. The same chart works for
  // 7, 12 or 31 bars.
  const H = 72;
  const v = b.values;
  const max = Math.max(1, ...v.map((n) => n ?? 0));
  const best = v.indexOf(Math.max(...v.map((n) => n ?? -1)));
  const w = (100 / v.length).toFixed(3);
  const pad = v.length > 12 ? 1 : 3;
  const td = (inner: string, i: number, style = "") =>
    `<td width="${w}%"${b.titles ? ` title="${esc(b.titles[i])}"` : ""} style="padding:0 ${pad}px;${style}">${inner}</td>`;
  const bar = (n: number | null, i: number) => n == null
    ? `<div style="height:2px;line-height:2px;font-size:1px;background:rgba(255,255,255,.08)">&nbsp;</div>`
    : `<div style="height:${Math.max(3, Math.round((n / max) * H))}px;line-height:1px;font-size:1px;background:${i === best ? "#3ddc84" : "#3a4654"};border-radius:3px 3px 0 0">&nbsp;</div>`;
  // The best value, with its unit, is wider than a bar, so its cell spans a few bars on
  // each side and centres over its own bar. At either end of the chart it can't span
  // both ways, so it lines up with that edge instead.
  const R = v.length > 12 ? 3 : 1;
  const lo = Math.max(0, best - R), hi = Math.min(v.length - 1, best + R);
  const r = Math.min(best - lo, hi - best);
  const [a0, a1, align] = lo === best ? [best, hi, "left"] : hi === best ? [lo, best, "right"] : [best - r, best + r, "center"];
  const empty = (i: number) => td("", i, "height:11px");
  // A fixed-layout table takes its column widths from the first row, so an empty row of
  // equal cells comes first; otherwise the spanning label cell squeezes its bars.
  const sizer = `<tr>${v.map(() => `<td width="${w}%" style="padding:0;height:0;line-height:0;font-size:0"></td>`).join("")}</tr>`;
  const tag = best < 0 ? "" : `<tr>${v.slice(0, a0).map((_, i) => empty(i)).join("")}` +
    `<td colspan="${a1 - a0 + 1}" style="padding:0 ${pad}px 5px;vertical-align:bottom;height:11px"><div style="font:700 11px/1 ${MONO};color:#3ddc84;text-align:${align};white-space:nowrap">${kwh(v[best]!).join(" ")}</div></td>` +
    `${v.slice(a1 + 1).map((_, i) => empty(a1 + 1 + i)).join("")}</tr>`;
  const bars = `<tr>${v.map((n, i) => td(bar(n, i), i, `vertical-align:bottom;height:${H}px`)).join("")}</tr>`;
  const under = b.labels
    ? `<tr>${b.labels.map((t, i) => td(`<div style="font:${i === best ? 700 : 400} 11px/1 ${MONO};color:${i === best ? "#e7ecf2" : "#7f8da0"};text-align:center;white-space:nowrap">${esc(t)}</div>`, i, "padding-top:7px")).join("")}</tr>`
    : "";
  const ends = b.labels ? "" :
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 6px"><tr><td style="font:400 12px/1 ${SANS};color:#7f8da0">${esc(b.from)}</td><td align="right" style="font:400 12px/1 ${SANS};color:#7f8da0">${esc(b.to)}</td></tr></table>`;
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="table-layout:fixed;margin:0 0 ${b.labels ? 16 : 6}px">${sizer}${tag}${bars}${under}</table>${ends}`;
}

const deltaHtml = (d: Delta) => {
  const r = Math.round(d.n);
  const tone = d.tone === "good" ? C.solar : d.tone === "bad" ? C.home : "#9aa5b3";
  return `<span style="color:${tone};font-weight:600">${r > 0 ? "↑" : r < 0 ? "↓" : "→"} ${Math.abs(r)}%</span> vs ${esc(d.prev)}`;
};
const deltaText = (d: Delta) => { const r = Math.round(d.n); return `${r > 0 ? "↑" : r < 0 ? "↓" : "→"} ${Math.abs(r)}% vs ${d.prev}`; };

function html(subject: string, b: Body): string {
  const rows = b.parts.map((x) => {
    if ("p" in x) return `<p class="t" style="margin:0 0 16px;font:400 15px/1.55 ${SANS};color:#e7ecf2">${x.p}</p>`;
    if ("note" in x) return `<p class="m" style="margin:0 0 16px;font:400 13px/1.5 ${SANS};color:#9aa5b3">${x.note}</p>`;
    if ("steps" in x)
      return `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 0 16px">${x.steps.map((s, i) =>
        `<tr><td style="vertical-align:top;padding:0 12px 12px 0"><div style="width:24px;height:24px;border-radius:12px;background:#141a22;border:1px solid rgba(255,255,255,.12);font:700 12px/24px ${MONO};color:#3ddc84;text-align:center">${i + 1}</div></td>` +
        `<td style="vertical-align:top;padding:2px 0 12px;font:400 15px/1.5 ${SANS};color:#e7ecf2">${s}</td></tr>`).join("")}</table>`;
    if ("bars" in x) return drawBars(x.bars);
    if ("chart" in x) {
      const c = x.chart;
      // The average sits under the title, not beside it, so the two never crowd on a phone.
      const head = `<div style="margin:0 0 14px"><div style="font:500 11px/1 ${SANS};letter-spacing:.12em;text-transform:uppercase;color:#9aa5b3">${esc(c.title)}</div>` +
        (c.side ? `<div style="margin-top:6px;font:400 12px/1.3 ${SANS};color:#7f8da0">${c.side}</div>` : "") + `</div>`;
      // Two figures to a row.
      const fact = (f: (typeof c.facts)[number], i: number) =>
        `<td width="50%" style="padding:14px ${i % 2 ? 0 : 12}px 0 0;vertical-align:top">` +
        `<div style="font:500 11px/1 ${SANS};letter-spacing:.12em;text-transform:uppercase;color:#9aa5b3">${esc(f.label)}</div>` +
        `<div style="margin-top:8px;font:700 16px/1.2 ${MONO};font-variant-numeric:tabular-nums;color:${f.tone ? C[f.tone] : "#e7ecf2"}">${f.value}${f.unit ? `<span style="font-size:12px;opacity:.85"> ${esc(f.unit)}</span>` : ""}</div>` +
        (f.sub ? `<div style="margin-top:4px;font:400 12px/1.3 ${SANS};color:#7f8da0">${esc(f.sub)}</div>` : "") + `</td>`;
      const rowsOf2: string[] = [];
      for (let i = 0; i < c.facts.length; i += 2)
        rowsOf2.push(`<tr>${fact(c.facts[i], 0)}${c.facts[i + 1] ? fact(c.facts[i + 1], 1) : '<td width="50%"></td>'}</tr>`);
      const facts = c.facts.length ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="table-layout:fixed;border-top:1px solid rgba(255,255,255,.07)">${rowsOf2.join("")}</table>` : "";
      return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 16px"><tr><td style="padding:16px;background:#141a22;border-radius:8px">${head}${drawBars(c.bars)}${facts}</td></tr></table>`;
    }
    if ("callout" in x)
      return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 16px"><tr><td style="padding:14px 16px;background:rgba(248,113,113,.07);border:1px solid rgba(248,113,113,.4);border-radius:8px;font:500 15px/1.45 ${SANS};color:#e7ecf2">` +
        `<span style="display:inline-block;width:8px;height:8px;border-radius:4px;background:${C.home};margin-right:10px;vertical-align:1px"></span>${x.callout}</td></tr></table>`;
    if ("facts" in x)
      return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 16px;border-top:1px solid rgba(255,255,255,.07)">${x.facts.map((f) =>
        `<tr><td style="padding:10px 0;border-bottom:1px solid rgba(255,255,255,.07);font:400 14px/1.3 ${SANS};color:#9aa5b3">${esc(f.label)}</td>` +
        `<td align="right" style="padding:10px 0;border-bottom:1px solid rgba(255,255,255,.07);font:700 14px/1.3 ${MONO};font-variant-numeric:tabular-nums;color:#e7ecf2">${f.value}</td></tr>`).join("")}</table>`;
    if ("button" in x)
      return `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 12px"><tr><td style="border-radius:8px;background:#3ddc84"><a href="${x.button.href}" style="display:inline-block;padding:12px 22px;font:600 15px/1 ${SANS};color:#0a0d12;text-decoration:none;border-radius:8px">${esc(x.button.label)}</a></td></tr></table>
<p class="d" style="margin:0 0 20px;font:400 12px/1.5 ${SANS};color:#7f8da0">Trouble with the button? <a href="${x.button.href}" style="color:inherit">Click here</a> instead.</p>`;
    const cells = x.stats.map((s) => `<td class="tile" width="50%" style="padding:16px;background:#141a22;border-radius:8px;vertical-align:top">
<div class="m" style="font:500 11px/1 ${SANS};letter-spacing:.12em;text-transform:uppercase;color:#9aa5b3">${esc(s.label)}</div>
<div class="${s.tone ?? "t"}" style="margin-top:8px;font:700 24px/1.1 ${MONO};font-variant-numeric:tabular-nums;color:${s.tone ? C[s.tone] : "#e7ecf2"}">${esc(s.value)}${s.unit ? `<span style="font-size:14px;opacity:.85"> ${esc(s.unit)}</span>` : ""}</div>
${s.delta ? `<div class="d" style="margin-top:6px;font:400 12px/1.4 ${SANS};color:#7f8da0">${deltaHtml(s.delta)}</div>` : s.sub ? `<div class="d" style="margin-top:6px;font:400 12px/1.4 ${SANS};color:#7f8da0">${esc(s.sub)}</div>` : ""}</td>`);
    // Every card takes half the width, a lone one included, so cards look the same in
    // every email. Two short cards fit side by side even on a phone (about 13 label and
    // 8 value characters per card at 375 px). Alert cards that are longer than that, or
    // alone, go full width on a phone, where the mail app honours the media query.
    // Below 340 px (the smallest phones) every card goes full width.
    const stack = x.stack && (x.stats.length === 1 || x.stats.some((s) => s.label.length > 13 || s.value.length > 8));
    const boxes = cells.map((c, i) => c.replace(/^<td class="tile" width="50%" style="/,
      `<div class="card${stack ? " flow" : ""}" style="display:inline-block;width:49%;box-sizing:border-box;margin:0 ${i % 2 ? 0 : "2%"} 8px 0;font-size:14px;`).replace(/<\/td>$/, "</div>"));
    return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:4px 0 4px"><tr><td style="font-size:0;line-height:0">${boxes.join("")}</td></tr></table>`;
  });

  // Every part ends in its own bottom margin; take it off the card's bottom padding so
  // the space under the last part matches the sides.
  const last = b.parts[b.parts.length - 1];
  const tail = !last ? 0 : "button" in last ? 20 : "stats" in last ? 12 : "steps" in last ? 28 : 16;
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark"><meta name="supported-color-schemes" content="dark"><title>${esc(subject)}</title>
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=JetBrains+Mono:wght@700&display=swap" rel="stylesheet">
<style>${STYLE}.pad{--pb-m:${Math.max(0, 20 - tail)}px}</style></head>
<body class="bg" style="margin:0;padding:0;background:#0a0d12">
<table role="presentation" class="bg" width="100%" cellpadding="0" cellspacing="0" style="background:#0a0d12"><tr><td align="center" style="padding:28px 12px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px">
<tr><td style="padding:0 4px 16px"><a href="${APP}" style="text-decoration:none"><img src="${SITE}/icon-192.png" width="28" height="28" alt="" style="vertical-align:middle;border:0;border-radius:6px"> <span class="t" style="vertical-align:middle;font:700 17px/1 ${SANS};color:#e7ecf2">Prince Solar Hub</span></a></td></tr>
<tr><td class="card pad" style="background:#11161d;border:1px solid rgba(255,255,255,.07);border-radius:12px;padding:32px 32px ${Math.max(0, 32 - tail)}px">
<h1 class="t" style="margin:0 0 ${b.sub ? 4 : 16}px;font:700 22px/1.25 ${SANS};letter-spacing:-.02em;color:#e7ecf2">${esc(b.title)}</h1>
${b.sub ? `<p class="m" style="margin:0 0 20px;font:400 14px/1.4 ${SANS};color:#9aa5b3">${esc(b.sub)}</p>` : ""}
${rows.join("\n")}
</td></tr>
<tr><td style="padding:16px 4px 0">${b.footer.map((f) => `<p class="d" style="margin:0 0 6px;font:400 12px/1.5 ${SANS};color:#7f8da0">${f}</p>`).join("")}</td></tr>
</table></td></tr></table></body></html>`;
}

const strip = (s: string) => s.replace(/<[^>]+>/g, "").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&nbsp;/g, " ");

function text(b: Body): string {
  const out = [b.title, b.sub ?? "", ""];
  for (const x of b.parts) {
    if ("p" in x) out.push(strip(x.p), "");
    else if ("note" in x) out.push(strip(x.note), "");
    else if ("steps" in x) out.push(...x.steps.map((s, i) => `${i + 1}. ${strip(s)}`), "");
    else if ("button" in x) out.push(`${x.button.label}: ${x.button.href}`, "");
    else if ("bars" in x && x.bars.labels) out.push(x.bars.labels.map((l, i) => `${l} ${x.bars.values[i] == null ? "–" : x.bars.values[i]!.toFixed(0)}`).join(", ") + " kWh", "");
    else if ("chart" in x) out.push(x.chart.title, ...(x.chart.bars.labels ? [x.chart.bars.labels.map((l, i) => `${l} ${x.chart.bars.values[i] == null ? "–" : x.chart.bars.values[i]!.toFixed(0)}`).join(", ") + " kWh"] : []),
      ...x.chart.facts.map((f) => `${f.label}: ${strip(f.value)}${f.unit ? " " + f.unit : ""}${f.sub ? `, ${f.sub}` : ""}`), "");
    else if ("callout" in x) out.push(strip(x.callout), "");
    else if ("facts" in x) out.push(...x.facts.map((f) => `${f.label}: ${strip(f.value)}`), "");
    else if ("stats" in x) out.push(...x.stats.map((s) => `${s.label}: ${s.value}${s.unit ? " " + s.unit : ""}${s.delta ? ` (${deltaText(s.delta)})` : s.sub ? ` (${s.sub})` : ""}`), "");
  }
  if (b.footer.length) out.push("--", ...b.footer.map((f) => strip(f.replace(/<a href="(?!mailto:)([^"]+)"[^>]*>([^<]+)<\/a>/g, "$2: $1"))));
  return out.filter((l, i, a) => !(l === "" && a[i - 1] === "")).join("\n");
}

const make = (subject: string, b: Body, unsubscribe?: string): Email => ({ subject, html: html(subject, b), text: text(b), ...(unsubscribe ? { unsubscribe } : {}) });


// ---------------------------------------------------------------- account mail

function account(subject: string, title: string, lead: string, label: string, url: string, ignore: string): Email {
  return make(subject, {
    title,
    parts: [{ p: lead }, { note: LINK_LIFE }, { button: { label, href: url } }],
    footer: [ignore, HELP],
  });
}

export const confirmSignup = (url: string) =>
  account("Confirm your email", "Confirm your email", "This finishes setting up your Prince Solar Hub account.",
    "Confirm email", url, "Didn't sign up? Ignore this email.");

export const resetPassword = (url: string) =>
  account("Reset your password", "Reset your password", "You'll choose a new password on the next screen.",
    "Reset password", url, "Didn't ask for this? Ignore this email. Your password stays the same.");

// Security notices: sent at once, after the change, so there is nothing to confirm.
// Common practice: say what changed, when and from what device, then one action named
// for what it does. Reset password needs the app to open its reset screen from a link
// (?reset=1, not built yet); these are noreply@, so help goes to hello@ by address.
const notYou = [
  { p: "If this wasn't you, reset your password now." },
  { button: { label: "Reset password", href: `${APP}/?reset=1` } },
];

// Supabase sends this one too: its "Password changed" security notice
// (auth.email.notification.password_changed). The template only knows {{ .Email }},
// so there's no time or device to show.
export const passwordChanged = (email: string) =>
  make("Your password was changed", {
    title: "Your password was changed",
    parts: [{ p: `The password for <b>${esc(email)}</b> was just changed.` }, ...notYou],
    footer: [HELP],
  });

export const accountDeleted = (email: string) =>
  make("Your account is deleted", {
    title: "Your account is deleted",
    parts: [{ p: `The Prince Solar Hub account for <b>${esc(email)}</b> is deleted, with its settings and its connection to SunSynk. Plant readings go too, unless someone else shares the plant.` },
      { p: "Your SunSynk account and your inverter are not affected." },
      { note: "You can sign up again any time. Only the last 60 days of history come back from SunSynk." }],
    footer: [HELP],
  });

// Supabase Auth fills these placeholders itself; they must reach it unescaped.
export function renderAuthTemplates(): Record<string, Email> {
  // Only what the app uses: password sign-up and reset. No email sign-in link, and
  // the email address can't be changed yet.
  const URL = "{{ .ConfirmationURL }}";
  return {
    confirmation: confirmSignup(URL),
    recovery: resetPassword(URL),
    password_changed_notification: passwordChanged("{{ .Email }}"),
  };
}

// ------------------------------------------------------------- getting started

// Footer for emails people can switch off: why they got it, and a text link to the
// notification settings.
// Each button opens the page and plant the email is about. app.jsx reads ?tab=; without
// it the app reopens the page last used. ?plant= needs SOLAR-156. Labels name the page.
const PAGES = { live: "Live", solar: "Solar", grid: "Grid", inverters: "Equipment" } as const;
const openPage = (tab: keyof typeof PAGES, plantId: number) => ({ label: `Open ${PAGES[tab]}`, href: `${APP}/?tab=${tab}&plant=${plantId}` });

const SETTINGS_FOOTER = (line: string) => [line.replace("notification settings", `<a href="${PREFS}">notification settings</a>`), HELP];

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
        "Tap the button below and sign in.",
        "Enter the email and password from your <b>SunSynk Connect</b> app.",
        "Your readings start within a minute and update every minute. Your last 60 days follow, and we'll email you when they're in.",
      ] },
      { button: { label: "Connect your inverter", href: APP } },
    ],
    footer: [HELP],
  });


export type History = {
  plant: string;
  plantId: number;
  days: number;
  from: string; // "19 Aug"
  to: string; // "17 Oct"
  daily: (number | null)[]; // solar kWh per day, oldest first; null = SunSynk had nothing
  madeKwh: number;
  homeKwh: number;
  independencePct: number;
  importKwh: number | null; // null: no grid
  bestDay: { label: string; kwh: number };
  highestUse?: { label: string; kwh: number }; // the day the home used the most ("Busiest day")
};

export const historySynced = (h: History) => {
  const [mv, mu] = kwh(h.madeKwh);
  return make(`Your last ${h.days} days at ${h.plant} are in`, {
    title: `Your last ${h.days} days are in`,
    sub: `${h.plant} · ${h.from} to ${h.to}`,
    parts: [
      { p: `That's as far back as SunSynk lets us go. From now on we keep your readings ourselves, so your history keeps growing.` },
      { stats: [
        { label: "Made", value: mv, unit: mu, tone: "solar" },
        { label: "Home", value: kwh(h.homeKwh)[0], unit: kwh(h.homeKwh)[1], tone: "home" },
        ...(h.importKwh != null ? [{ label: "Imported", value: kwh(h.importKwh)[0], unit: kwh(h.importKwh)[1], tone: "grid" as Tone }] : []),
        { label: "Independence", value: `${Math.round(h.independencePct)}%`, tone: "cyan" },
      ] },
      // The same chart panel as the reports, with the first and last date under it.
      { chart: { title: "Solar each day", side: (() => {
          const known = h.daily.filter((d): d is number => d != null);
          return `Average ${kwh(known.reduce((x, y) => x + y, 0) / Math.max(1, known.length)).join(" ")} a day`;
        })(), bars: { values: h.daily, from: h.from, to: h.to },
        facts: [{ label: "Best day", value: kwh(h.bestDay.kwh)[0], unit: kwh(h.bestDay.kwh)[1], tone: "solar", sub: h.bestDay.label },
          ...(h.highestUse ? [{ label: "Busiest day", value: kwh(h.highestUse.kwh)[0], unit: kwh(h.highestUse.kwh)[1], tone: "home" as Tone, sub: h.highestUse.label }] : [])] } },
      { button: openPage("solar", h.plantId) },
    ],
    footer: [HELP],
  });
};

// SunSynk's own service is down: every plant is affected, not one inverter.
export const sunsynkDown = (plant: string, plantId: number, since: string, unsubscribeUrl: string, day = "today") =>
  make("SunSynk is not answering", {
    title: "SunSynk is not answering",
    parts: [
      { stack: true, stats: [{ label: "SunSynk", value: "Down", tone: "home", sub: `since ${since} ${day}` }] },
      { p: `SunSynk's service isn't answering, so no readings from ${esc(plant)} can reach us. We'll email you when it's back.` },
      { button: openPage("live", plantId) },
    ],
    footer: ALERT_FOOTER(plant),
  }, unsubscribeUrl);

export const sunsynkBack = (plant: string, plantId: number, at: string, lasted: string, unsubscribeUrl: string, day = "today") =>
  make("SunSynk is back", {
    title: "SunSynk is back",
    parts: [
      { stack: true, stats: [{ label: "SunSynk", value: "Back", tone: "solar", sub: `since ${at} ${day}, after ${span(lasted)}` }] },
      { p: `Readings from ${esc(plant)} are arriving again.` },
      { button: openPage("live", plantId) },
    ],
    footer: ALERT_FOOTER(plant),
  }, unsubscribeUrl);

// --------------------------------------------------------------------- reports

export type Period = "week" | "month" | "year";

export type Report = {
  plantId: number;
  period: Period;
  label: string; // "October 2026", "6 – 12 Oct 2026", "2026"
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
  highestUse?: { label: string; kwh: number }; // the day the home used the most ("Busiest day")
  daily?: Bars; // solar kWh per day (per month for a year)
  unsubscribeUrl: string;
};

const kwh = (n: number): [string, string] => (n >= 1000 ? [(n / 1000).toFixed(2), "MWh"] : [n.toFixed(n < 100 ? 1 : 0), "kWh"]);
// Colour a change by whether it's good for the owner, not by up or down: less grid
// bought and less home use are good. Only a change that rounds to 0% stays grey.
const trend = (n: number | undefined, prev: string, better: "up" | "down"): { delta?: Delta } => {
  if (n == null || !isFinite(n)) return {};
  if (Math.round(n) === 0) return { delta: { n, prev } };
  return { delta: { n, prev, tone: (n > 0) === (better === "up") ? "good" : "bad" } };
};
const rand = (n: number) => "R" + Math.round(n).toLocaleString("en-ZA").replace(/,/g, " ");
const EVERY: Record<Period, string> = { week: "Weekly", month: "Monthly", year: "Yearly" };

export function report(r: Report): Email {
  const [mv, mu] = kwh(r.madeKwh);
  const stats: Extract<Part, { stats: unknown }>["stats"] = [
    { label: "Made", value: mv, unit: mu, tone: "solar", ...trend(r.change.made, r.prevLabel, "up") },
    { label: "Home", value: kwh(r.homeKwh)[0], unit: kwh(r.homeKwh)[1], tone: "home", ...trend(r.change.home, r.prevLabel, "down") },
    { label: "Imported", value: kwh(r.importKwh)[0], unit: kwh(r.importKwh)[1], tone: "grid", ...trend(r.change.import, r.prevLabel, "down") },
    ...(r.exportKwh != null ? [{ label: "Exported", value: kwh(r.exportKwh)[0], unit: kwh(r.exportKwh)[1], tone: "grid" as Tone }] : []),
    { label: "Independence", value: `${Math.round(r.independencePct)}%`, tone: "cyan", ...trend(r.change.independence, r.prevLabel, "up") },
    ...(r.savedRand != null ? [{ label: "Est. saved", value: rand(r.savedRand), tone: "batt" as Tone, ...trend(r.change.saved, r.prevLabel, "up") }] : []),
  ];
  const parts: Part[] = [{ stats }];
  const facts: Extract<Part, { chart: unknown }>["chart"]["facts"] = [];
  if (r.bestDay) facts.push({ label: "Best day", value: kwh(r.bestDay.kwh)[0], unit: kwh(r.bestDay.kwh)[1], tone: "solar", sub: r.bestDay.label });
  if (r.highestUse) facts.push({ label: "Busiest day", value: kwh(r.highestUse.kwh)[0], unit: kwh(r.highestUse.kwh)[1], tone: "home", sub: r.highestUse.label });
  if (r.daily) {
    const known = r.daily.values.filter((v): v is number => v != null);
    const avg = known.length ? known.reduce((a, b) => a + b, 0) / known.length : 0;
    parts.push({ chart: { title: r.period === "year" ? "Solar each month" : "Solar each day", side: `Average ${kwh(avg).join(" ")} a ${r.period === "year" ? "month" : "day"}`, bars: r.daily, facts } });
  } else if (facts.length) parts.push({ facts: facts.map((f) => ({ label: f.label, value: `${f.sub ? esc(f.sub) + " · " : ""}${f.value}${f.unit ? " " + f.unit : ""}` })) });
  parts.push({ button: openPage("solar", r.plantId) });
  return make(`${EVERY[r.period]} solar report for ${r.plant}: ${r.label}`, {
    title: r.label,
    sub: r.plant,
    parts,
    footer: SETTINGS_FOOTER(`You get this every ${r.period}. Don't want it? Turn it off in your notification settings.`),
  }, r.unsubscribeUrl);
}

// ---------------------------------------------------------------- plant events

// Kinds and wording follow api_alerts_due_raw (0057) and its wrapper (0042):
//  grid_down     3 known minutes with no grid (>100 V); SQL gives no charge, the sender
//                may add the latest batt_soc
//  grid_back     grid present again after >=3 absent minutes; SQL gives no duration
//  grid_seen     a plant marked off-grid shows grid voltage on any phase (no email; dropped 2026-10-24)
//  soc_overnight (no email; dropped 2026-10-24) 18:00-06:00, at the current draw the battery reaches its reserve
//                before 06:00 (a forecast, not a low reading)
//  batt_hot      battery temperature above 40 C (was 35; raised 2026-10-24, the SQL still says 35)
//  bank_drift    charge % differs by 10 points or more between inverters' batteries for an hour,
//                at most once a day (was 5 points for 10 min, hourly; changed 2026-10-24, SQL not yet)
//  string_dead   11:00-14:59, a string dead for 15 min while another string on the
//                same inverter makes over 200 W
//  logger_stale  no new reading for the whole plant for 15 min
// logger_back and needs_relink have no SQL alert yet; the poller sets needs_relink.
export type PlantEvent =
  | { kind: "grid_down"; at: string; chargePct?: number }
  | { kind: "grid_back"; at: string; lasted?: string }
  | { kind: "batt_hot"; at: string; tempC: number; hotDays?: number } // hotDays: days over 40 C in the last 30, today included; counted from readings at send time
  | { kind: "bank_drift"; banks: { name: string; chargePct: number }[] } // name: the inverter's name in SunSynk
  | { kind: "string_dead"; string: string; inverter: string; since: string }
  | { kind: "logger_stale"; since: string }
  | { kind: "logger_back"; at: string; lasted: string }
  | { kind: "needs_relink" };

// day: "today", or the date when the alert reaches the owner on a later day
// ("Tue 21 Oct"), so a time is never read against the wrong day.
//
// Each alert shows its facts as cards, like the reports: coral for what went wrong,
// green for what came back, amber for grid, purple for battery. A sentence stays only
// where the cards can't explain it alone.
type Card = Extract<Part, { stats: unknown }>["stats"][number];
// "1 h 47 min" wraps in a card; "1h 47m" fits.
const PAGE: Record<Exclude<PlantEvent["kind"], "needs_relink">, keyof typeof PAGES> = {
  grid_down: "grid", grid_back: "grid",
  batt_hot: "inverters", bank_drift: "inverters", string_dead: "inverters",
  logger_stale: "live", logger_back: "live",
};
const span = (d: string) => d.replace(/ h /, "h ").replace(/ min$/, "m");
const ALERT_FOOTER = (plant: string) => SETTINGS_FOOTER(`Alert for ${esc(plant)}. Don't want these? Turn them off in your notification settings.`);
export function plantEvent(plant: string, plantId: number, e: PlantEvent, unsubscribeUrl: string, day = "today"): Email {
  const P = esc(plant);
  const at = (time: string) => `${time} ${day}`;
  const [title, cards, note]: [string, Part | Card[], string?] = (() => {
    switch (e.kind) {
      case "grid_down":
        return [`Grid down at ${plant}`, [
          { label: "Grid", value: "Off", tone: "home", sub: `since ${at(e.at)}` },
          ...(e.chargePct != null ? [{ label: "Battery", value: `${e.chargePct}%`, tone: "batt" as Tone, sub: "running the house" }] : []),
        ]];
      case "grid_back":
        return [`Grid back at ${plant}`, [
          { label: "Grid", value: "On", tone: "grid", sub: `since ${at(e.at)}` },
          ...(e.lasted ? [{ label: "Outage", value: span(e.lasted), sub: "without grid" }] : []),
        ]];
      case "batt_hot":
        return [`Battery hot at ${plant}`, [
          { label: "Battery", value: `${e.tempC}\u00a0°C`, tone: "home", sub: `at ${at(e.at)}` },
        ], "Batteries wear faster when they run hot." + ((e.hotDays ?? 1) > 1
          ? ` Yours has gone above 40&nbsp;°C on ${e.hotDays} days in the last 30. If it keeps happening, have your battery checked.` : "")];
      case "bank_drift": {
        const pcts = e.banks.map((b) => b.chargePct);
        return [`Batteries charging unevenly at ${plant}`, [
          ...e.banks.map((b) => ({ label: b.name, value: `${b.chargePct}%`, tone: "batt" as Tone, sub: "battery charge" })),
        ], `Batteries that work together usually stay within a few percent of each other. These have been ${Math.max(...pcts) - Math.min(...pcts)}% apart for over an hour. If the gap keeps growing over the next few days, have them checked.`];
      }
      case "string_dead":
        return [`Some panels stopped producing at ${plant}`, [
          { label: `${e.string} · ${e.inverter.replace(/^Inverter /, "")}`, value: "No power", tone: "home", sub: `since ${at(e.since)}` },
          { label: "Other panels", value: "OK", tone: "solar", sub: "producing as normal" },
        ], `One group of panels on ${esc(e.inverter)} has stopped making power. The rest are still working.`];
      case "logger_stale":
        return [`No readings from ${plant}`, [
          { label: "Last reading", value: e.since, tone: "home", sub: esc(day) },
        ], "Your inverters haven't sent a reading to SunSynk for 15 minutes. We'll email you when readings are back."];
      case "logger_back":
        return [`Readings back at ${plant}`, [
          { label: "Readings", value: "Back", tone: "solar", sub: `since ${at(e.at)}, after ${span(e.lasted)}` },
        ], "Your inverters are sending readings again."];
      case "needs_relink":
        return ["Reconnect your SunSynk login", { callout: "Prince Solar Hub is no longer connected to your SunSynk account, so new readings aren't arriving." },
          "This usually happens after your SunSynk password changes. Enter your SunSynk password in Account to reconnect."];
    }
  })();
  const relink = e.kind === "needs_relink";
  return make(title, {
    title,
    parts: [Array.isArray(cards) ? { stats: cards, stack: true } : cards, ...(note ? [{ p: note }] : []), { button: relink ? { label: "Reconnect", href: LOGINS } : openPage(PAGE[e.kind as Exclude<PlantEvent["kind"], "needs_relink">], plantId) }],
    footer: ALERT_FOOTER(plant),
  }, unsubscribeUrl);
}
