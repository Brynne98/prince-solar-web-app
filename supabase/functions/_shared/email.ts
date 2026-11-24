// Every email Prince Solar Hub sends, as { subject, html, text }.
//
// Plain TypeScript with no Deno or Node APIs, so an Edge Function can import it and
// scripts/email-preview.ts can run it under Node to preview and send test mail.
//
// Senders (SOLAR-287): one address per kind of mail, so Gmail judges each kind on its own
// history; see senderFor(). Replies go to hello@, the support inbox (SOLAR-114). No mail
// carries a List-Unsubscribe header: alerts and reports are switched off in the app, and the
// header made them look like a mailing list to Gmail.
//
// Account mail is sent by Supabase Auth, not by us: renderAuthTemplates() fills the
// links with Supabase's Go placeholders ({{ .TokenHash }}) and the output is
// pasted into Dashboard -> Authentication -> Emails.
//
// Look: DESIGN.md. Dark only, like the app (decided 2026-10-18, SOLAR-117); colour
// goes on the value, never the card.

export const SITE = "https://princesolarhub.co.za";
// Buttons open the web app; SITE is the showcase and only hosts the logo.
export const APP = "https://app.princesolarhub.co.za";
// Email choices are per person, so they belong on Account (logins, delete) rather
// than Settings (plant, tariff, battery). Relink is on Account too.
// The footer's "notification settings" link opens Account's Notifications section (SOLAR-158).
const PREFS = `${APP}/?tab=account&section=notifications`;
// Reconnect lands on Account's SunSynk logins section and flashes it, like the app's own
// Reconnect (openSettings('connection')). ?section= needs SOLAR-156.
const LOGINS = `${APP}/?tab=account&section=logins`;
const ADD_PLANT = `${APP}/?add=plant`;
export const FROM_ACCOUNT = "Prince Solar Hub <noreply@princesolarhub.co.za>";
export const FROM_ALERTS = "Prince Solar Hub <alerts@princesolarhub.co.za>";
export const FROM_BILLING = "Prince Solar Hub <billing@princesolarhub.co.za>";
export const FROM_REPORTS = "Prince Solar Hub <reports@princesolarhub.co.za>";
export const FROM_HELLO = "Prince Solar Hub <hello@princesolarhub.co.za>";
export const REPLY_TO = "hello@princesolarhub.co.za";
// The sender for a mail_queue kind. Account mail Supabase Auth sends itself uses noreply@ too.
export const senderFor = (kind: string) =>
  kind === "account_deleted" ? FROM_ACCOUNT
    : kind.startsWith("report_") ? FROM_REPORTS
    : kind === "welcome" || kind === "history" || kind === "need_a_hand" ? FROM_HELLO
    : FROM_ALERTS;
// Supabase's link lifetime (Auth -> mailer OTP expiry): 24 hours since SOLAR-196.
const LINK_LIFE = "The link works once, for 24 hours.";

// An email address in body text. Gmail links any address it finds and paints it blue,
// so give it a link of our own in the text colour.
const addr = (email: string) => `<a href="mailto:${email}" style="color:#e7ecf2;text-decoration:none;font-weight:700">${email}</a>`;
// The one help line every email ends with.
const HELP = `Need help? Email <a href="mailto:hello@princesolarhub.co.za">hello@princesolarhub.co.za</a>.`;

export type Email = { subject: string; html: string; text: string };
import { type AlertMail, alertMail, type LoginEvent, type Mail as TextMail, pageNames, type PlantEvent } from "./text.ts";

// Same roles as the app's :root (public/index.html, SOLAR-346). The five power colours
// mean only solar, home, grid, charge and battery; status words take ok, warn or bad;
// the main button takes accent. Money has no colour: it stays plain text.
const C = {
  solar: "#3ddc84",
  home: "#f87171",
  grid: "#facc15",
  cyan: "#22d3ee",
  batt: "#a78bfa",
  ok: "#84cc16",
  warn: "#f59e0b",
  bad: "#ef4444",
} as const;
const ACCENT = "#3ddc84";
type Tone = keyof typeof C;

const esc = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

const SANS = "'Space Grotesk',-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";
const MONO = "'JetBrains Mono',ui-monospace,Menlo,Consolas,monospace";

// .chg: a report card's change line wraps to two lines between 341 and 420 px; every card
// keeps two there, so a row stays even (SOLAR-452)
const STYLE = `
:root{color-scheme:dark;supported-color-schemes:dark}
body{margin:0;padding:0}
a{color:inherit}
@media (max-width:520px){.pad{padding:20px 20px var(--pb-m,8px)!important}}
@media (max-width:340px){.card{width:auto!important;display:block!important;margin-right:0!important}}
@media (min-width:341px) and (max-width:420px){.chg{min-height:34px}}
`;

