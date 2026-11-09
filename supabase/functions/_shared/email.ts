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

const STYLE = `
:root{color-scheme:dark;supported-color-schemes:dark}
body{margin:0;padding:0}
a{color:inherit}
@media (max-width:520px){.pad{padding:20px 20px var(--pb-m,8px)!important}}
@media (max-width:340px){.card{width:auto!important;display:block!important;margin-right:0!important}}
`;

// The one box every email shows its facts in (SOLAR-415): an optional big number, then
// label-value rows split by space, no lines. Values may hold markup set by us (a coloured
// battery %), never user text unescaped. tone colours the big number only.
type Hero = { label: string; value: string; tone?: Tone; sub?: string };
// checks: a checklist (setup) or numbered steps (adding a plant). A done line is ticked
// and struck through, name only; an open line has an empty circle, or its step number n,
// then the name, a line under it, and a dimmer line under that.
type Check = { name: string; done?: boolean; n?: number; text?: string; sub?: string };
type Box = { hero?: Hero; rows?: [label: string, value: string][]; checks?: Check[] };

type Part =
  | { lead: string } // grey sentence under the title: what happened, only when the box can't say it
  | { box: Box }
  | { small: string } // small print under the button ("The link works once, for 24 hours.")
  | { button: { label: string; href: string } }
  | { stats: { label: string; value: string; unit?: string; tone?: Tone; sub?: string; delta?: Delta }[] } // report tiles, two to a row
  | { chart: { title: string; side?: string; bars: Bars; facts: { label: string; value: string; unit?: string; tone?: Tone; sub?: string }[] } }
  | { facts: { label: string; value: string }[] } // label left, value right
  | { note: string };

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
  return `<span style="color:${tone};font-weight:600">${r > 0 ? "↑" : r < 0 ? "↓" : "→"} ${Math.abs(r)}%</span> vs ${esc(d.prev)}`;
};
const deltaText = (d: Delta) => { const r = Math.round(d.n); return `${r > 0 ? "↑" : r < 0 ? "↓" : "→"} ${Math.abs(r)}% vs ${d.prev}`; };

