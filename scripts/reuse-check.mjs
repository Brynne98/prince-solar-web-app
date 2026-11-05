#!/usr/bin/env node
/**
 * Keeps the app on its own components (see COMPONENTS.md). Run by `npm test`; exit 1 on a finding.
 *
 *  1. Dead CSS: a class in index.html's <style> that no .jsx, .js or .html under public/ uses.
 *     Classes the code builds at run time ('status-' + s.status) count as used by their prefix.
 *  2. Rebuilt components: markup or helpers that already exist in the shared set, made again.
 *  3. One global scope: every public/*.jsx shares it, so a second top-level `function x` or
 *     `const x` silently replaces the first. Two files may not declare the same name.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const PUB = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');
const read = (f) => fs.readFileSync(path.join(PUB, f), 'utf8');
const src = fs.readdirSync(PUB).filter(f => /\.(jsx|js|html)$/.test(f) && f !== 'sw.js');
const jsx = src.filter(f => f.endsWith('.jsx'));
const problems = [];

// ---- 1. dead CSS ----
const html = read('index.html');
const styleStart = html.indexOf('<style>'), styleEnd = html.indexOf('</style>');
const css = html.slice(styleStart, styleEnd).replace(/\/\*[\s\S]*?\*\//g, (c) => c.replace(/[^\n]/g, ' '));
const corpus = src.map(f => f === 'index.html' ? html.slice(0, styleStart) + html.slice(styleEnd) : read(f)).join('\n');
const used = new Set(corpus.match(/[A-Za-z_][\w-]*/g));
const prefixes = [...corpus.matchAll(/([a-z][\w-]*-)['"`]\s*\+|([a-z][\w-]*-)\$\{/g)].map(m => m[1] || m[2]);
const lineOf = (i) => css.slice(0, i).split('\n').length + html.slice(0, styleStart).split('\n').length - 1;
const dead = new Map();
for (const m of css.matchAll(/([^{}]+)\{/g)) {
  const sel = m[1];
  if (/^\s*@/.test(sel) || /^\s*(from|to|\d+%)/.test(sel)) continue;
  for (const c of sel.matchAll(/\.([A-Za-z_][\w-]*)/g)) {
    const name = c[1];
    if (used.has(name) || prefixes.some(p => name.startsWith(p))) continue;
    if (!dead.has(name)) dead.set(name, lineOf(m.index + sel.search(/\S/)));
  }
}
for (const [name, line] of dead) problems.push(`index.html:${line} .${name} is not used anywhere: delete the rule`);

// ---- 2. rebuilt components ----
const rules = [
  [/<select\b/, 'a native <select>: use PickMenu (app.jsx)'],
  [/type=["']date["']/, 'a native date input: use DayField (tabs.jsx) or CalendarPop (chart.jsx)'],
  [/<input[^>]*type=["']checkbox["']/, 'a checkbox: use Switch or Toggle (components.jsx)'],
  [/<[a-z][\w-]*\s[^>]*\stitle=["{]/, 'a title= tooltip on an element: use Tip (components.jsx)'],
  [/className=["']skel["']/, 'a raw .skel: use Skeleton (components.jsx)'],
  [/toLocaleDateString\(['"]en-CA['"]\)/, 'a hand-made YYYY-MM-DD: use localDateStr or shiftDate (components.jsx)', 'components.jsx'],
  [/window\.confirm\(|[^.\w]confirm\(['"`]/, 'the browser confirm(): use ConfirmCard (tabs.jsx)'],
  [/window\.alert\(|[^.\w]alert\(['"`]/, 'the browser alert(): use toast (app.jsx)'],
  [/className=["']tip-row["']/, 'a hand-made tooltip row: use TipRow (components.jsx)', 'components.jsx'],
  [/className=\{?["']meter\b/, 'a hand-made progress bar: use Meter (components.jsx)', 'components.jsx'],
  [/className=["']login-card["']/, 'a hand-made sign-in card: use AuthCard (auth.jsx)', 'auth.jsx'],
  [/Promise\.race\(/, 'a hand-made timeout: use withTimeout (link.jsx)', 'link.jsx'],
  [/getItem\(['"]synsynk\.tab/, 'reading the saved tab by hand: use savedTab (app.jsx)', 'app.jsx'],
];
const icons = [...read('app.jsx').matchAll(/^\s+\w+: '(<path d="[^"]+"\/>)/gm)].map(m => m[1].match(/d="([^"]+)"/)[1]);
for (const f of jsx) {
  read(f).split('\n').forEach((line, i) => {
    if (/reuse-check: allow/.test(line) || /^\s*(\/\/|\*|\/\*)/.test(line)) return;
    for (const [re, why, home] of rules) if (f !== home && re.test(line)) problems.push(`${f}:${i + 1} ${why}`);
    if (f !== 'app.jsx' || !/^\s+\w+: '<path/.test(line))
      for (const d of icons) if (line.includes(`d="${d}"`)) problems.push(`${f}:${i + 1} an icon NAV_ICONS already has: use <Icon id=…> (app.jsx)`);
  });
}

// ---- 2b. one type scale (SOLAR-344) ----
// Every font size in index.html is a --fs-* token. A px size outside :root, clamp() or calc() is a new step.
for (const m of css.matchAll(/font(?:-size)?:[^;{}]*?(?<![\w(-])(\d+(?:\.\d+)?)px/g)) {
  if (/clamp\(/.test(m[0])) continue;
  problems.push(`index.html:${lineOf(m.index)} font size ${m[1]}px: use a --fs-* token`);
}

// ---- 2c. one spacing and corner scale (SOLAR-345) ----
// Paddings, margins and gaps up to 40px are --sp-* tokens; corners are --r-* (or 50%).
// 0 and 1px (hairline nudges) pass; bigger offsets match another element's size and stay px.
for (const m of css.matchAll(/(?<![\w-])(padding|margin|gap|row-gap|column-gap|border(?:-[a-z]+)*-radius)(?:-[a-z]+)?\s*:([^;{}]*)/g)) {
  const val = m[2].replace(/clamp\([^)]*\)/g, '');
  for (const n of val.matchAll(/(\d+(?:\.\d+)?)px/g)) {
    const v = Number(n[1]);
    if (v <= 1 || (v > 40 && !/radius/.test(m[1]))) continue;
    problems.push(`index.html:${lineOf(m.index)} ${m[1]} ${v}px: use a --${/radius/.test(m[1]) ? 'r' : 'sp'}-* token`);
  }
}

// ---- 2d. one meaning per colour (SOLAR-346) ----
// The five power colours and the role colours (ok, warn, bad, accent) live on :root only.
// Elsewhere a hex or rgb() of one is a second copy that drifts: use var(--x) or
// rgba(var(--x-rgb), a). A focus, open or picked state takes --focus, never a power colour.
const ROLE_HEX = /#(3ddc84|a78bfa|facc15|f87171|22d3ee|60a5fa|f97316|f43f5e|f59e0b|ef4444)\b/i;
const ROLE_RGB = /rgba?\(\s*(61,\s*220,\s*132|167,\s*139,\s*250|250,\s*204,\s*21|248,\s*113,\s*113|34,\s*211,\s*238|96,\s*165,\s*250|249,\s*115,\s*22|244,\s*63,\s*94|245,\s*158,\s*11|239,\s*68,\s*68)\b/;
for (const m of css.matchAll(/([^{}]*)\{([^{}]*)\}/g)) {
  for (const d of m[2].matchAll(/([\w-]+)\s*:([^;]*)/g)) {
    if (d[1].startsWith('--') || /url\(/.test(d[2])) continue;
    const at = lineOf(m.index + m[1].length + 1 + d.index);
    if (ROLE_HEX.test(d[2]) || ROLE_RGB.test(d[2])) problems.push(`index.html:${at} a raw power or status colour: use var(--…) from :root`);
    if (/:focus|\.open\b|\[aria-expanded|\.on\b/.test(m[1]) && /(border|outline)/.test(d[1]) && /var\(--(pv|batt|grid|load|soc)\)/.test(d[2]))
      problems.push(`index.html:${at} a power colour marks focus or a pick: use var(--focus)`);
  }
}
for (const f of jsx) {
  read(f).split('\n').forEach((line, i) => {
    if (/reuse-check: allow/.test(line) || /^\s*(\/\/|\*|\/\*)/.test(line) || f === 'components.jsx' && /^\s+(pv|batt|grid|load|soc):/.test(line)) return;
    if (ROLE_HEX.test(line) || ROLE_RGB.test(line)) problems.push(`${f}:${i + 1} a raw power or status colour: use window.COLORS or var(--…)`);
  });
}

// Emails can't read CSS variables, so email.ts keeps its own copy: it must match :root.
const mail = fs.readFileSync(path.join(PUB, '..', 'supabase', 'functions', '_shared', 'email.ts'), 'utf8');
for (const [k, v] of [['pv', 'solar'], ['load', 'home'], ['grid', 'grid'], ['soc', 'cyan'], ['batt', 'batt'], ['ok', 'ok'], ['warn', 'warn'], ['bad', 'bad'], ['accent', 'ACCENT']]) {
  const app = css.match(new RegExp('--' + k + ':\\s*(#[0-9a-f]{6})', 'i'))?.[1];
  const em = mail.match(new RegExp('\\b' + v + '(?::| =)\\s*"(#[0-9a-f]{6})"', 'i'))?.[1];
  if (!app || !em || app.toLowerCase() !== em.toLowerCase()) problems.push(`email.ts ${v} is ${em ?? 'missing'}, index.html --${k} is ${app ?? 'missing'}: keep them the same`);
}

// ---- 2e. one focus ring (SOLAR-343) ----
// :root's `:focus-visible` draws the only ring: 2px in --focus. A focus rule may move it
// (offset, radius) but not hide it or recolour it. Text fields mark focus with a --focus
// border instead, so input/.input/.fs-in/.fs-cnt/.pop-dlg rules may drop the outline.
for (const m of css.matchAll(/([^{}]*)\{([^{}]*)\}/g)) {
  const sel = m[1].trim();
  if (!/:focus/.test(sel) || sel === ':focus:not(:focus-visible)') continue;
  const at = lineOf(m.index + m[1].length);
  const o = m[2].match(/(?<![\w-])outline\s*:([^;]*)/)?.[1].trim();
  const field = /input|\.input|\.fs-in|\.fs-cnt|\.pop-dlg|textarea/.test(sel);
  if (o && /^(none|0)$/.test(o) && !field) problems.push(`index.html:${at} outline: none on focus: keyboard users lose the ring`);
  if (o && !/^(none|0)$/.test(o) && !/var\(--focus\)/.test(o)) problems.push(`index.html:${at} a focus ring not in var(--focus)`);
  if (/outline-color\s*:(?![^;]*var\(--focus\))/.test(m[2])) problems.push(`index.html:${at} a focus ring not in var(--focus)`);
}
// An email's backup link says where it goes, not "Click here".
for (const f of [path.join(PUB, '..', 'supabase', 'functions', '_shared', 'email.ts'), ...fs.readdirSync(path.join(PUB, '..', 'supabase', 'templates')).map(t => path.join(PUB, '..', 'supabase', 'templates', t))])
  if (/>\s*click here\s*</i.test(fs.readFileSync(f, 'utf8'))) problems.push(`${path.basename(f)}: a link reads "Click here"; name where it goes`);

// ---- 2f. one icon line and three icon sizes (SOLAR-349) ----
// Icons are svg.ico: line var(--icon-stroke) in screen px (.ico * is non-scaling), size
// var(--icon-sm|md|lg). Charts, pies, the setup progress ring and the power-flow lines are
// drawings, not icons, and keep their own lines.
const NOT_ICON = /chart-svg|\.pie\b|fs-mini|pflow-lane|mflow-inv/;
for (const m of css.matchAll(/([^{}]*)\{([^{}]*)\}/g)) {
  const sel = m[1].trim();
  if (!/\.ico\b|(^|[\s>+~,(])svg\b/.test(sel) || NOT_ICON.test(sel)) continue;
  for (const d of m[2].matchAll(/(?<![\w-])(width|height|stroke-width)\s*:([^;]*)/g)) {
    const v = d[2].trim();
    const ok = d[1] === 'stroke-width' ? v === 'var(--icon-stroke)' : /^var\(--icon-(sm|md|lg)\)$|^1em$/.test(v);
    if (!ok) problems.push(`index.html:${lineOf(m.index + m[1].length + 1 + d.index)} icon ${d[1]} ${v}: use var(--icon-${d[1] === 'stroke-width' ? 'stroke' : 'sm|md|lg'})`);
  }
}
// An icon drawn in a data: URI keeps the same 1.5 px line and a token size.
for (const m of css.matchAll(/url\("data:image\/svg\+xml,([^"]*)"\)([^;]*)/g)) {
  const at = lineOf(m.index);
  for (const w of m[1].matchAll(/stroke-width='([^']*)'/g)) if (w[1] !== '1.5' || !/non-scaling-stroke/.test(m[1])) problems.push(`index.html:${at} icon in a data: URI: stroke-width='1.5' with vector-effect='non-scaling-stroke'`);
  const size = m[2].match(/\/\s*([^\s;]+)/)?.[1];
  if (size && !/^var\(--icon-(sm|md|lg)\)$/.test(size)) problems.push(`index.html:${at} icon in a data: URI sized ${size}: use var(--icon-sm|md|lg)`);
}
// In jsx a line icon is <svg className="ico …"> with no width, height or strokeWidth of its own.
for (const f of jsx) {
  let inIcon = false;
  read(f).split('\n').forEach((line, i) => {
    if (/reuse-check: allow/.test(line)) return;
    const svg = line.match(/<svg\b[^>]*>/)?.[0];
    if (svg && !/chart-svg|className="pie"|pay-logo/.test(svg)) {
      const ico = /className="[^"]*\bico\b/.test(svg);
      if (ico && /\b(width|height|strokeWidth)=/.test(svg)) problems.push(`${f}:${i + 1} an .ico svg sets its own size or line: drop width/height/strokeWidth`);
      const w = +(svg.match(/\bwidth="(\d+)/)?.[1] || 0);
      if (!ico && w <= 40 && /stroke|width="\d/.test(svg)) problems.push(`${f}:${i + 1} an inline icon without className="ico": use Icon or svg.ico`);
      inIcon = ico;
    }
    // the power-flow box icons are drawn by flow.jsx's icon() into an svg.ico
    if (f === 'flow.jsx' && /const icon = \(/.test(line)) inIcon = true;
    if (inIcon && /strokeWidth=/.test(line)) problems.push(`${f}:${i + 1} strokeWidth inside an icon: the line is var(--icon-stroke)`);
    if (inIcon && (/<\/svg>/.test(line) || f === 'flow.jsx' && /^  };/.test(line))) inIcon = false;
  });
}

// ---- 3. one global scope ----
const seen = new Map();
for (const f of jsx) {
  for (const m of read(f).matchAll(/^(?:function\s+([A-Za-z_$][\w$]*)|(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=)/gm)) {
    const name = m[1] || m[2];
    if (seen.has(name) && seen.get(name) !== f) problems.push(`${f}: ${name} is also declared at the top of ${seen.get(name)}: one global scope, rename or share it`);
    else seen.set(name, f);
  }
}

if (problems.length) {
  console.log(problems.map(p => 'REUSE ' + p).join('\n'));
  console.log(`\n${problems.length} reuse finding${problems.length === 1 ? '' : 's'}. See COMPONENTS.md.`);
  process.exit(1);
}
console.log('reuse check: clean');