// The one box every email shows its facts in (SOLAR-415): an optional big number, then
// label-value rows split by space, no lines. Values may hold markup set by us (a coloured
// battery %), never user text unescaped. tone colours the big number only.
type Hero = { label: string; value: string; tone?: Tone; sub?: string };
// checks: a checklist (setup) or numbered steps (adding a plant). A done line is ticked
// and struck through, name only; an open line has an empty circle, or its step number n,
// then the name, a line under it, and a dimmer line under that.
type Check = { name: string; done?: boolean; n?: number; text?: string; sub?: string };
// steps: what happens when, by date: the date in bold, a sentence under it (a cancel, SOLAR-488).
type Box = { hero?: Hero; rows?: [label: string, value: string][]; checks?: Check[]; steps?: [when: string, what: string][] };

type Part =
  | { lead: string } // grey sentence under the title: what happened, only when the box can't say it
  | { pair: [head: string, text: string] } // one fact: a white line, its sentence under it in the body grey (SOLAR-559); text is HTML, as lead
  | { box: Box }
  | { small: string } // small print under the button ("The link works once, for 24 hours.")
  | { button: { label: string; href: string } }
  | { stats: { label: string; value: string; unit?: string; tone?: Tone; sub?: string; delta?: Delta }[] } // report tiles, two to a row
  | { chart: { title: string; side?: string; bars: Bars; facts: { label: string; value: string; unit?: string; tone?: Tone; sub?: string }[] } }
  | { facts: { label: string; value: string }[] } // label left, value right
  | { note: string }
  | { heading: string }; // small capitals over a section further down (the day-7 report under its notice)

// labels: one under each bar (a week); titles: the hover text per bar, where the mail app
// shows it (desktop only). The highest bar is drawn full green, the rest dimmer.
// A change on the previous period: the arrow and percent take the tone, the rest stays grey.
// abs: the change in the tile's own unit ("3.8 kWh"), shown instead of the percent when it
// is 200% or more, a jump off a small base (the app's rule, TrendBadge; SOLAR-615).
type Delta = { n: number; prev: string; tone?: "good" | "bad"; abs?: string };
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
  // The best value, with its unit, is wider than a bar, so its cell spans R bars on each
  // side and centres over its own bar. R is enough bars to hold the ~70px label on a
  // ~290px phone chart. Near either end there aren't R bars to that side, so the label
  // lines up with the first or last bar instead: it never runs past either end. That
  // cell still spans 2R+1 bars, since text too wide for its cell spills right even when
  // set to the right.
  const n = v.length, R = Math.max(1, Math.ceil((Math.ceil((70 * n) / 290) - 1) / 2));
  const [a0, a1, align] = best < R ? [0, Math.min(n - 1, 2 * R), "left"]
    : best > n - 1 - R ? [Math.max(0, n - 1 - 2 * R), n - 1, "right"]
    : [best - R, best + R, "center"];
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
  const tone = d.tone === "good" ? C.ok : d.tone === "bad" ? C.bad : "#9aa5b3";
  return `<span style="color:${tone};font-weight:600">${r > 0 ? "↑" : r < 0 ? "↓" : "→"} ${esc(d.abs ?? Math.abs(r) + "%")}</span> vs ${esc(d.prev)}`;
};
const deltaText = (d: Delta) => { const r = Math.round(d.n); return `${r > 0 ? "↑" : r < 0 ? "↓" : "→"} ${d.abs ?? Math.abs(r) + "%"} vs ${d.prev}`; };

