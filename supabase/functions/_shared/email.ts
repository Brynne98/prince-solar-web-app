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
// links with Supabase's Go placeholders ({{ .ConfirmationURL }}) and the output is
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
export const FROM_ACCOUNT = "Prince Solar Hub <noreply@princesolarhub.co.za>";
export const FROM_ALERTS = "Prince Solar Hub <alerts@princesolarhub.co.za>";
export const FROM_BILLING = "Prince Solar Hub <billing@princesolarhub.co.za>";
export const FROM_REPORTS = "Prince Solar Hub <reports@princesolarhub.co.za>";
export const FROM_HELLO = "Prince Solar Hub <hello@princesolarhub.co.za>";
export const REPLY_TO = "hello@princesolarhub.co.za";
// The sender for a mail_queue kind. Account mail Supabase Auth sends itself uses noreply@ too.
export const senderFor = (kind: string) =>
  kind === "account_deleted" ? FROM_ACCOUNT
    : kind.startsWith("bill_") || kind === "free_week_soon" ? FROM_BILLING
    : kind.startsWith("report_") ? FROM_REPORTS
    : kind === "welcome" || kind === "history" || kind === "free_week_setup" || kind === "winback" || kind === "need_a_hand" ? FROM_HELLO
    : FROM_ALERTS;
// Supabase's link lifetime (Auth -> mailer OTP expiry): 24 hours since SOLAR-196.
const LINK_LIFE = "The link works once, for 24 hours.";

// An email address in body text. Gmail links any address it finds and paints it blue,
// so give it a link of our own in the text colour.
const addr = (email: string) => `<a href="mailto:${email}" style="color:#e7ecf2;text-decoration:none;font-weight:700">${email}</a>`;
// The one help line every email ends with.
const HELP = `Need help? Email <a href="mailto:hello@princesolarhub.co.za">hello@princesolarhub.co.za</a>.`;

export type Email = { subject: string; html: string; text: string };

// Same roles as the app's :root (public/index.html, SOLAR-346). The five power colours
// mean only solar, home, grid, charge and battery; status words take ok, warn or bad;
// the main button takes accent. Money has no colour: it stays plain text.
const C = {
  solar: "#3ddc84",
  home: "#f87171",
  grid: "#facc15",
  cyan: "#22d3ee",
  batt: "#a78bfa",
  ok: "#3ddc84",
  warn: "#f59e0b",
  bad: "#ef4444",
} as const;
const ACCENT = "#3ddc84";
type Tone = keyof typeof C;

const esc = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

const SANS = "'Space Grotesk',-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";
const MONO = "'JetBrains Mono',ui-monospace,Menlo,Consolas,monospace";

const STYLE = `
:root{color-scheme:dark;supported-color-schemes:dark}
body{margin:0;padding:0}
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
  | { plants: { title: string; names: string[]; tone: "keep" | "stop"; count?: false } } // one row per plant, any number; count: false when the title already counts
  | { items: { rows: Item[]; total?: { label: string; value: string }; meta?: string[] } } // billing: what is paid for, as receipt rows
  | { bars: Bars }; // daily solar kWh; null = no data

// labels: one under each bar (a week); titles: the hover text per bar, where the mail app
// shows it (desktop only). The highest bar is drawn full green, the rest dimmer.
// A change on the previous period: the arrow and percent take the tone, the rest stays grey.
type Delta = { n: number; prev: string; tone?: "good" | "bad" };
type Bars = { values: (number | null)[]; from: string; to: string; labels?: string[]; titles?: string[] };

type Body = { title: string; sub?: string; parts: Part[]; footer: string[] };
const PLANT_ROWS = 10;

// Billing rows (SOLAR-297), like a store receipt: an icon tile, the name, a grey detail
// under it, the price on the right. Space separates the rows, no lines. Plant lists use
// the same row with a coloured dot.
type Item = { icon: "plan" | "plus" | "back" | "keep" | "stop"; name: string; sub?: string; value?: string };
const tileIcon = (icon: Item["icon"]) =>
  icon === "plan" ? `<img src="${SITE}/icon-192.png" width="18" height="18" alt="" style="display:inline-block;vertical-align:middle;border:0;border-radius:4px">`
    : icon === "plus" ? `<span style="font:700 17px/1 ${SANS};color:${ACCENT}">+</span>`
    : icon === "back" ? `<span style="font:700 15px/1 ${SANS};color:#9aa5b3">&#8617;</span>`
    : `<span style="display:inline-block;width:8px;height:8px;border-radius:4px;background:${icon === "keep" ? C.ok : C.bad};vertical-align:middle"></span>`;