function html(subject: string, b: Body): string {
  const rows = b.parts.map((x) => {
    if ("lead" in x) return `<p class="m" style="margin:0 0 16px;font:400 15px/1.55 ${SANS};color:#9aa5b3">${x.lead}</p>`;
    if ("small" in x) return `<p class="d" style="margin:0;font:400 13px/1.5 ${SANS};color:#7f8da0">${x.small}</p>`;
    if ("box" in x) {
      const { hero, rows: r = [], checks = [] } = x.box;
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
      return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 20px"><tr><td style="padding:${checks.length ? "4px 18px" : `${hero ? 18 : 12}px 18px ${r.length ? 12 : 18}px`};background:#141a22;border-radius:10px">` +
        `<table role="presentation" width="100%" cellpadding="0" cellspacing="0">${big}${lines}${list}</table></td></tr></table>`;
    }
    if ("note" in x) return `<p class="m" style="margin:0 0 16px;font:400 14px/1.55 ${SANS};color:#9aa5b3">${x.note}</p>`;
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
    const cells = x.stats.map((s) => `<td class="tile" width="50%" style="padding:16px;background:#141a22;border-radius:8px;vertical-align:top">
<div class="m" style="font:500 11px/1 ${SANS};letter-spacing:.12em;text-transform:uppercase;color:#9aa5b3">${esc(s.label)}</div>
<div class="${s.tone ?? "t"}" style="margin-top:8px;font:700 24px/1.1 ${MONO};font-variant-numeric:tabular-nums;color:${s.tone ? C[s.tone] : "#e7ecf2"}">${esc(s.value)}${s.unit ? `<span style="font-size:14px;opacity:.85"> ${esc(s.unit)}</span>` : ""}</div>
${s.delta ? `<div class="d" style="margin-top:6px;font:400 12px/1.4 ${SANS};color:#7f8da0">${deltaHtml(s.delta)}</div>` : s.sub ? `<div class="d" style="margin-top:6px;font:400 12px/1.4 ${SANS};color:#7f8da0">${esc(s.sub)}</div>` : ""}</td>`);
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
    else if ("small" in x) out.push(strip(x.small), "");
    else if ("box" in x) out.push(...(x.box.hero ? [`${x.box.hero.label}: ${x.box.hero.value}${x.box.hero.sub ? ` (${x.box.hero.sub})` : ""}`] : []),
      ...(x.box.rows ?? []).map(([l, v]) => `${l}: ${strip(v)}`), ...(x.box.checks ?? []).map((c) => c.done ? `[x] ${c.name}` : `${c.n ? `${c.n}.` : "[ ]"} ${[c.name, [c.text, c.sub].filter(Boolean).join(" ")].filter(Boolean).join(": ")}`), "");
    else if ("note" in x) out.push(strip(x.note), "");
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
    parts: [{ lead: `The settings and readings for ${addr(esc(email))} are gone. Your SunSynk account and inverter aren't affected.` },
      { note: "Sign up again any time. Your last 60 days come back from SunSynk." }],
    footer: [HELP],
  });

// Supabase Auth fills these placeholders itself; they must reach it unescaped.
export function renderAuthTemplates(): Record<string, Email> {
  // Only what the app uses: password sign-up and reset. No email sign-in link, and
  // the email address can't be changed yet.
  const URL = "{{ .ConfirmationURL }}";
  return {
    confirmation: confirmSignup(URL, "{{ .Email }}"),
    recovery: resetPassword(URL, "{{ .Email }}"),
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
const ADD_STEPS = {
  box: { checks: [
    { n: 1, name: "Tap Add your plant" },
    { n: 2, name: "Sign in with SunSynk", text: "Use the email and password from your SunSynk Connect app." },
    { n: 3, name: "Watch it fill in", text: "Readings start within a minute. Your last 60 days follow." },
  ] },
};
export const welcome = () =>
  make("Welcome to Prince Solar Hub", {
    title: "Welcome to Prince Solar Hub",
    parts: [{ lead: "Three steps, about a minute." }, ADD_STEPS, { button: { label: "Add your plant", href: APP } }],
    footer: [HELP],
  });

// 24 hours after sign-up, only if no SunSynk login was ever added (SOLAR-319). The
// welcome email's steps again; from hello@, so a reply reaches us.
export const needAHand = () =>
  make("Need a hand adding your plant?", {
    title: "Need a hand adding your plant?",
    parts: [{ lead: "Your plant isn't added yet. It takes about a minute." }, ADD_STEPS,
      { button: { label: "Add your plant", href: APP } }, { small: "Stuck? Reply to this email and we'll help." }],
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

// SunSynk's own service is down: every plant is affected, not one inverter.
export const sunsynkDown = (plant: string, plantId: number, since: string, day = "today") =>
  make("SunSynk is down", {
    title: "SunSynk is down",
    parts: [
      { lead: "SunSynk isn't answering for anyone, so no readings come in." },
      { box: { hero: { label: "Down since", value: since, tone: "bad", sub: day } } },
      { button: openPage("live", plantId) },
    ],
    footer: ALERT_FOOTER("SunSynk", plant),
  });

export const sunsynkBack = (plant: string, plantId: number, since: string, at: string, lasted: string, day = "today") =>
  make("SunSynk is back", {
    title: "SunSynk is back",
    parts: [
      { box: { hero: { label: "SunSynk was down for", value: lasted, sub: `${since} to ${at} ${day}` } } },
      { button: openPage("live", plantId) },
    ],
    footer: ALERT_FOOTER("SunSynk", plant),
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
const rand = (n: number) => "R" + Math.round(n).toLocaleString("en-US");
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
export type PlantEvent =
  // from: set when the grid went off inside a gap in readings and the refill can't say
  // when (SOLAR-416): it went off between from and at
  | { kind: "grid_down"; at: string; from?: string; chargePct?: number }
  | { kind: "grid_back"; since: string; at: string; lasted?: string; chargePct?: number }
  | { kind: "batt_hot"; at: string; tempC: number; hotDays?: number } // hotDays: days over 45 C in the last 30, today included; counted from readings at send time
  | { kind: "bank_drift"; banks: { name: string; chargePct: number }[] } // name: the inverter's name in SunSynk
  | { kind: "string_dead"; string: string; inverter: string; since: string }
  | { kind: "string_back"; string: string; inverter: string; since: string; at: string; lasted: string }
  // inverters: every inverter on the plant with its last reading time ("08:15"), or null
  // while it still sends; listed so the owner sees which one stopped (SOLAR-415)
  | { kind: "logger_stale"; since: string; inverter?: string; inverters?: { name: string; last: string | null }[] }
  | { kind: "logger_back"; since: string; at: string; lasted: string; inverter?: string };
// batt_hot_back and bank_drift_back stay in the app's bell but send no email (SOLAR-415).

// day: "today", or the date when the alert reaches the owner on a later day
// ("Tue 21 Oct"), so a time is never read against the wrong day.
//
// Each alert shows its facts in the one box (SOLAR-415): the big number is what's wrong
// now (red or amber), or how long it lasted (white) once it's back. Rows only for other
// numbers. A sentence only where the box can't say it. Never a guessed cause, and never a
// promise to fill missed readings: we get what we can.
const PAGE: Record<PlantEvent["kind"], keyof typeof PAGES> = {
  grid_down: "grid", grid_back: "grid", batt_hot: "inverters", bank_drift: "inverters",
  string_dead: "inverters", string_back: "inverters", logger_stale: "live", logger_back: "live",
};
const WHAT: Record<PlantEvent["kind"], string> = {
  grid_down: "grid", grid_back: "grid", batt_hot: "battery", bank_drift: "battery",
  string_dead: "panel", string_back: "panel", logger_stale: "reading", logger_back: "reading",
};
// "Inverter 2508290475, string 2", as the app names it (SOLAR-348)
const ALERT_FOOTER = (what: string, plant: string) => SETTINGS_FOOTER(`You get ${what} alerts for ${esc(plant)}. Turn them off in notification settings.`);
const batt = (pct: number) => `<span style="color:${C.batt}">${pct}%</span>`;
const GAP = "We're getting what we can of the missed readings.";
export function plantEvent(plant: string, plantId: number, e: PlantEvent, day = "today"): Email {
  const span = (from: string, to: string) => `${from} to ${to} ${day}`;
  const [title, parts]: [string, Part[]] = (() => {
    switch (e.kind) {
      case "grid_down":
        return [`Grid down at ${plant}`, [{ box: { hero: { label: "Grid", value: "Off", tone: "bad", sub: e.from ? `went off between ${e.from} and ${e.at} ${day}` : `since ${e.at} ${day}` },
          rows: e.chargePct != null ? [["Battery", batt(e.chargePct)]] : [] } }]];
      case "grid_back":
        return [`Grid back at ${plant}`, [{ box: { hero: { label: "Grid was off for", value: e.lasted ?? "a while", sub: span(e.since, e.at) },
          rows: e.chargePct != null ? [["Battery", batt(e.chargePct)]] : [] } }]];
      case "batt_hot":
        return [`Battery hot at ${plant}`, [{ box: { hero: { label: "Battery", value: `${e.tempC}°C`, tone: "bad", sub: `at ${e.at} ${day}` },
          rows: (e.hotDays ?? 1) > 1 ? [["Over 45°C", `${e.hotDays} of the last 30 days`]] : [] } }]];
      case "bank_drift": {
        const pcts = e.banks.map((b) => b.chargePct);
        return [`Batteries charging unevenly at ${plant}`, [{ box: {
          hero: { label: "Gap", value: `${Math.max(...pcts) - Math.min(...pcts)}%`, tone: "warn", sub: "for over an hour" },
          rows: e.banks.map((b) => [b.name, batt(b.chargePct)] as [string, string]) } }]];
      }
      case "string_dead":
        return [`Panels stopped producing at ${plant}`, [{ box: { hero: { label: e.string, value: "No power", tone: "bad", sub: `since ${e.since} ${day}` },
          rows: [["Inverter", esc(e.inverter.replace(/^Inverter /, ""))], ["Other strings", "Producing"]] } }]];
      case "string_back":
        return [`Panels producing again at ${plant}`, [{ box: { hero: { label: `${e.string} was off for`, value: e.lasted, sub: span(e.since, e.at) },
          rows: [["Inverter", esc(e.inverter.replace(/^Inverter /, ""))]] } }]];
      case "logger_stale": {
        const one = !!e.inverter;
        const list = e.inverters?.length ? e.inverters : [{ name: e.inverter ?? "Inverter", last: e.since }];
        return [`No readings from ${plant}`, [
          { lead: one
            ? "SunSynk is working, but one inverter stopped sending it readings. Your power isn't affected. Only the app shows part of your plant."
            : "SunSynk is working, but your inverter stopped sending it readings. Your power isn't affected. Only the app stops updating." },
          { box: { hero: { label: "Last reading", value: e.since, tone: "warn", sub: day },
            rows: list.map((i) => [esc(i.name), i.last ? esc(i.last) : "Sending"] as [string, string]) } },
          { note: "We'll email you when readings come back, and get what we can of the gap." },
        ]];
      }
      case "logger_back":
        return [`Readings back at ${plant}`,
          [{ box: { hero: { label: "No readings for", value: e.lasted, sub: span(e.since, e.at) },
            rows: e.inverter ? [["Inverter", esc(e.inverter.replace(/^Inverter /, ""))]] : [] } }, { note: GAP }]];
    }
  })();
  return make(title, { title, parts: [...parts, { button: openPage(PAGE[e.kind], plantId) }], footer: ALERT_FOOTER(WHAT[e.kind], plant) });
}

// A SunSynk login stopped working (needs_relink) or works again (relinked), SOLAR-380.
// One email per login: it names every plant on it (0158).
//  at      when it stopped / came back, HH:MM; since: when it stopped (relinked)
export type LoginEvent =
  | { kind: "needs_relink"; plants: string[]; at?: string }
  | { kind: "relinked"; plants: string[]; since?: string; at: string; lasted: string }
  // the owner removed the plant's share to our login (SOLAR-310, 0172)
  | { kind: "share_removed"; plants: string[] };
// up to 3 names, then a count, as the app's billing banner
const andList = (a: string[]) => names(a.length > 3 ? [...a.slice(0, 3), `${a.length - 3} more`] : a);
export function loginEvent(e: LoginEvent, plantId: number, day = "today"): Email {
  const plants = andList(e.plants.length ? e.plants : ["your plant"]);
  // A calm note, no red (SOLAR-383). No switch for these, so no "turn them off" line.
  if (e.kind === "needs_relink")
    return make(`Sign in to SunSynk again for ${plants}`, {
      title: "Sign in to SunSynk again",
      parts: [
        { lead: "SunSynk asked for your login again." },
        { box: { hero: e.at ? { label: "No readings since", value: e.at, sub: day } : undefined, rows: [["Plants", esc(plants)]] } },
        { lead: "After you sign in, we get what we can of the missed readings." },
        { button: { label: "Sign in to SunSynk", href: LOGINS } },
      ],
      footer: [HELP],
    });
  if (e.kind === "share_removed")
    return make(`Sharing stopped for ${plants}`, {
      title: "Sharing stopped",
      parts: [
        { lead: "Your plant is no longer shared with admin@princesolarhub.co.za in SunSynk, so we stopped reading it. Your history is safe." },
        { box: { rows: [["Plants", esc(plants)]] } },
        { lead: "To start again, share it as Visitor, then add it in the app with Share plant." },
        { button: { label: "Open Prince Solar Hub", href: LOGINS } },
      ],
      footer: [HELP],
    });
  return make(`SunSynk reconnected for ${plants}`, {
    title: "SunSynk reconnected",
    parts: [
      { box: { hero: { label: "No readings for", value: e.lasted, sub: e.since ? `${e.since} to ${e.at} ${day}` : `until ${e.at} ${day}` },
        rows: [["Plants", esc(plants)]] } },
      { note: GAP },
      { button: openPage("live", plantId) },
    ],
    footer: [HELP],
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
// After a paid plan ends, said the same way in every email (SOLAR-329, 0146; SOLAR-415).
const PAID_FREE = "On Free, one plant updates and you see only the last 24 hours. We keep your history for 30 days in case you come back. Reports stop.";
const PLAN_NAME = { free: "Free", home: "Home", family: "Family" } as const;
// How many plants each plan keeps (SOLAR-371): said when plants are deleted.
const PLAN_PLANTS = { free: "one plant", home: "2 plants", family: "5 plants" } as const;
// Who is selling: on every billing email (SOLAR-415).
const SELLER = "Prince Solar Hub is run by Theron and Prince Solutions (Pty) Ltd, reg. no. 2026/182827/07, Kempton Park, Gauteng. No VAT is charged.";
const BILL_FOOTER = [HELP, SELLER];
export type Plan = keyof typeof PLAN_NAME;
export type BillPeriod = "monthly" | "yearly";
const names = (list: string[]) => list.length < 2 ? list.join("") : `${list.slice(0, -1).join(", ")} and ${list[list.length - 1]}`;
const list = (a: string[]) => esc(a.join(", "));
const SEE_PLAN = { button: { label: "See your plan", href: PLAN } };
const CANCEL_BUTTON = { button: { label: "Cancel plan", href: CANCEL } };
const PAY_BUTTON = (url: string) => ({ button: { label: "Pay with another card", href: url } });

// Billing wording (SOLAR-415): short, names the plan, date and amount, and never explains
// what the owner just did themselves. Amounts sit in the box, not in the title, except
// in a subject, where the inbox shows them.
export type Receipt = {
  plan: Plan; period: BillPeriod; amount: number; date: string; // "1 Nov 2026"
  card: string; // "Visa •••• 4081"
  reference: string; // Paystack reference
  covers?: string; // the days this payment pays for: "1 to 30 Nov"
  extraPlants?: { n: number; each: number }; // old plans only; extra plants left pricing (SOLAR-371)
  next: { amount: number; date: string };
};

export const paymentReceived = (r: Receipt) =>
  make(`Payment received: ${rand(r.amount)}`, {
    title: "Payment received",
    parts: [
      { box: { hero: { label: "Paid", value: rand(r.amount), sub: r.date },
        rows: [["For", esc(`${PLAN_NAME[r.plan]}${r.covers ? `, ${r.covers}` : `, ${r.period}`}`)], ["Card", esc(r.card)],
          ["Reference", esc(r.reference)], ["Next payment", `${rand(r.next.amount)} on ${r.next.date}`]] } },
      SEE_PLAN,
    ],
    footer: BILL_FOOTER,
  });

// Yearly plans: notice 40 to 80 business days before the renewal (Consumer Protection
// Act s14, if a yearly plan counts as fixed-term; to confirm on SOLAR-104).
export type Renewal = { plan: Plan; amount: number; on: string; card?: string; change?: string };

export const renewalNotice = (r: Renewal) =>
  make(`Your yearly ${PLAN_NAME[r.plan]} plan renews on ${r.on}`, {
    title: `Your ${PLAN_NAME[r.plan]} plan renews on ${r.on}`,
    parts: [
      ...(r.change ? [{ lead: esc(r.change) }] : []),
      { box: { hero: { label: "We charge", value: rand(r.amount), sub: `on ${r.on}` }, rows: r.card ? [["Card", esc(r.card)]] : [] } },
      { note: `To stop it, cancel before ${r.on}.` },
      CANCEL_BUTTON,
    ],
    footer: BILL_FOOTER,
  });

// An offer price that lasts some months ends: sent up to 30 days before the first charge
// at the usual price (SOLAR-330).
export type OfferEnds = { plan: Plan; period: BillPeriod; was: number; amount: number; on: string; card?: string };
export const offerEnds = (o: OfferEnds) => {
  const per = o.period === "yearly" ? "a year" : "a month";
  return make(`${PLAN_NAME[o.plan]} goes to ${rand(o.amount)} ${per} on ${o.on}`, {
    title: `Your offer price ends on ${o.on}`,
    parts: [
      { box: { hero: { label: `From ${o.on}`, value: rand(o.amount), sub: `${per}, was ${rand(o.was)}` }, rows: o.card ? [["Card", esc(o.card)]] : [] } },
      { note: `To stop it, cancel before ${o.on}.` },
      CANCEL_BUTTON,
    ],
    footer: BILL_FOOTER,
  });
};

// An upgrade starts at once: the difference for the days left is charged now, the
// billing date stays (SOLAR-208).
export type Upgrade = {
  from: Plan; to: Plan; period: BillPeriod;
  addedPlants?: number; // extra plants on Family: no email since SOLAR-371 (notify skips it)
  paidNow: number; daysLeft: number;
  card?: string;
  credit?: number; // Home monthly to Family yearly (SOLAR-364): what the rest of the month came to
  next: { amount: number; date: string };
};

export const planUpgraded = (u: Upgrade) =>
  make(`You're on ${PLAN_NAME[u.to]}`, {
    title: `You're on ${PLAN_NAME[u.to]}`,
    parts: [
      { box: { hero: { label: "Paid today", value: rand(u.paidNow),
          sub: u.credit != null ? `${rand(u.credit)} off for the rest of your month` : `for the rest of this ${u.period === "yearly" ? "year" : "month"}` },
        rows: [...(u.card ? [["Card", esc(u.card)] as [string, string]] : []), ["Next payment", `${rand(u.next.amount)} on ${u.next.date}`]] } },
      u.to === "family" ? { button: { label: "Add a plant", href: LOGINS } } : SEE_PLAN,
    ],
    footer: BILL_FOOTER,
  });

// Monthly to yearly on the same plan is paid now (SOLAR-298). The month paid runs out;
// the year starts on the billing date, so the next payment is a year after it.
export type Switched = Receipt & { startsOn: string };

export const planSwitched = (s: Switched) =>
  make(`Your yearly plan starts on ${s.startsOn}`, {
    title: "You're on yearly",
    parts: [
      { box: { hero: { label: "Paid today", value: rand(s.amount), sub: s.date },
        rows: [["For", esc(`${PLAN_NAME[s.plan]}, ${s.covers ?? `from ${s.startsOn}`}`)], ["Card", esc(s.card)], ["Reference", esc(s.reference)]] } },
      SEE_PLAN,
    ],
    footer: BILL_FOOTER,
  });

// Downgrade, cancel (to Free) and a monthly/yearly switch all wait for the billing
// date. Sent when booked; the plants named are deleted on deleteOn (SOLAR-295), or on
// that date when no deleteOn is given.
export type Change = {
  from: Plan; to: Plan; fromPeriod: BillPeriod; toPeriod?: BillPeriod;
  on: string; // the billing date
  removePlants: string[];
  keepPlants?: string[];
  deleteOn?: string;
  next?: { amount: number }; // absent on Free
  days?: number; // day totals the plants to delete hold between them
  history?: { plant: string; days: number; on: string }; // cancel: the first plant's history, deleted 30 days after
};

export const planChangeBooked = (c: Change) => {
  const cancel = c.to === "free";
  const switchOnly = c.from === c.to;
  const title = cancel ? `${PLAN_NAME[c.from]} ends on ${c.on}` : switchOnly ? `${PLAN_NAME[c.from]} goes ${c.toPeriod} on ${c.on}` : `You move to ${PLAN_NAME[c.to]} on ${c.on}`;
  // Plants to delete lead, in amber, as in the later "deleted on" email (SOLAR-415).
  const hero = c.removePlants.length
    ? lost(`Deleted on ${c.deleteOn ?? c.on}`, plantCount(c.removePlants.length), withDays(names(c.removePlants), c.days)) : undefined;
  const kept: [string, string][] = hero && c.keepPlants?.length ? [["Plants kept", list(c.keepPlants)]] : [];
  const keep = { button: { label: `Keep ${PLAN_NAME[c.from]}`, href: PLAN } };
  return make(title, {
    title,
    parts: cancel
      ? hero ? [{ lead: `Nothing more is charged. ${PAID_FREE}` }, { box: { hero, rows: kept } }, keep]
        // No plant deleted: the history that goes leads instead, as in the plan-ended email.
        : c.history?.days ? [{ lead: "Nothing more is charged." },
            { box: { hero: lost(`Deleted on ${c.history.on}`, dayCount(c.history.days), `of history at ${c.history.plant}`),
              rows: [[`After ${c.on}`, "Last 24 hours"], ["Reports", "Stop"]] } }, keep]
        : [{ lead: `Nothing more is charged. ${PAID_FREE}` }, keep]
      // A monthly/yearly switch reads like the plan-kept email: what carries on, then the price.
      : switchOnly ? [{ lead: "Your plants, history and reports carry on as before." },
          { box: { rows: [["Next payment", `${c.next ? rand(c.next.amount) : "R0"} on ${c.on}`]] } },
          { button: { label: `Keep ${c.fromPeriod}`, href: PLAN } }]
      : [{ box: { hero, rows: [["Next payment", `${c.next ? rand(c.next.amount) : "R0"} on ${c.on}`], ...kept] } },
         hero ? keep : SEE_PLAN],
    footer: BILL_FOOTER,
  });
};

// Keep: a booked change undone, so the plan carries on as it is (SOLAR-271). undone: the
// change that was booked, read from its bill_change email; the title names it.
export type Kept = { plan: Plan; period: BillPeriod; next: { amount: number; date: string }; undone?: { to: Plan; toPeriod?: BillPeriod } };

export const planKept = (k: Kept) => {
  // Warm, not loud (SOLAR-415): a cancel or downgrade undone says what carries on. Undoing
  // a monthly/yearly switch changes nothing they'd notice, so it just says so.
  const u = k.undone;
  const periodOnly = !!u && u.to === k.plan;
  const title = periodOnly ? `${PLAN_NAME[k.plan]} stays ${k.period}` : `Good to have you on ${PLAN_NAME[k.plan]}`;
  const lead = periodOnly ? null : u && u.to !== "free" ? "Your plants, history and reports carry on as before." : "Your history and reports carry on as before.";
  return make(title, {
    title,
    parts: [...(lead ? [{ lead }] : []), { box: { rows: [["Next payment", `${rand(k.next.amount)} on ${k.next.date}`]] } }, SEE_PLAN],
    footer: BILL_FOOTER,
  });
};

// A failed charge is retried on day 1, 3 and 7 after the billing date. The first email
// goes as soon as the billing-day charge fails; each retry that fails sends another.
export type Failed = {
  plan: Plan; period: BillPeriod; amount: number; card: string;
  nextTry?: string; // absent after the last try
  freeOn: string; // the day the account moves to Free if it stays unpaid
  payUrl: string;
  disputed?: string; // the bank took a payment back (a lost dispute, 0130): the day it was paid
};

// The shared layout (SOLAR-415): the amount big with what it was for, facts as rows
// (card, next try, the day Free starts), one line on what to do, the button, then what
// Free means in small print.
export const paymentFailed = (f: Failed) => {
  const plan = PLAN_NAME[f.plan];
  return make(f.disputed ? "Your bank reversed a payment" : `Your payment of ${rand(f.amount)} didn't go through`, {
    title: f.disputed ? "Your bank reversed a payment" : "Your payment didn't go through",
    parts: [
      { box: { hero: f.disputed
          ? { label: "Reversed", value: rand(f.amount), tone: "bad", sub: `for ${plan}, paid on ${f.disputed}` }
          : { label: "Declined", value: rand(f.amount), tone: "bad", sub: `for ${plan}` },
        rows: [["Card", esc(f.card)], ...(f.nextTry ? [["Next try", f.nextTry] as [string, string]] : []), ["Free from", f.freeOn]] } },
      { lead: `${f.nextTry ? "" : "That was the last try. "}Pay before ${f.freeOn} to keep ${plan}.` },
      PAY_BUTTON(f.payUrl),
      { small: PAID_FREE },
    ],
    footer: BILL_FOOTER,
  });
};

// A payment we refund (0130): it applied nothing, because the plan or the price changed
// while the user paid. Or one refunded by hand in Paystack (why "hand", SOLAR-444, 0171),
// all or part of it: the plan stays. Not sent for the R1 card check.
// card: the card on file, which the refund goes back to. 3 to 10 working days is
// Paystack's own figure for card refunds in South Africa; Paystack emails them too.
// paid: what the payment was, for a hand refund; a part refund shows it.
export type Refund = { amount: number; date: string; reference: string; why: "price" | "changed" | "hand"; paid?: number; card?: string };

// A hand refund can be part of a rand: R40.50 stays R40.50.
const refundRand = (n: number) => Number.isInteger(n) ? rand(n) : "R" + n.toFixed(2);
export const paymentRefunded = (r: Refund) => {
  const part = r.why === "hand" && r.paid != null && r.amount < r.paid;
  return make(`${refundRand(r.amount)} is on its way back to your card`, {
    title: "Your refund is on its way",
    parts: [
      { lead: r.why === "price" ? "The price changed while you paid, so we sent it back."
        : r.why === "hand" ? `We refunded ${part ? "part of " : ""}your payment. Your plan stays as it is.`
        : "Your plan changed while you paid, so we sent it back." },
      { box: { hero: { label: "Refund", value: refundRand(r.amount), sub: r.card ? `back to ${r.card}` : "back to your card" },
        rows: [...(part ? [["Payment", rand(r.paid!)] as [string, string]] : []),
          ["Paid on", r.date], ["Arrives in", "3 to 10 working days"], ["Reference", esc(r.reference)]] } },
      SEE_PLAN,
      { small: "Paystack, who handles our payments, emails you about it too." },
    ],
    footer: BILL_FOOTER,
  });
};

// After a card change (the R1 card check, SOLAR-406, 0161): the new card, the one it
// replaced (left out when the same card is saved again), when, and the next payment (left
// out once a cancel is booked); then the password-reset line, so a change they didn't
// make shows up. No switch turns it off.
export type CardChange = { card: string; was?: string; at?: string; next?: { amount: number; date: string } };
export const cardChanged = (c: CardChange) =>
  make("Your card was changed", {
    title: "Your card was changed",
    parts: [
      { box: { rows: [["New card", esc(c.card)], ...(c.was ? [["Replaces", esc(c.was)] as [string, string]] : []),
        ...(c.at ? [["Changed", esc(c.at)] as [string, string]] : []),
        ...(c.next ? [["Next payment", `${rand(c.next.amount)} on ${c.next.date}`] as [string, string]] : [])] } },
      { lead: "The R1 card check is paid back. Wasn't you? Reset your password." },
      RESET,
    ],
    footer: BILL_FOOTER,
  });

// The saved card's last day (end of its expiry month) falls before the next payment
// (SOLAR-406, 0161): 30 days before, then a last reminder 7 days before. A card first
// seen 7 days or less before gets one email, not called a last reminder.
export type CardExpiry = { card: string; on: string; final?: boolean; next: { amount: number; date: string } };
export const cardExpiring = (c: CardExpiry) => {
  const title = `${c.final ? "Last reminder: your" : "Your"} card expires on ${c.on}`;
  return make(c.final ? title : `Your ${c.card} expires on ${c.on}`, {
    title: c.final ? title : `Your card expires on ${c.on}`,
    parts: [
      { box: { rows: [["Card", esc(c.card)], ["Next payment", `${rand(c.next.amount)} on ${c.next.date}`]] } },
      { lead: "Update it before your next payment." },
      { button: { label: "Update card", href: PLAN } },
    ],
    footer: BILL_FOOTER,
  });
};

// To hello@ (Brynne): a bill email failed after its last try, so the user never heard.
export const billMailFailed = (m: { kind: string; key: string; user: string; error: string }) =>
  make(`Bill email not sent: ${m.kind}`, {
    title: "A bill email was not sent",
    parts: [{ box: { rows: [["Email", esc(m.kind)], ["Key", esc(m.key)], ["User", esc(m.user)], ["Error", esc(m.error)]] } }],
    footer: [],
  });

// Emails where the owner loses something: a big amber number for what goes and when,
// then the plan that keeps it at today's price (SOLAR-415).
// Price: the live offer's monthly price, and the usual price when the offer is lower.
export type Price = { plan: Plan; now: number; list: number };
const keepOn = (p: Price, what: string) =>
  `Keep ${what} on ${PLAN_NAME[p.plan]} for ${rand(p.now)} a month${p.now < p.list ? ", the launch price" : ""}.`;
const keepSmall = (p: Price) => `${p.now < p.list ? `${PLAN_NAME[p.plan]} is normally ${rand(p.list)} a month. ` : ""}Cancel any time.`;
const dayCount = (n: number) => `${n} day${n === 1 ? "" : "s"}`;
const plantCount = (n: number) => `${n} plant${n === 1 ? "" : "s"}`;
const lost = (label: string, value: string, sub: string): Hero => ({ label, value, tone: "warn", sub });
const withDays = (who: string, days?: number) => days ? `${who}, with ${dayCount(days)} of history` : who;

// Unpaid after the last try: the account is on Free. The first-linked plant stays
// live; the others stop updating and are deleted after 30 days, unless paid for or
// swapped for the one kept. days: history the kept plant holds.
// No offer price here: the line above names what they were paying.
// stoppedDays: day totals the stopped plants hold between them.
export type MovedToFree = { from: Plan; kept: string; stopped: string[]; deleteOn: string; amount?: number; days?: number; stoppedDays?: number };

export const movedToFree = (m: MovedToFree) =>
  make("You're now on Free", {
    title: "You're now on Free",
    parts: [
      { lead: `We couldn't charge ${m.amount != null ? rand(m.amount) : "your card"} for ${PLAN_NAME[m.from]}.` },
      { box: {
        hero: m.stopped.length ? lost(`Deleted on ${m.deleteOn}`, plantCount(m.stopped.length), withDays(names(m.stopped), m.stoppedDays))
          : m.days ? lost(`Deleted on ${m.deleteOn}`, dayCount(m.days), `of history at ${m.kept}`) : undefined,
        rows: [...(m.stopped.length ? [["Still updating", esc(m.kept)] as [string, string]] : []),
          ["You see", "Last 24 hours"], ["Reports", "Stop"]],
      } },
      { button: { label: `Pay for ${PLAN_NAME[m.from]}`, href: PLANS } },
    ],
    footer: BILL_FOOTER,
  });

// Once, when a cancelled plan ends on its date (SOLAR-328, 0144). History is kept 30
// days after (SOLAR-329). days: history the first plant holds.
export const winback = (w: { from: Plan; keepUntil: string; plant?: string; days?: number; price?: Price }) =>
  make(`Your ${PLAN_NAME[w.from]} plan has ended`, {
    title: `Your ${PLAN_NAME[w.from]} plan has ended`,
    parts: [
      { box: {
        hero: w.days && w.plant ? lost(`Deleted on ${w.keepUntil}`, dayCount(w.days), `of history at ${w.plant}`) : undefined,
        rows: [...(w.days && w.plant ? [] : [["History deleted on", w.keepUntil] as [string, string]]),
          ["You see", "Last 24 hours"], ["Reports", "Stopped"]],
      } },
      ...(w.price ? [{ lead: keepOn(w.price, "your history") }] : []),
      { button: { label: "Keep my history", href: PLANS } },
      ...(w.price ? [{ small: keepSmall(w.price) }] : []),
    ],
    footer: [HELP],
  });

// 3 days before plants are deleted (after a downgrade, cancel or failed payment). plan:
// the plan the account is on now, to say how many plants it keeps. price: the next plan
// up, which keeps them. days: day totals the plants hold between them.
export const plantsRemovalSoon = (plants: string[], on: string, plan?: Plan, price?: Price, days?: number) => {
  const title = `${plants.length > 2 ? `${plants.length} plants` : names(plants)} ${plants.length === 1 ? "is" : "are"} deleted on ${on}`;
  const them = plants.length === 1 ? "it" : "them";
  return make(title, {
    title,
    parts: [
      { box: { hero: lost(`Deleted on ${on}`, plantCount(plants.length), withDays(names(plants), days)) } },
      { lead: `${plan ? `${PLAN_NAME[plan]} keeps ${PLAN_PLANTS[plan]}. ` : ""}${price ? keepOn(price, them) : `Choose a plan to keep ${them}.`}` },
      { button: { label: plants.length === 1 ? "Keep my plant" : "Keep my plants", href: PLANS } },
      ...(price ? [{ small: keepSmall(price) }] : []),
    ],
    footer: BILL_FOOTER,
  });
};

// Two days before a Free account's first week ends (SOLAR-242): what goes. The day-7
// report says it again. endsOn: "Monday 10 Nov". days: day totals the plant holds; 0
// when unknown.
export const freeWeekEndsSoon = (endsOn: string, plant: string, days: number, price?: Price) => {
  const wd = endsOn.split(" ")[0];
  return make(`Your free week ends on ${endsOn}`, {
    title: `Your free week ends on ${endsOn}`,
    parts: [
      { box: {
        hero: days > 0 ? lost(`Deleted on ${wd}`, dayCount(days), `of history at ${plant}`) : undefined,
        rows: [[`After ${wd}`, "Last 24 hours"], ["Reports", "Stop"]],
      } },
      { lead: price ? keepOn(price, "everything") : "A plan keeps it all." },
      { button: { label: "Keep my history", href: PLANS } },
      ...(price ? [{ small: keepSmall(price) }] : []),
    ],
    footer: BILL_FOOTER,
  });
};

// Two days after the account's first plant, once, while a number is still empty (0163):
// a checklist. Sign up and Add plant are done by then; each number is ticked when set.
// A plant without a battery isn't asked for battery size or reserve, so those go.
export type SetupStep = "rate" | "size" | "reserve" | "panels";
// Same names as the app's setup card (app.jsx STEPS, STEPS_DONE): what each number shows
// in the app, then where to find it.
const SETUP_WHERE: Record<SetupStep, [string, string, string]> = {
  rate: ["Electricity rate", "Shows what solar saved you, in rand.", "Use the price per unit on your bill, with VAT."],
  size: ["Battery size", "Shows how long your battery will last.", "Add up all your batteries, from their labels."],
  reserve: ["Battery reserve", "Shows how long until the battery stops powering your home.", "Use the number set on your inverter."],
  panels: ["Solar panels", "Shows how much your panels make against what they can.", "Add up their watts, from your installer's invoice."],
};
const BATTERY_STEPS: SetupStep[] = ["size", "reserve"];
const COUNT = ["", "One number is", "Two numbers are", "Three numbers are", "Four numbers are"];
export const freeWeekSetup = (steps: SetupStep[], plantId?: number, battery = true) => {
  const all = (Object.keys(SETUP_WHERE) as SetupStep[]).filter((s) => battery || !BATTERY_STEPS.includes(s));
  const left = steps.filter((s) => all.includes(s));
  const checks = [
    { name: "Sign up", done: true }, { name: "Add plant", done: true },
    ...all.map((s) => left.includes(s)
      ? { name: SETUP_WHERE[s][0], text: SETUP_WHERE[s][1], sub: SETUP_WHERE[s][2] }
      : { name: SETUP_WHERE[s][0], done: true }),
  ];
  return make("Finish your setup", {
    title: "Finish your setup",
    parts: [
      { lead: `${COUNT[left.length] ?? `${left.length} numbers are`} still empty. Each one turns on part of the app.` },
      { box: { checks } },
      { button: { label: "Finish setup", href: plantId ? `${SYSTEM}&plant=${plantId}` : SYSTEM } },
    ],
    footer: [HELP],
  });
};