function html(subject: string, b: Body): string {
  const rows = b.parts.map((x) => {
    if ("lead" in x) return `<p class="m" style="margin:0 0 16px;font:400 15px/1.55 ${SANS};color:#9aa5b3">${x.lead}</p>`;
    if ("pair" in x) return `<p class="m" style="margin:0 0 16px;font:400 15px/1.55 ${SANS};color:#9aa5b3"><span class="t" style="display:block;margin:0 0 3px;font-weight:600;color:#e7ecf2">${esc(x.pair[0])}</span>${x.pair[1]}</p>`;
    if ("small" in x) return `<p class="d" style="margin:0;font:400 13px/1.5 ${SANS};color:#7f8da0">${x.small}</p>`;
    if ("box" in x) {
      const { hero, rows: r = [], checks = [], steps = [] } = x.box;
      const big = hero ? `<tr><td colspan="2" style="padding:0 0 ${r.length ? 12 : 0}px">` +
        `<div class="m" style="font:500 11px/1 ${SANS};letter-spacing:.12em;text-transform:uppercase;color:#9aa5b3">${esc(hero.label)}</div>` +
        `<div class="${hero.tone ?? "t"}" style="margin-top:8px;font:700 40px/1 ${MONO};font-variant-numeric:tabular-nums;color:${hero.tone ? C[hero.tone] : "#e7ecf2"}">${esc(hero.value)}</div>` +
        (hero.sub ? `<div class="d" style="margin-top:6px;font:400 13px/1.4 ${SANS};color:#7f8da0">${esc(hero.sub)}</div>` : "") + `</td></tr>` : "";
      const lines = r.map(([l, v]) => `<tr><td class="m" style="padding:6px 12px 6px 0;font:400 14px/1.3 ${SANS};color:#9aa5b3;vertical-align:top;white-space:nowrap">${esc(l)}</td>` +
        `<td class="t" align="right" style="padding:6px 0;font:700 14px/1.3 ${MONO};font-variant-numeric:tabular-nums;color:#e7ecf2;vertical-align:top">${v}</td></tr>`).join("");
      const tick = (c: Check) => c.n
        ? `<div style="width:22px;height:22px;border-radius:50%;background:#1f3a2b;color:#3ddc84;font:700 12px/22px ${SANS};text-align:center">${c.n}</div>`
        : c.done
        ? `<div style="width:20px;height:20px;border-radius:50%;background:#3ddc84;font-size:0;line-height:0"><img src="${SITE}/email/tick.png" width="20" height="20" alt="" style="display:block;border:0"></div>`
        : `<div style="width:16px;height:16px;border-radius:50%;border:2px solid #4a5666"></div>`;
      const list = checks.map((c) => {
        const pad = c.done ? 10 : 16;
        return `<tr><td style="vertical-align:top;width:34px;padding:${pad}px 0"><div style="margin-top:1px">${tick(c)}</div></td><td style="vertical-align:top;padding:${pad}px 0">` +
          (c.done
            ? `<div class="d" style="font:700 16px/1.3 ${SANS};color:#7f8da0;text-decoration:line-through">${esc(c.name)}</div>`
            : `<div class="t" style="font:700 16px/1.3 ${SANS};color:#e7ecf2">${esc(c.name)}</div>` +
              (c.text ? `<div class="m" style="margin-top:4px;font:400 14px/1.5 ${SANS};color:#c3ccd6">${esc(c.text)}</div>` : "") +
              (c.sub ? `<div class="d" style="margin-top:6px;font:400 13px/1.5 ${SANS};color:#7f8da0">${esc(c.sub)}</div>` : "")) +
          `</td></tr>`;
      }).join("");
      const when = steps.map(([w, t], i) => `<tr><td style="padding:${i ? 14 : 0}px 0 0"><div class="t" style="font:700 15px/1.3 ${SANS};color:#e7ecf2">${esc(w)}</div>` +
        `<div class="m" style="margin-top:3px;font:400 14px/1.5 ${SANS};color:#c3ccd6">${esc(t)}</div></td></tr>`).join("");
      return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 20px"><tr><td style="padding:${steps.length ? "16px 18px" : checks.length ? "4px 18px" : `${hero ? 18 : 12}px 18px ${r.length ? 12 : 18}px`};background:#141a22;border-radius:10px">` +
        `<table role="presentation" width="100%" cellpadding="0" cellspacing="0">${big}${lines}${list}${when}</table></td></tr></table>`;
    }
    if ("note" in x) return `<p class="m" style="margin:0 0 16px;font:400 14px/1.55 ${SANS};color:#9aa5b3">${x.note}</p>`;
    if ("heading" in x) return `<div class="m" style="margin:28px 0 8px;font:500 11px/1 ${SANS};letter-spacing:.12em;text-transform:uppercase;color:#9aa5b3">${esc(x.heading)}</div>`;
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
    if ("facts" in x)
      return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 16px">${x.facts.map((f) =>
        `<tr><td style="padding:6px 0;font:400 14px/1.3 ${SANS};color:#9aa5b3">${esc(f.label)}</td>` +
        `<td align="right" style="padding:6px 0;font:700 14px/1.3 ${MONO};font-variant-numeric:tabular-nums;color:#e7ecf2">${f.value}</td></tr>`).join("")}</table>`;
    if ("button" in x)
      return `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:4px 0 12px"><tr><td style="border-radius:8px;background:${ACCENT}"><a href="${x.button.href}" style="display:inline-block;padding:13px 24px;font:600 15px/1 ${SANS};color:#0a0d12;text-decoration:none;border-radius:8px">${esc(x.button.label)}</a></td></tr></table>`;
    // When one card has a change line, every card keeps its space, so a card with nothing
    // to compare (Imported with the grid off) stays as tall as the card beside it
    // (SOLAR-452). When none has, the line goes (SOLAR-559).
    const chg = x.stats.some((s) => s.delta || s.sub);
    const cells = x.stats.map((s) => `<td class="tile" width="50%" style="padding:16px;background:#141a22;border-radius:8px;vertical-align:top">
<div class="m" style="font:500 11px/1 ${SANS};letter-spacing:.12em;text-transform:uppercase;color:#9aa5b3">${esc(s.label)}</div>
<div class="${s.tone ?? "t"}" style="margin-top:8px;font:700 24px/1.1 ${MONO};font-variant-numeric:tabular-nums;color:${s.tone ? C[s.tone] : "#e7ecf2"}">${esc(s.value)}${s.unit ? `<span style="font-size:14px;opacity:.85"> ${esc(s.unit)}</span>` : ""}</div>
${chg ? `<div class="d chg" style="margin-top:6px;font:400 12px/1.4 ${SANS};color:#7f8da0">${s.delta ? deltaHtml(s.delta) : s.sub ? esc(s.sub) : "&nbsp;"}</div>` : ""}</td>`);
    // Every card takes half the width, a lone one included. Below 340 px (the smallest
    // phones) every card goes full width.
    const boxes = cells.map((c, i) => c.replace(/^<td class="tile" width="50%" style="/,
      `<div class="card" style="display:inline-block;width:49%;box-sizing:border-box;margin:0 ${i % 2 ? 0 : "2%"} 8px 0;font-size:14px;`).replace(/<\/td>$/, "</div>"));
    return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:4px 0 4px"><tr><td style="font-size:0;line-height:0">${boxes.join("")}</td></tr></table>`;
  });

  // Every part ends in its own bottom margin; take it off the card's bottom padding so
  // the space under the last part matches the sides.
  const last = b.parts[b.parts.length - 1];
  const tail = !last ? 0 : "button" in last ? 20 : "stats" in last ? 12 : "small" in last ? 8 : "box" in last ? 20 : 16;
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark"><meta name="supported-color-schemes" content="dark"><title>${esc(subject)}</title>
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=JetBrains+Mono:wght@700&display=swap" rel="stylesheet">
<style>${STYLE}.pad{--pb-m:${Math.max(0, 20 - tail)}px}</style></head>
<body style="margin:0;padding:0">
<!-- The dark fills the whole mail window, with the lighter card in the middle (SOLAR-287). -->
<table role="presentation" class="bg" width="100%" cellpadding="0" cellspacing="0" style="background:#0a0d12"><tr><td align="center" style="padding:40px 8px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px">
<tr><td style="padding:24px 16px 16px 20px"><a href="${APP}" style="text-decoration:none"><img src="${SITE}/icon-192.png" width="28" height="28" alt="" style="vertical-align:middle;border:0;border-radius:6px"> <span class="t" style="vertical-align:middle;font:700 17px/1 ${SANS};color:#e7ecf2">Prince Solar Hub</span></a></td></tr>
<tr><td style="padding:0 12px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td class="card pad" style="background:#11161d;border:1px solid rgba(255,255,255,.07);border-radius:12px;padding:32px 32px ${Math.max(0, 32 - tail)}px">
<h1 class="t" style="margin:0 0 ${b.sub ? 4 : 16}px;font:700 20px/1.3 ${SANS};letter-spacing:-.02em;color:#e7ecf2">${esc(b.title).replace(/ (\S+)$/, "&nbsp;$1")}</h1>
${b.sub ? `<p class="m" style="margin:0 0 20px;font:400 14px/1.4 ${SANS};color:#9aa5b3">${esc(b.sub)}</p>` : ""}
${rows.join("\n")}
</td></tr></table></td></tr>
<tr><td style="padding:16px 20px 20px">${b.footer.map((f) => `<p class="d" style="margin:0 0 6px;font:400 12px/1.5 ${SANS};color:#7f8da0">${f.replace(/<a href=/g, '<a style="color:#7f8da0;text-decoration:underline" href=')}</p>`).join("")}</td></tr>
</table></td></tr></table></body></html>`;
}

const strip = (s: string) => s.replace(/<[^>]+>/g, "").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&nbsp;/g, " ");

function text(b: Body): string {
  const out = [b.title, b.sub ?? "", ""];
  for (const x of b.parts) {
    if ("lead" in x) out.push(strip(x.lead), "");
    else if ("pair" in x) out.push(x.pair[0], strip(x.pair[1]), "");
    else if ("small" in x) out.push(strip(x.small), "");
    else if ("box" in x) out.push(...(x.box.hero ? [`${x.box.hero.label}: ${x.box.hero.value}${x.box.hero.sub ? ` (${x.box.hero.sub})` : ""}`] : []),
      ...(x.box.rows ?? []).map(([l, v]) => `${l}: ${strip(v)}`), ...(x.box.checks ?? []).map((c) => c.done ? `[x] ${c.name}` : `${c.n ? `${c.n}.` : "[ ]"} ${[c.name, [c.text, c.sub].filter(Boolean).join(" ")].filter(Boolean).join(": ")}`),
      ...(x.box.steps ?? []).map(([w, t]) => `${w}: ${t}`), "");
    else if ("note" in x) out.push(strip(x.note), "");
    else if ("heading" in x) out.push("", x.heading.toUpperCase());
    else if ("button" in x) out.push(`${x.button.label}: ${x.button.href}`, "");
    else if ("chart" in x) out.push(x.chart.title, ...(x.chart.bars.labels ? [x.chart.bars.labels.map((l, i) => `${l} ${x.chart.bars.values[i] == null ? "–" : x.chart.bars.values[i]!.toFixed(0)}`).join(", ") + " kWh"] : []),
      ...x.chart.facts.map((f) => `${f.label}: ${strip(f.value)}${f.unit ? " " + f.unit : ""}${f.sub ? `, ${f.sub}` : ""}`), "");
    else if ("facts" in x) out.push(...x.facts.map((f) => `${f.label}: ${strip(f.value)}`), "");
    else if ("stats" in x) out.push(...x.stats.map((s) => `${s.label}: ${s.value}${s.unit ? " " + s.unit : ""}${s.delta ? ` (${deltaText(s.delta)})` : s.sub ? ` (${s.sub})` : ""}`), "");
  }
  if (b.footer.length) out.push("--", ...b.footer.map((f) => strip(f.replace(/<a href="(?!mailto:)([^"]+)"[^>]*>([^<]+)<\/a>/g, "$2: $1"))));
  return out.filter((l, i, a) => !(l === "" && a[i - 1] === "")).join("\n");
}

// A phone line never splits a date ("7 Jan", "Jan 2027") or a card ("•••• 4081").
const MON = "Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec";
const keep = (h: string) => h
  .replace(new RegExp(`(\\d{1,2}) (${MON})\\b`, "g"), "$1&nbsp;$2")
  .replace(new RegExp(`\\b(${MON}) (\\d{4})`, "g"), "$1&nbsp;$2")
  .replace(/•••• (\d{4})/g, "••••&nbsp;$1")
  // Mail apps turn a long number (an inverter serial) into a blue phone link; a
  // zero-width space inside it stops that and shows nothing.
  .replace(/>([^<]*)</g, (_m, t: string) => `>${t.replace(/\b(\d{4})(\d{5,})\b/g, "$1&#8203;$2")}<`);
const make = (subject: string, b: Body): Email => ({ subject, html: keep(html(subject, b)), text: text(b) });


// ---------------------------------------------------------------- billing outbox (SOLAR-641)

// SOLAR-208. Billing runs on our side (Paystack charge_authorization), so receipts and
// plan changes come from us; Paystack's own receipts are off. Prices are final: the
// company isn't VAT-registered, so no VAT line.
const PLAN = `${APP}/?tab=account&section=plan`;
// "Pay with another card": the Plan section opens Paystack's card page for the failed payment.
const PAY_URL = `${PLAN}&pay=1`;
// Buttons that ask them to pick a plan open Adjust plan (SOLAR-341).
const PLANS = `${APP}/?tab=plans`;
// Billing's Payment section: the saved card and its Update button (SOLAR-473).
const PAYMENT = `${APP}/?tab=account&section=payments`;
// Billing's Cancellation section (SOLAR-361).
const CANCEL = `${APP}/?tab=account&section=cancel`;
// Who is selling: on every billing email (SOLAR-415).
const SELLER = "Prince Solar Hub is run by Theron and Prince Solutions (Pty) Ltd, reg. no. 2026/182827/07, Kempton Park, Gauteng. No VAT is charged.";
const BILL_FOOTER = [HELP, SELLER];
// A psh_ reference is 36 characters with no break: it wraps anywhere, or it pushes the
// box past a phone's width (SOLAR-484).
const ref = (r: string) => `<span style="word-break:break-all">${esc(r)}</span>`;
// Every email that offers a plan says why it came and links the page that turns the
// 'reminders' switch off ("Offers and reminders" in the app, SOLAR-569; POPIA s69(4)).
const OFFER_FOOTER = (why: string, unsub: string) => [`You get this because ${why}. <a href="${unsub}">Unsubscribe</a>.`, HELP];

/** An email from the text catalog (_shared/text.ts mail()): its words and numbers come from
 *  the account's state read at send time; this only lays them out. unsub: the reminders
 *  switch's page, for the kinds behind it. */
export function outboxMail(m: TextMail, unsub?: string): Email {
  const page = { billing: PLAN, plans: PLANS, pay: PAY_URL, card: PAYMENT, cancel: CANCEL } as const;
  const parts: Part[] = m.parts.map((x): Part => {
    if ("lead" in x) return { lead: esc(x.lead) };
    if ("pair" in x) return { pair: [x.pair[0], esc(x.pair[1])] };
    if ("note" in x) return { note: esc(x.note) };
    if ("steps" in x) return { box: { steps: x.steps } };
    // a pay button names its bill (?pay=<bill id>), so the app pays that bill or says why not
    if ("button" in x) return { button: { label: x.button.label,
      href: x.button.page === "pay" && x.button.bill ? `${PLAN}&pay=${encodeURIComponent(x.button.bill)}` : page[x.button.page] } };
    return { box: { hero: x.hero,
      rows: x.rows.map(([k, v]) => [k, k === "Reference" ? ref(v) : esc(v)] as [string, string]) } };
  });
  const footer = m.reminder && unsub ? OFFER_FOOTER("you have an account with us", unsub) : BILL_FOOTER;
  return make(m.subject, { title: m.title, sub: m.sub, parts, footer });
}

// ---------------------------------------------------------------- account mail

function account(title: string, lead: string, label: string, url: string, ignore: string): Email {
  return make(title, {
    title,
    parts: [{ lead }, { button: { label, href: url } }, { small: LINK_LIFE }],
    footer: [ignore, HELP],
  });
}

export const confirmSignup = (url: string, email: string) =>
  account("Confirm your email", `Tap the button to finish signing up as ${addr(esc(email))}.`,
    "Confirm email", url, "Didn't sign up? Ignore this email.");

export const resetPassword = (url: string, email: string) =>
  account("Reset your password", `Tap the button to choose a new password for ${addr(esc(email))}.`,
    "Reset password", url, "Didn't ask for this? Ignore this email. Your password stays the same.");

// Security notices: sent at once, after the change, so there is nothing to confirm.
// Common practice: say what changed, when and from what device, then one action named
// for what it does. Reset password needs the app to open its reset screen from a link
// (?reset=1, not built yet); these are noreply@, so help goes to hello@ by address.
const RESET = { button: { label: "Reset password", href: `${APP}/?reset=1` } };

// Supabase sends this one too: its "Password changed" security notice
// (auth.email.notification.password_changed). The template only knows {{ .Email }},
// so there's no time or device to show.
export const passwordChanged = (email: string) =>
  make("Your password was changed", {
    title: "Your password was changed",
    parts: [{ box: { rows: [["Account", esc(email)]] } }, { note: "Wasn't you? Reset your password." }, RESET],
    footer: [HELP],
  });

export const accountDeleted = (email: string) =>
  make("Your account is deleted", {
    title: "Your account is deleted",
    parts: [{ lead: `The settings and readings for ${addr(esc(email))} are gone. Your inverter and its login aren't affected.` },
      { note: "You can sign up again any time." }],
    footer: [HELP],
  });