const itemRow = (r: Item) => `<tr><td width="32" style="width:32px;padding:6px 12px 6px 0;vertical-align:middle">` +
  `<div style="width:32px;height:32px;border-radius:8px;background:#141a22;text-align:center;line-height:32px">${tileIcon(r.icon)}</div></td>` +
  `<td style="padding:6px 0;vertical-align:middle"><div style="font:700 14px/1.3 ${SANS};color:#e7ecf2">${r.name}</div>` +
  (r.sub ? `<div style="margin-top:2px;font:400 12px/1.4 ${SANS};color:#7f8da0">${r.sub}</div>` : "") + `</td>` +
  (r.value != null ? `<td align="right" style="padding:6px 0 6px 12px;vertical-align:middle;white-space:nowrap;font:700 14px/1.3 ${MONO};font-variant-numeric:tabular-nums;color:#e7ecf2">${r.value}</td>` : "") +
  `</tr>`;

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
  const tone = d.tone === "good" ? C.ok : d.tone === "bad" ? C.bad : "#9aa5b3";
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
    if ("plants" in x) {
      // One row per plant, so a long name wraps in its own row and many plants stay a
      // list. Past PLANT_ROWS the rest are counted, not listed: an installer login can
      // bring dozens.
      const { title, names, tone, count } = x.plants;
      const shown = names.length > PLANT_ROWS ? names.slice(0, PLANT_ROWS - 1) : names;
      const more = names.length - shown.length;
      return `<div style="margin:0 0 6px;font:500 11px/1 ${SANS};letter-spacing:.12em;text-transform:uppercase;color:#9aa5b3">${esc(title)}${names.length > 1 && count !== false ? ` · ${names.length} plants` : ""}</div>` +
        `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 16px">${shown.map((n) => itemRow({ icon: tone, name: esc(n) })).join("")}` +
        (more ? `<tr><td></td><td style="padding:6px 0;font:400 14px/1.35 ${SANS};color:#9aa5b3">and ${more} more, listed in Billing</td></tr>` : "") +
        `</table>`;
    }
    if ("items" in x) {
      const { rows, total, meta } = x.items;
      return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 ${meta ? 10 : 16}px">${rows.map(itemRow).join("")}` +
        (total ? `<tr><td colspan="2" style="padding:12px 0 0;font:700 14px/1.3 ${SANS};color:#e7ecf2">${esc(total.label)}</td>` +
          `<td align="right" style="padding:12px 0 0;white-space:nowrap;font:700 14px/1.3 ${MONO};font-variant-numeric:tabular-nums;color:#e7ecf2">${total.value}</td></tr>` : "") +
        `</table>` + (meta ? `<p class="d" style="margin:0 0 16px;font:400 12px/1.6 ${SANS};color:#7f8da0">${meta.join("<br>")}</p>` : "");
    }
    if ("callout" in x)
      return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 16px"><tr><td style="padding:14px 16px;background:rgba(239,68,68,.07);border:1px solid rgba(239,68,68,.4);border-radius:8px;font:500 15px/1.45 ${SANS};color:#e7ecf2">` +
        `<span style="display:inline-block;width:8px;height:8px;border-radius:4px;background:${C.bad};margin-right:10px;vertical-align:1px"></span>${x.callout}</td></tr></table>`;
    if ("facts" in x)
      return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 16px">${x.facts.map((f) =>
        `<tr><td style="padding:6px 0;font:400 14px/1.3 ${SANS};color:#9aa5b3">${esc(f.label)}</td>` +
        `<td align="right" style="padding:6px 0;font:700 14px/1.3 ${MONO};font-variant-numeric:tabular-nums;color:#e7ecf2">${f.value}</td></tr>`).join("")}</table>`;
    if ("button" in x)
      return `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 12px"><tr><td style="border-radius:8px;background:${ACCENT}"><a href="${x.button.href}" style="display:inline-block;padding:12px 22px;font:600 15px/1 ${SANS};color:#0a0d12;text-decoration:none;border-radius:8px">${esc(x.button.label)}</a></td></tr></table>`;
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
<body style="margin:0;padding:0">
<!-- The dark fills the whole mail window, with the lighter card in the middle (SOLAR-287). -->
<table role="presentation" class="bg" width="100%" cellpadding="0" cellspacing="0" style="background:#0a0d12"><tr><td align="center" style="padding:40px 8px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px">
<tr><td style="padding:24px 16px 16px 20px"><a href="${APP}" style="text-decoration:none"><img src="${SITE}/icon-192.png" width="28" height="28" alt="" style="vertical-align:middle;border:0;border-radius:6px"> <span class="t" style="vertical-align:middle;font:700 17px/1 ${SANS};color:#e7ecf2">Prince Solar Hub</span></a></td></tr>
<tr><td style="padding:0 12px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td class="card pad" style="background:#11161d;border:1px solid rgba(255,255,255,.07);border-radius:12px;padding:32px 32px ${Math.max(0, 32 - tail)}px">
<h1 class="t" style="margin:0 0 ${b.sub ? 4 : 16}px;font:700 22px/1.25 ${SANS};letter-spacing:-.02em;color:#e7ecf2">${esc(b.title)}</h1>
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
    if ("p" in x) out.push(strip(x.p), "");
    else if ("note" in x) out.push(strip(x.note), "");
    else if ("steps" in x) out.push(...x.steps.map((s, i) => `${i + 1}. ${strip(s)}`), "");
    else if ("button" in x) out.push(`${x.button.label}: ${x.button.href}`, "");
    else if ("bars" in x && x.bars.labels) out.push(x.bars.labels.map((l, i) => `${l} ${x.bars.values[i] == null ? "–" : x.bars.values[i]!.toFixed(0)}`).join(", ") + " kWh", "");
    else if ("chart" in x) out.push(x.chart.title, ...(x.chart.bars.labels ? [x.chart.bars.labels.map((l, i) => `${l} ${x.chart.bars.values[i] == null ? "–" : x.chart.bars.values[i]!.toFixed(0)}`).join(", ") + " kWh"] : []),
      ...x.chart.facts.map((f) => `${f.label}: ${strip(f.value)}${f.unit ? " " + f.unit : ""}${f.sub ? `, ${f.sub}` : ""}`), "");
    else if ("plants" in x) out.push(`${x.plants.title}${x.plants.names.length > 1 && x.plants.count !== false ? ` (${x.plants.names.length} plants)` : ""}:`, ...x.plants.names.map((n) => `- ${n}`), "");
    else if ("callout" in x) out.push(strip(x.callout), "");
    else if ("items" in x) out.push(...x.items.rows.map((r) => `${strip(r.name)}${r.sub ? ` (${strip(r.sub)})` : ""}${r.value ? `: ${strip(r.value)}` : ""}`),
      ...(x.items.total ? [`${x.items.total.label}: ${strip(x.items.total.value)}`] : []), ...(x.items.meta ?? []).map(strip), "");
    else if ("facts" in x) out.push(...x.facts.map((f) => `${f.label}: ${strip(f.value)}`), "");
    else if ("stats" in x) out.push(...x.stats.map((s) => `${s.label}: ${s.value}${s.unit ? " " + s.unit : ""}${s.delta ? ` (${deltaText(s.delta)})` : s.sub ? ` (${s.sub})` : ""}`), "");
  }
  if (b.footer.length) out.push("--", ...b.footer.map((f) => strip(f.replace(/<a href="(?!mailto:)([^"]+)"[^>]*>([^<]+)<\/a>/g, "$2: $1"))));
  return out.filter((l, i, a) => !(l === "" && a[i - 1] === "")).join("\n");
}

const make = (subject: string, b: Body): Email => ({ subject, html: html(subject, b), text: text(b) });


// ---------------------------------------------------------------- account mail

function account(subject: string, title: string, label: string, url: string, ignore: string): Email {
  return make(subject, {
    title,
    parts: [{ note: LINK_LIFE }, { button: { label, href: url } }],
    footer: [ignore, HELP],
  });
}

export const confirmSignup = (url: string) =>
  account("Confirm your email", "Confirm your email",
    "Confirm email", url, "Didn't sign up? Ignore this email.");

export const resetPassword = (url: string) =>
  account("Reset your password", "Reset your password",
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
    parts: [{ p: `The password for ${addr(esc(email))} was just changed.` }, ...notYou],
    footer: [HELP],
  });

