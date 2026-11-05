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