// Supabase Auth fills these placeholders itself; they must reach it unescaped.
export function renderAuthTemplates(): Record<string, Email> {
  // Only what the app uses: password sign-up and reset. No email sign-in link, and
  // the email address can't be changed yet.
  // The link opens the app, which spends the token only when the person taps a button
  // (auth.jsx, SOLAR-586): mail scanners that open every link no longer use it up.
  const link = (type: string) => `{{ .RedirectTo }}#verify={{ .TokenHash }}&type=${type}`;
  return {
    confirmation: confirmSignup(link("signup"), "{{ .Email }}"),
    recovery: resetPassword(link("recovery"), "{{ .Email }}"),
    password_changed_notification: passwordChanged("{{ .Email }}"),
  };
}

// ------------------------------------------------------------- getting started

// Footer for emails people can switch off: why they got it, and a text link to the
// notification settings.
// Each button opens the page and plant the email is about. app.jsx reads ?tab=; without
// it the app reopens the page last used. ?plant= needs SOLAR-156. Labels name the page.
const PAGES = pageNames;
const openPage = (tab: keyof typeof PAGES, plantId: number) => ({ label: `Open ${PAGES[tab]}`, href: `${APP}/?tab=${tab}&plant=${plantId}` });

const SETTINGS_FOOTER = (line: string) => [line.replace("notification settings", `<a href="${PREFS}">notification settings</a>`), HELP];