export const accountDeleted = (email: string) =>
  make("Your account is deleted", {
    title: "Your account is deleted",
    parts: [{ p: `The account for ${addr(esc(email))} is deleted, with its settings and readings. Your SunSynk account and inverter are not affected.` },
      { note: "Sign up again any time. The last 60 days come back from SunSynk." }],
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

// Sent once the email is confirmed, before any plant is added. The Add plant
// card opens on Live when a user has no plant, so the button goes straight there.
// Wording matches link.jsx ("Add your plant", "Use the login from the
// SunSynk Connect app").
export const welcome = () =>
  make("Welcome to Prince Solar Hub", {
    title: "Welcome to Prince Solar Hub",
    parts: [
      { p: "One step left: add your plant." },
      { steps: [
        "Tap the button below and sign in.",
        "Enter the email and password from your <b>SunSynk Connect</b> app.",
        "Readings start within a minute. Your last 60 days follow.",
      ] },
      { button: { label: "Add your plant", href: APP } },
    ],
    footer: [HELP],
  });

// 24 hours after sign-up, only if no SunSynk login was ever added (SOLAR-319). The
// welcome email's steps again; from hello@, so a reply reaches us.
export const needAHand = () =>
  make("Need a hand adding your plant?", {
    title: "Need a hand adding your plant?",
    parts: [
      { p: "No plant is linked yet. It takes two minutes." },
      { steps: [
        "Tap the button below and sign in.",
        "Enter the email and password from your <b>SunSynk Connect</b> app.",
        "Readings start within a minute. Your last 60 days follow.",
      ] },
      { button: { label: "Add your plant", href: APP } },
      { p: "Stuck? Reply and we'll help." },
    ],
    footer: [],
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
    title: `Your last ${days} are in`,
    sub: `${h.plant} · ${h.from} to ${h.to}`,
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

// SunSynk's own service is down: every plant is affected, not one inverter.
export const sunsynkDown = (plant: string, plantId: number, since: string, day = "today") =>
  make("SunSynk is down", {
    title: "SunSynk is down",
    parts: [
      { stack: true, stats: [{ label: "SunSynk", value: "Down", tone: "bad", sub: `since ${since} ${day}` }] },
      { p: "Every SunSynk plant is affected, not only yours." },
      { button: openPage("live", plantId) },
    ],
    footer: ALERT_FOOTER(plant),
  });

export const sunsynkBack = (plant: string, plantId: number, at: string, lasted: string, day = "today") =>
  make("SunSynk is back", {
    title: "SunSynk is back",
    parts: [
      { stack: true, stats: [{ label: "SunSynk", value: "Back", tone: "ok", sub: `since ${at} ${day}, after ${lasted}` }] },
      { button: openPage("live", plantId) },
    ],
    footer: ALERT_FOOTER(plant),
  });

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
  bestDay?: { label: string; kwh: number };
  highestUse?: { label: string; kwh: number }; // the day the home used the most ("Busiest day")
  daily?: Bars; // solar kWh per day (per month for a year)
  freeWeekEnds?: boolean; // the week report sent at the end of a Free account's first week (SOLAR-208)
  partialFrom?: string; // first day counted, when after the period starts: "20 Oct" (SOLAR-273)
  partialWhy?: "added" | "history"; // the plant was added then (SOLAR-305), or its history starts then
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
    ...(r.importKwh != null ? [{ label: "Imported", value: kwh(r.importKwh)[0], unit: kwh(r.importKwh)[1], tone: "grid" as Tone, ...trend(r.change.import, r.prevLabel, "down") }] : []),
    ...(r.exportKwh != null ? [{ label: "Exported", value: kwh(r.exportKwh)[0], unit: kwh(r.exportKwh)[1], tone: "grid" as Tone }] : []),
    { label: "Independence", value: `${Math.round(r.independencePct)}%`, tone: "cyan", ...trend(r.change.independence, r.prevLabel, "up") },
    ...(r.savedRand != null ? [{ label: "Est. saved", value: rand(r.savedRand), ...trend(r.change.saved, r.prevLabel, "up") }] : []),
  ];
  const parts: Part[] = [];
  // A Free account's day-7 report is its last, so it promises no next one.
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
  if (r.freeWeekEnds) {
    parts.push({ note: `Your free week ends today. From tomorrow, ${FREE_RULE}` });
    parts.push({ button: { label: "See plans", href: PLANS } });
  } else parts.push({ button: openPage("live", r.plantId) });
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
//  string_dead   a string dead for 12 samples while another string on the same
//                inverter makes over 200 W
//  string_back   voltage for 15 min with no dead sample, after a string_dead (0151)
//  logger_stale  no new reading for the whole plant, or from one inverter while the others
//                report (inverter set), for 30 min
//  logger_back   readings fresh again, after a logger_stale went out
//  needs_relink  the login turned needs_relink in poll
export type PlantEvent =
  | { kind: "grid_down"; at: string; chargePct?: number }
  | { kind: "grid_back"; at: string; lasted?: string }
  | { kind: "batt_hot"; at: string; tempC: number; hotDays?: number } // hotDays: days over 45 C in the last 30, today included; counted from readings at send time
  | { kind: "batt_hot_back"; at: string; tempC: number; lasted: string }
  | { kind: "bank_drift"; banks: { name: string; chargePct: number }[] } // name: the inverter's name in SunSynk
  | { kind: "bank_drift_back"; banks: { name: string; chargePct: number }[]; lasted: string }
  | { kind: "string_dead"; string: string; inverter: string; since: string }
  | { kind: "string_back"; string: string; inverter: string; at: string; lasted: string }
  | { kind: "logger_stale"; since: string; inverter?: string }
  | { kind: "logger_back"; at: string; lasted: string; inverter?: string }
  | { kind: "needs_relink" };

// day: "today", or the date when the alert reaches the owner on a later day
// ("Tue 21 Oct"), so a time is never read against the wrong day.
//
// Each alert shows its facts as cards, like the reports: coral for what went wrong,
// green for what came back, amber for grid, purple for battery. A sentence stays only
// where the cards can't explain it alone.
type Card = Extract<Part, { stats: unknown }>["stats"][number];
const PAGE: Record<Exclude<PlantEvent["kind"], "needs_relink">, keyof typeof PAGES> = {
  grid_down: "grid", grid_back: "grid",
  batt_hot: "inverters", batt_hot_back: "inverters", bank_drift: "inverters", bank_drift_back: "inverters",
  string_dead: "inverters", string_back: "inverters",
  logger_stale: "live", logger_back: "live",
};
// "Inverter 2508290475, string 2", as the app names it (SOLAR-348)
const stringName = (e: { string: string; inverter: string }) => `${e.inverter}, ${e.string.toLowerCase()}`;
const ALERT_FOOTER = (plant: string) => SETTINGS_FOOTER(`Alert for ${esc(plant)}. Turn these off in notification settings.`);
export function plantEvent(plant: string, plantId: number, e: PlantEvent, day = "today"): Email {
  const P = esc(plant);
  const at = (time: string) => `${time} ${day}`;
  const [title, cards, note]: [string, Part | Card[], string?] = (() => {
    switch (e.kind) {
      case "grid_down":
        return [`Grid down at ${plant}`, [
          { label: "Grid", value: "Off", tone: "bad", sub: `since ${at(e.at)}` },
          ...(e.chargePct != null ? [{ label: "Battery", value: `${e.chargePct}%`, tone: "batt" as Tone }] : []),
        ]];
      case "grid_back":
        return [`Grid back at ${plant}`, [
          { label: "Grid", value: "On", tone: "ok", sub: `since ${at(e.at)}` },
          ...(e.lasted ? [{ label: "Outage", value: e.lasted }] : []),
        ]];
      case "batt_hot":
        return [`Battery hot at ${plant}`, [
          { label: "Battery", value: `${e.tempC}\u00a0°C`, tone: "bad", sub: `at ${at(e.at)}` },
          ...((e.hotDays ?? 1) > 1 ? [{ label: "Above 45\u00a0°C", value: `${e.hotDays} days`, sub: "in the last 30" }] : []),
        ]];
      case "batt_hot_back":
        return [`Battery cooled at ${plant}`, [
          { label: "Battery", value: `${e.tempC}\u00a0°C`, tone: "ok", sub: `since ${at(e.at)}` },
          { label: "Hot for", value: e.lasted },
        ]];
      case "bank_drift_back":
        return [`Batteries charging evenly at ${plant}`, [
          ...e.banks.map((b) => ({ label: b.name, value: `${b.chargePct}%`, tone: "batt" as Tone })),
          { label: "Apart for", value: e.lasted },
        ]];
      case "bank_drift": {
        const pcts = e.banks.map((b) => b.chargePct);
        return [`Batteries charging unevenly at ${plant}`, [
          ...e.banks.map((b) => ({ label: b.name, value: `${b.chargePct}%`, tone: "batt" as Tone })),
          { label: "Gap", value: `${Math.max(...pcts) - Math.min(...pcts)}%`, sub: "for over an hour" },
        ]];
      }
      case "string_dead":
        return [`Panels stopped producing at ${plant}`, [
          { label: stringName(e), value: "No power", tone: "bad", sub: `since ${at(e.since)}` },
          { label: "Other panels", value: "OK", tone: "ok" },
        ]];
      case "string_back":
        return [`Panels producing again at ${plant}`, [
          { label: stringName(e), value: "Producing", tone: "ok", sub: `since ${at(e.at)}` },
          { label: "Stopped for", value: e.lasted },
        ]];
      case "logger_stale":
        return e.inverter
          ? [`No readings from ${e.inverter} at ${plant}`, [
              { label: "Last reading", value: e.since, tone: "warn", sub: esc(day) },
              { label: "Other inverters", value: "OK", tone: "ok" },
            ]]
          : [`No readings from ${plant}`, [
              { label: "Last reading", value: e.since, tone: "warn", sub: esc(day) },
            ]];
      case "logger_back":
        return [e.inverter ? `${e.inverter} back at ${plant}` : `Readings back at ${plant}`, [
          { label: "Readings", value: "Back", tone: "ok", sub: `since ${at(e.at)}, after ${e.lasted}` },
        ]];
      case "needs_relink":
        return ["Reconnect your SunSynk login", { callout: "SunSynk stopped accepting your login. New readings have stopped." }];
    }
  })();
  const relink = e.kind === "needs_relink";
  return make(title, {
    title,
    parts: [Array.isArray(cards) ? { stats: cards, stack: true } : cards, ...(note ? [{ p: note }] : []), { button: relink ? { label: "Reconnect", href: LOGINS } : openPage(PAGE[e.kind as Exclude<PlantEvent["kind"], "needs_relink">], plantId) }],
    // Reconnect has no switch, so no "turn them off" line.
    footer: relink ? [HELP] : ALERT_FOOTER(plant),
  });
}

// --------------------------------------------------------------------- billing

// SOLAR-208. Billing runs on our side (Paystack charge_authorization), so receipts and
// plan changes come from us; Paystack's own receipts are off. Prices are final: the
// company isn't VAT-registered, so no VAT line. No unsubscribe: these are about money.
const PLAN = `${APP}/?tab=account&section=plan`;
// "Pay with another card": the Plan section opens Paystack's card page for the failed payment.
export const PAY_URL = `${PLAN}&pay=1`;
// Buttons that ask them to pick a plan open Adjust plan: Free, Home and Family side by
// side (SOLAR-341).
const PLANS = `${APP}/?tab=plans`;
// "To stop it, cancel before": Billing's Cancellation section (SOLAR-361).
const CANCEL = `${APP}/?tab=account&section=cancel`;
// Day-2 "Finish setup": Plant settings' Your system, where rate, battery and panels are set (SOLAR-361).
const SYSTEM = `${APP}/?tab=account&section=system`;
// What Free means after its first week, said the same way in every email.
const FREE_RULE = "Free keeps only the last 24 hours of readings. Alerts stay on; reports stop.";
// After a paid plan, readings stay 30 days first (SOLAR-329, 0146).
const PAID_FREE_RULE = "readings are kept for 30 days, then only the last 24 hours. Alerts stay on; reports stop.";
const PLAN_NAME = { free: "Free", home: "Home", family: "Family" } as const;
// Who is selling, on every receipt and renewal notice.
const SELLER = "Prince Solar Hub is run by Theron and Prince Solutions (Pty) Ltd, reg. no. 2026/182827/07, Kempton Park, Gauteng. No VAT is charged.";
export type Plan = keyof typeof PLAN_NAME;
export type BillPeriod = "monthly" | "yearly";
// The plan as a receipt row: "Family plan", "Monthly · from 1 Dec", its price on the right.
const PERIOD = { monthly: "Monthly", yearly: "Yearly" } as const;
const planItem = (plan: Plan, period?: BillPeriod, when?: string, value?: string): Item => {
  const sub = [plan === "free" ? "" : period ? PERIOD[period] : "", when ?? ""].filter(Boolean).join(" · ");
  return { icon: "plan", name: `${PLAN_NAME[plan]} plan`, sub: sub ? sub[0].toUpperCase() + sub.slice(1) : undefined, value };
};
const extraN = (n: number) => `${n} extra ${n === 1 ? "plant" : "plants"}`;
const names = (list: string[]) => list.length < 2 ? list.join("") : `${list.slice(0, -1).join(", ")} and ${list[list.length - 1]}`;

export type Receipt = {
  plan: Plan; period: BillPeriod; amount: number; date: string; // "1 Nov 2026"
  card: string; // "Visa •••• 4081"
  reference: string; // Paystack reference
  extraPlants?: { n: number; each: number }; // plants after the 3rd paid for, and the price of one
  next: { amount: number; date: string };
};

export const paymentReceived = (r: Receipt) => {
  const extra = r.extraPlants ? r.extraPlants.n * r.extraPlants.each : 0;
  return make(`Payment received: ${rand(r.amount)}`, {
    title: "Payment received",
    parts: [
      { items: {
        rows: [
          // The plan's own price is what is left after the extra plants.
          planItem(r.plan, r.period, undefined, extra > 0 && extra < r.amount ? rand(r.amount - extra) : r.extraPlants ? undefined : rand(r.amount)),
          ...(r.extraPlants ? [{ icon: "plus" as const, name: extraN(r.extraPlants.n), sub: `${rand(r.extraPlants.each)} each`, value: rand(extra) }] : []),
        ],
        total: { label: "Paid", value: rand(r.amount) },
        meta: [`${r.date} · ${esc(r.card)}`, `Reference ${esc(r.reference)}`, `Next payment ${rand(r.next.amount)} on ${r.next.date}`],
      } },
      { button: { label: "See your plan", href: PLAN } },
    ],
    footer: [SELLER, HELP],
  });
};

// Yearly plans: notice 40 to 80 business days before the renewal (Consumer Protection
// Act s14, if a yearly plan counts as fixed-term; to confirm on SOLAR-104). It names any
// change and says the plan can be stopped before the date.
export type Renewal = { plan: Plan; amount: number; on: string; change?: string };

export const renewalNotice = (r: Renewal) =>
  make(`Your yearly ${PLAN_NAME[r.plan]} plan renews on ${r.on}`, {
    title: `Your yearly plan renews on ${r.on}`,
    parts: [
      ...(r.change ? [{ p: esc(r.change) }] : []),
      { items: { rows: [planItem(r.plan, "yearly", `renews ${r.on}`, rand(r.amount))] } },
      { p: `To stop it, cancel before ${r.on}.` },
      { button: { label: "Go to cancel plan", href: CANCEL } },
    ],
    footer: [SELLER, HELP],
  });

// An offer price that lasts some months ends: sent up to 30 days before the first charge
// at the usual price (SOLAR-330).
export type OfferEnds = { plan: Plan; period: BillPeriod; was: number; amount: number; on: string; card?: string };
export const offerEnds = (o: OfferEnds) =>
  make(`${PLAN_NAME[o.plan]} goes to ${rand(o.amount)} ${o.period === "yearly" ? "a year" : "a month"} on ${o.on}`, {
    title: `Your offer price ends on ${o.on}`,
    parts: [
      { p: `You pay ${rand(o.was)} ${o.period === "yearly" ? "a year" : "a month"} until then.${o.card ? ` We'll charge your ${esc(o.card)}.` : ""}` },
      { items: { rows: [planItem(o.plan, o.period, `from ${o.on}`, rand(o.amount))] } },
      { p: `To stop it, cancel before ${o.on}.` },
      { button: { label: "Go to cancel plan", href: CANCEL } },
    ],
    footer: [SELLER, HELP],
  });

// An upgrade starts at once: the difference for the days left is charged now, the
// billing date stays (SOLAR-208). Adding extra plants past the 3rd is the same.
export type Upgrade = {
  from: Plan; to: Plan; period: BillPeriod;
  addedPlants?: number; // set when the change is extra plants on Family
  paidNow: number; daysLeft: number;
  // Home monthly to Family yearly (SOLAR-364): the year starts today; what the rest of the month came to
  credit?: number;
  next: { amount: number; date: string };
};

export const planUpgraded = (u: Upgrade) => {
  const plants = u.addedPlants ? `${u.addedPlants} extra ${u.addedPlants === 1 ? "plant" : "plants"}` : "";
  return make(u.addedPlants ? `${plants} added to your plan` : `You're on ${PLAN_NAME[u.to]}`, {
    title: u.addedPlants ? `${plants} added` : `You're on ${PLAN_NAME[u.to]}`,
    parts: [
      { p: u.addedPlants ? "They're billed with your Family plan from today." : u.to === "family" ? "You can add up to 3 plants now." : "Your history is kept from now on." },
      { items: {
        rows: [u.addedPlants ? { icon: "plus" as const, name: plants, sub: `On your ${PLAN_NAME[u.to]} plan` } : planItem(u.to, u.period, "from today")],
        total: { label: "Paid today", value: rand(u.paidNow) },
        meta: [u.credit != null ? `${rand(u.credit)} off for the rest of your month` : `For the ${u.daysLeft === 1 ? "day" : u.daysLeft + " days"} left this period`, `Next payment ${rand(u.next.amount)} on ${u.next.date}`],
      } },
      { button: u.to === "family" && !u.addedPlants ? { label: "Add a plant", href: LOGINS } : { label: "See your plan", href: PLAN } },
    ],
    footer: [HELP],
  });
};

// Monthly to yearly on the same plan is paid now (SOLAR-298). The month paid runs out;
// the year starts on the billing date, so the next payment is a year after it.
export type Switched = Receipt & { startsOn: string };

export const planSwitched = (s: Switched) => {
  const extra = s.extraPlants ? s.extraPlants.n * s.extraPlants.each : 0;
  return make(`Your yearly plan starts on ${s.startsOn}`, {
    title: `Your yearly plan starts on ${s.startsOn}`,
    parts: [
      { items: {
        rows: [
          planItem(s.plan, "yearly", `from ${s.startsOn}`, rand(s.amount - extra)),
          ...(s.extraPlants ? [{ icon: "plus" as const, name: extraN(s.extraPlants.n), sub: `${rand(s.extraPlants.each)} each`, value: rand(extra) }] : []),
        ],
        total: { label: "Paid today", value: rand(s.amount) },
        meta: [`${s.date} · ${esc(s.card)}`, `Reference ${esc(s.reference)}`, `Next payment ${rand(s.next.amount)} on ${s.next.date}`],
      } },
      { button: { label: "See your plan", href: PLAN } },
    ],
    footer: [SELLER, HELP],
  });
};

// Downgrade, cancel (to Free) and a monthly/yearly switch all wait for the billing
// date. Sent when booked; the plants named collect until that date and are deleted on
// deleteOn (SOLAR-295), or on that date when no deleteOn is given.
export type Change = {
  from: Plan; to: Plan; fromPeriod: BillPeriod; toPeriod?: BillPeriod;
  on: string; // the billing date
  removePlants: string[];
  deleteOn?: string;
  next?: { amount: number }; // absent on Free
};

export const planChangeBooked = (c: Change) => {
  const cancel = c.to === "free";
  const switchOnly = c.from === c.to;
  const title = cancel ? `${PLAN_NAME[c.from]} ends on ${c.on}` : switchOnly ? `You switch to ${c.toPeriod} on ${c.on}` : `You move to ${PLAN_NAME[c.to]} on ${c.on}`;
  return make(title, {
    title,
    parts: [
      ...(cancel ? [{ p: `After that, on Free, ${PAID_FREE_RULE}` }] : []),
      { items: {
        rows: [planItem(c.from, c.fromPeriod, `until ${c.on}`), planItem(c.to, c.toPeriod ?? c.fromPeriod, `from ${c.on}`, c.next ? rand(c.next.amount) : "R0")],
        meta: [c.next ? `Next payment ${rand(c.next.amount)} on ${c.on}` : "Nothing more is charged."],
      } },
      ...(c.removePlants.length ? [{ plants: { title: `Deleted on ${c.deleteOn ?? c.on}`, names: c.removePlants, tone: "stop" as const } },
        { note: c.removePlants.length === 1 ? "Its history is deleted too." : "Their history is deleted too." }] : []),
      { button: { label: cancel ? `Keep ${PLAN_NAME[c.from]}` : "See your plan", href: PLAN } },
    ],
    footer: [HELP],
  });
};

// Keep: a booked change undone, so the plan carries on as it is (SOLAR-271).
export type Kept = { plan: Plan; period: BillPeriod; next: { amount: number; date: string } };

export const planKept = (k: Kept) =>
  make(`You're staying on ${PLAN_NAME[k.plan]}`, {
    title: `You're staying on ${PLAN_NAME[k.plan]}`,
    parts: [
      { p: "The change you booked is undone." },
      { items: { rows: [planItem(k.plan, k.period, undefined, rand(k.next.amount))], meta: [`Next payment ${rand(k.next.amount)} on ${k.next.date}`] } },
      { button: { label: "See your plan", href: PLAN } },
    ],
    footer: [HELP],
  });

// A failed charge is retried on day 1, 3 and 7 after the billing date. The first email
// goes as soon as the billing-day charge fails, not at the day-1 retry; each retry that
// fails sends another, with a link to pay with another card.
export type Failed = {
  plan: Plan; period: BillPeriod; amount: number; card: string;
  nextTry?: string; // absent after the last try
  freeOn: string; // the day the account moves to Free if it stays unpaid
  payUrl: string;
  disputed?: string; // the bank took a payment back (a lost dispute, 0130): the day it was paid
};

export const paymentFailed = (f: Failed) =>
  make(`Your payment of ${rand(f.amount)} didn't go through`, {
    title: "Your payment didn't go through",
    parts: [
      { callout: f.disputed ? `Your bank took back the ${rand(f.amount)} paid on ${f.disputed}.` : `${esc(f.card)} was declined for ${rand(f.amount)}.` },
      { p: f.nextTry
        ? `We'll try again on ${f.nextTry}. If it's still unpaid on ${f.freeOn}, your account moves to Free.`
        : `That was the last try. Your account moves to Free on ${f.freeOn} unless it's paid.` },
      { items: { rows: [planItem(f.plan, f.period, "unpaid", rand(f.amount))] } },
      { button: { label: "Pay with another card", href: f.payUrl } },
    ],
    footer: [HELP],
  });

// A payment we refund (0130): it applied nothing, because the plan or the price changed
// while the user paid. Not sent for the R1 card check.
export type Refund = { amount: number; date: string; reference: string; why: "price" | "changed" };

export const paymentRefunded = (r: Refund) =>
  make(`${rand(r.amount)} is on its way back to your card`, {
    title: `${rand(r.amount)} is on its way back to your card`,
    parts: [
      { p: r.why === "price" ? "The price changed while you paid. Pay the new price on your plan."
        : "Your plan changed while you paid." },
      { items: { rows: [{ icon: "back", name: "Refund", sub: `Paid ${r.date} · Reference ${esc(r.reference)}`, value: rand(r.amount) }] } },
      { button: { label: "See your plan", href: PLAN } },
    ],
    footer: [HELP],
  });

// To hello@ (Brynne): a bill email failed after its last try, so the user never heard.
export const billMailFailed = (m: { kind: string; key: string; user: string; error: string }) =>
  make(`Bill email not sent: ${m.kind}`, {
    title: "A bill email was not sent",
    parts: [{ facts: [
      { label: "Email", value: esc(m.kind) },
      { label: "Key", value: esc(m.key) },
      { label: "User", value: esc(m.user) },
      { label: "Error", value: esc(m.error) },
    ] }],
    footer: [],
  });

// Unpaid after the last try: the account is on Free. The first-linked plant stays
// live; the others stop updating and are deleted after 30 days, unless paid for or
// swapped for the one kept.
export type MovedToFree = { from: Plan; kept: string; stopped: string[]; deleteOn: string };

export const movedToFree = (m: MovedToFree) =>
  make("Your account is now on Free", {
    title: "Your account is now on Free",
    parts: [
      { p: `Payment for ${PLAN_NAME[m.from]} didn't go through. On Free, ${PAID_FREE_RULE}` },
      { plants: { title: "Still updating", names: [m.kept], tone: "keep" } },
      ...(m.stopped.length ? [{ plants: { title: `Stopped, deleted on ${m.deleteOn}`, names: m.stopped, tone: "stop" as const } }] : []),
      ...(m.stopped.length ? [{ note: "Or choose which plant Free keeps." }] : []),
      { button: { label: m.stopped.length ? "Pay to keep these plants" : "Pay now", href: PLANS } },
    ],
    footer: [HELP],
  });

// Once, when a cancelled plan ends on its date (SOLAR-328, 0144). Readings are kept 30
// days after (SOLAR-329). No switch to turn it off: it goes once per plan that ends.
export const winback = (w: { from: Plan; keepUntil: string }) =>
  make(`Your ${PLAN_NAME[w.from]} plan has ended`, {
    title: `Your ${PLAN_NAME[w.from]} plan has ended`,
    parts: [
      { p: `You're on Free now. Your readings are kept until ${w.keepUntil}, then only the last 24 hours.` },
      { button: { label: "Pick a plan", href: PLANS } },
    ],
    footer: [HELP],
  });

// 3 days before plants are deleted (after a downgrade, cancel or failed payment).
export const plantsRemovalSoon = (plants: string[], on: string) =>
  // The subject names one or two plants; past that it counts them, so it stays short.
  make(`${plants.length > 2 ? `${plants.length} plants` : names(plants)} ${plants.length === 1 ? "is" : "are"} deleted on ${on}`, {
    title: `${plants.length === 1 ? "A plant is" : "Plants are"} deleted on ${on}`,
    parts: [
      // The heading already gives the date, so the list only counts.
      { plants: { title: plants.length === 1 ? "1 plant" : `${plants.length} plants`, names: plants, tone: "stop", count: false } },
      { p: `${plants.length === 1 ? "Its" : "Their"} history goes too.` },
      { button: { label: "Choose the plant to keep", href: PLAN } },
    ],
    footer: [HELP],
  });

// Two days before a Free account's first week ends (SOLAR-242): what goes, in days. The
// day-7 report says it again. `days` = day totals the plant holds; 0 when unknown.
export const freeWeekEndsSoon = (endsOn: string, plant: string, days: number, perMonth: number) => {
  const title = `${days > 1 ? `${days} days of history` : "History"} for ${plant} go${days > 1 ? "" : "es"} on ${endsOn}`;
  return make(title, {
    title,
    parts: [
      { p: `Free keeps only the last 24 hours. Keep it all for R${perMonth} a month, billed yearly.` },
      { button: { label: "Keep my history", href: PLANS } },
    ],
    footer: [HELP],
  });
};

// Day 2 of the free week, only while setup steps are left (0122): each one left, and
// where its number is found.
export type SetupStep = "rate" | "size" | "reserve" | "panels";
const SETUP_WHERE: Record<SetupStep, string> = {
  rate: "<b>Electricity rate</b>: price per unit on your bill, with VAT.",
  size: "<b>Battery size</b>: on the battery's label, or under Equipment in the SunSynk app.",
  reserve: "<b>Battery reserve</b>: as set on your inverter.",
  panels: "<b>Solar panels</b>: panel count times watts each, from your installer's invoice.",
};
export const freeWeekSetup = (steps: SetupStep[]) =>
  make("Finish your setup", {
    title: "Finish your setup",
    parts: [
      { steps: steps.filter((s) => s in SETUP_WHERE).map((s) => SETUP_WHERE[s]) },
      { button: { label: "Finish setup", href: SYSTEM } },
    ],
    footer: [HELP],
  });