// Sent once the email is confirmed, before any plant is added. ?add=plant opens the
// Add plant form, kept through sign-in (link.jsx, SOLAR-473).
// Wording matches link.jsx ("Add your plant", Share plant or SunSynk login, SOLAR-455).
const ADD_STEPS = {
  box: { checks: [
    { n: 1, name: "Tap Add your plant" },
    { n: 2, name: "Share it or sign in", text: "Share your plant with admin@princesolarhub.co.za in the SunSynk app, no password needed. Or use your SunSynk login." },
    { n: 3, name: "Watch it fill in", text: "Readings start within a minute. Your last 60 days follow." },
  ] },
};
export const welcome = () =>
  make("Welcome to Prince Solar Hub", {
    title: "Welcome to Prince Solar Hub",
    parts: [{ lead: "Three steps, about a minute." }, ADD_STEPS, { button: { label: "Add your plant", href: ADD_PLANT } }],
    footer: [HELP],
  });

// 24 hours after sign-up, only if no SunSynk login was ever added (SOLAR-319). The
// welcome email's steps again; from hello@, so a reply reaches us.
// choose (SOLAR-567, 0210): a login is added but its plants all wait to be chosen,
// and no week has started. Laid out as the free week's emails: facts as pairs, one
// button. Every page then shows the locked card with Choose plants.
export const needAHand = (choose = false) => choose
  ? make("Your free week hasn't started", {
    title: "Your free week hasn't started",
    parts: [
      { pair: ["Your plants are locked", "Your SunSynk login is added, but we read none of its plants yet."] },
      { pair: ["Choose up to 5", "Your free week starts then: 7 days, no card."] },
      { button: { label: "Choose plants", href: `${APP}/?tab=live` } },
    ],
    footer: [HELP],
  })
  : make("Need a hand adding your plant?", {
    title: "Need a hand adding your plant?",
    parts: [{ lead: "Your plant isn't added yet. It takes about a minute." }, ADD_STEPS,
      { button: { label: "Add your plant", href: ADD_PLANT } }],
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
  const days = h.days === 1 ? "day" : `${h.days} days`;
  return make(`Your last ${days} at ${h.plant} are in`, {
    title: `Your last ${days} at ${h.plant} are in`,
    sub: `${h.from} to ${h.to}`,
    parts: [
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
      { button: openPage("live", h.plantId) },
    ],
    footer: [HELP],
  });
};

// SunSynk's own service is down (words: text.ts alertMail).
export const sunsynkDown = (plant: string, plantId: number, since: string, day = "today") =>
  alertEmail(alertMail({ kind: "sunsynk_down", since }, plant, day), plantId);
export const sunsynkBack = (plant: string, plantId: number, since: string, at: string, lasted: string, day = "today") =>
  alertEmail(alertMail({ kind: "sunsynk_back", since, at, lasted }, plant, day), plantId);

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
  importKwh: number | null; // null: no grid, so the tile is left out
  exportKwh: number | null; // null: the plant doesn't export, so the tile is left out
  independencePct: number;
  savedRand: number | null; // null: no tariff set
  change: { made?: number; home?: number; import?: number; independence?: number; saved?: number }; // % vs prevLabel
  was?: { made: number; home: number; import: number; independence: number; saved?: number }; // the figures in prevLabel
  bestDay?: { label: string; kwh: number };
  highestUse?: { label: string; kwh: number }; // the day the home used the most ("Busiest day")
  daily?: Bars; // solar kWh per day (per month for a year)
  partialFrom?: string; // first day counted, when after the period starts: "20 Oct" (SOLAR-273)
  partialWhy?: "added" | "history"; // the plant was added then (SOLAR-305), or its history starts then
};

const kwh = (n: number): [string, string] => (n >= 1000 ? [(n / 1000).toFixed(2), "MWh"] : [n.toFixed(n < 100 ? 1 : 0), "kWh"]);
// Colour a change by whether it's good for the owner, not by up or down: less grid
// bought and less home use are good. Only a change that rounds to 0% stays grey.
// With the two figures (cur, was) and the tile's format: none when they read the same
// (Independence 100% both weeks), and the change itself at 200% or more (SOLAR-615).
const trend = (n: number | undefined, prev: string, better: "up" | "down",
               cur?: number, was?: number, fmt?: (v: number) => string): { delta?: Delta } => {
  if (n == null || !isFinite(n)) return {};
  const both = cur != null && was != null && fmt;
  if (both && fmt(cur) === fmt(was)) return {};
  const abs = both && Math.abs(n) >= 200 ? fmt(Math.abs(cur - was)) : undefined;
  if (Math.round(n) === 0) return { delta: { n, prev } };
  return { delta: { n, prev, tone: (n > 0) === (better === "up") ? "good" : "bad", ...(abs ? { abs } : {}) } };
};
const kwhText = (n: number) => kwh(n).join(" ");
const pctText = (n: number) => `${Math.round(n)}%`;
const rand = (n: number) => "R" + Math.round(n).toLocaleString("en-US");
const EVERY: Record<Period, string> = { week: "Weekly", month: "Monthly", year: "Yearly" };

export function report(r: Report): Email {
  const [mv, mu] = kwh(r.madeKwh);
  const stats: Extract<Part, { stats: unknown }>["stats"] = [
    { label: "Made", value: mv, unit: mu, tone: "solar", ...trend(r.change.made, r.prevLabel, "up", r.madeKwh, r.was?.made, kwhText) },
    { label: "Home", value: kwh(r.homeKwh)[0], unit: kwh(r.homeKwh)[1], tone: "home", ...trend(r.change.home, r.prevLabel, "down", r.homeKwh, r.was?.home, kwhText) },
    ...(r.importKwh != null ? [{ label: "Imported", value: kwh(r.importKwh)[0], unit: kwh(r.importKwh)[1], tone: "grid" as Tone, ...trend(r.change.import, r.prevLabel, "down", r.importKwh, r.was?.import, kwhText) }] : []),
    ...(r.exportKwh != null ? [{ label: "Exported", value: kwh(r.exportKwh)[0], unit: kwh(r.exportKwh)[1], tone: "grid" as Tone }] : []),
    { label: "Independence", value: `${Math.round(r.independencePct)}%`, tone: "cyan", ...trend(r.change.independence, r.prevLabel, "up", r.independencePct, r.was?.independence, pctText) },
    ...(r.savedRand != null ? [{ label: "Est. saved", value: rand(r.savedRand), ...trend(r.change.saved, r.prevLabel, "up", r.savedRand, r.was?.saved, rand) }] : []),
  ];
  const parts: Part[] = [];
  if (r.partialFrom) parts.push({ note: `From ${r.partialFrom}, when ${r.partialWhy === "added" ? "you added this plant" : "your history starts"}.` +
    "" });
  parts.push({ stats });
  const facts: Extract<Part, { chart: unknown }>["chart"]["facts"] = [];
  if (r.bestDay) facts.push({ label: "Best day", value: kwh(r.bestDay.kwh)[0], unit: kwh(r.bestDay.kwh)[1], tone: "solar", sub: r.bestDay.label });
  if (r.highestUse) facts.push({ label: "Busiest day", value: kwh(r.highestUse.kwh)[0], unit: kwh(r.highestUse.kwh)[1], tone: "home", sub: r.highestUse.label });
  if (r.daily) {
    const known = r.daily.values.filter((v): v is number => v != null);
    const avg = known.length ? known.reduce((a, b) => a + b, 0) / known.length : 0;
    parts.push({ chart: { title: r.period === "year" ? "Solar each month" : "Solar each day", side: `Average ${kwh(avg).join(" ")} a ${r.period === "year" ? "month" : "day"}`, bars: r.daily, facts } });
  } else if (facts.length) parts.push({ facts: facts.map((f) => ({ label: f.label, value: `${f.sub ? esc(f.sub) + " · " : ""}${f.value}${f.unit ? " " + f.unit : ""}` })) });
  parts.push({ button: openPage("live", r.plantId) });
  return make(`${EVERY[r.period]} solar report for ${r.plant}: ${r.label}`, {
    title: r.label,
    sub: r.plant,
    parts,
    footer: SETTINGS_FOOTER(`Sent every ${r.period}. Turn it off in notification settings.`),
  });
}

// ---------------------------------------------------------------- plant events

// Kinds follow the state changes in 0102 (email_plant_step, email_sweep):
//  grid_down     3 known minutes in a row with no grid (>100 V); once per outage
//  grid_back     2 known minutes with grid, after a grid_down went out
//  batt_hot      hottest battery over 45 C for 3 minutes
//  batt_hot_back 15 min at 43 C or below, after a batt_hot (0151)
//  bank_drift    charge 10 points or more apart between inverters' own batteries for an hour
//  bank_drift_back  under 8 points apart for 15 min, after a bank_drift (0151)
//  string_dead   a string dead for 12 samples while another string on the plant makes
//                over 200 W; every used string on one inverter is one email, "Strings 1 and 2" (0231)
//  string_back   voltage for 15 min with no dead sample, after a string_dead (0151)
//  logger_stale  no new reading for the whole plant, or from one inverter while the others
//                report (inverter set), for 30 min
//  logger_back   readings fresh again, after a logger_stale went out
// The words are in text.ts (alertMail, SOLAR-645), shared with the app's alert list and the
// pop-ups; this lays them out. Times come formatted; day: "today", or the date when the alert
// reaches the owner on a later day ("Tue 21 Oct"), so a time is never read against the wrong day.
export type { LoginEvent, PlantEvent } from "./text.ts";

/** An alert email from text.ts's parts. plantId: the plant its button opens. */
export function alertEmail(m: AlertMail, plantId: number): Email {
  const parts = m.parts.map((x): Part => {
    if ("lead" in x) return { lead: esc(x.lead) };
    if ("note" in x) return { note: esc(x.note) };
    if ("heading" in x) return x;
    if ("button" in x) return { button: { label: x.button.label,
      href: x.button.page === "logins" ? LOGINS : `${APP}/?tab=${x.button.page}&plant=${plantId}` } };
    return { box: { hero: x.box.hero, steps: x.box.steps,
      rows: x.box.rows?.map(([l, v, t]): [string, string] => [l, t === "batt" ? `<span style="color:${C.batt}">${esc(v)}</span>` : esc(v)]) } };
  });
  return make(m.subject, { title: m.title, parts, footer: m.footer ? SETTINGS_FOOTER(esc(m.footer)) : [HELP] });
}
export const plantEvent = (plant: string, plantId: number, e: PlantEvent, day = "today") => alertEmail(alertMail(e, plant, day), plantId);
// One email per login: it names every plant on it (0158).
export const loginEvent = (e: LoginEvent, plantId: number, day = "today") => alertEmail(alertMail(e, "", day), plantId);

// To admin@: a PostHog error tracking alert (SOLAR-336). PostHog calls error-alert with
// the issue; this says what happened and links to it.
export const errorAlert = (a: { trigger: "created" | "reopened"; name: string; description: string; fn: string; url: string }) =>
  make(`${a.trigger === "created" ? "New server error" : "Server error back"}: ${a.name.slice(0, 80)}`, {
    title: a.trigger === "created" ? "A new error" : "A fixed error came back",
    parts: [
      { lead: esc(a.description || a.name).replace(/\n/g, "<br>\n") },
      { box: { rows: [["Error", esc(a.name)], ["Function", esc(a.fn || "web app")], ["Issue", `<a href="${esc(a.url)}">${esc(a.url)}</a>`]] } },
    ],
    footer: [],
  });

// To hello@: a user's "Send feedback" (SOLAR-428). Reply-to is the sender (notify sets it),
// so Reply answers them. The screenshot, if any, comes as an attachment.
export const feedback = (f: { email: string; message: string; page: string; version: string; user: string; image: boolean }) =>
  make(`Feedback: ${f.message.replace(/\s+/g, " ").slice(0, 60)}`, {
    title: "New feedback",
    parts: [
      { lead: esc(f.message).replace(/\n/g, "<br>\n") },
      { box: { rows: [["From", esc(f.email)], ["Page", esc(f.page || "unknown")], ["Version", esc(f.version || "unknown")],
        ["Screenshot", f.image ? "attached" : "none"], ["User", esc(f.user)]] } },
    ],
    footer: [],
  });
