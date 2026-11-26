#!/usr/bin/env node
// One owner per table (SOLAR-681 R1, R2). supabase/owners.json gives each table its owner part
// and the files that write it today. Run by `npm test`; exit 1 on a finding.
//
//   R1  a file that writes a table (insert, update, delete, merge, truncate; in supabase-js
//       .insert/.update/.upsert/.delete) must be listed as a writer of that table. A new writer
//       is a design change: add it to owners.json in the same commit, or call the owner's function.
//   R2  a file outside a part that reads one of that part's tables (from, join, using) must be in
//       the part's "readers" list, for the parts that have one. Lists only ever shrink.
//
// Files: supabase/schemas/functions/**.sql (unqualified names resolve through the function's
// search_path), supabase/functions/**.ts (not tests), public/*.jsx. Every table in the database
// is in owners.json: scripts/db-files.mjs checks that against a database built from migrations.
//
//   node scripts/owners-check.mjs           check
//   node scripts/owners-check.mjs --shrink  drop writers and readers that no longer touch a table
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OWNERS = path.join(ROOT, 'supabase', 'owners.json');
const own = JSON.parse(fs.readFileSync(OWNERS, 'utf8'));
const tables = new Set(Object.keys(own.tables));
const problems = [];

const walk = (d) => fs.existsSync(path.join(ROOT, d))
  ? fs.readdirSync(path.join(ROOT, d), { recursive: true }).map((f) => path.join(d, String(f))) : [];
const noComments = (t) => t.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/--[^\n]*/g, ' ');

// file -> { writes: Set<table>, reads: Set<table> }
export function scan() {
  const out = new Map();
  const add = (f, kind, t) => { if (!out.has(f)) out.set(f, { writes: new Set(), reads: new Set() }); out.get(f)[kind].add(t); };
  for (const f of walk('supabase/schemas/functions').filter((f) => f.endsWith('.sql'))) {
    const raw = fs.readFileSync(path.join(ROOT, f), 'utf8');
    const sp = (raw.match(/SET search_path TO ([^\n]*)/) || [, ''])[1].split(',').map((s) => s.trim().replace(/^'|'$/g, '')).filter(Boolean);
    const body = noComments(raw).replace(/"/g, '').toLowerCase();
    const resolve = (n) => {
      if (n.includes('.')) return tables.has(n) ? n : null;
      for (const s of [...sp, 'public']) if (tables.has(`${s}.${n}`)) return `${s}.${n}`;
      return null;
    };
    const W = [/\binsert\s+into\s+([\w.]+)/g, /\b(?<!do\s)update\s+(?!set\b)(?:only\s+)?([\w.]+)\s+(?:(?:as\s+)?\w+\s+)?set\b/g,
      /\bdelete\s+from\s+(?:only\s+)?([\w.]+)/g, /\bmerge\s+into\s+([\w.]+)/g, /\btruncate\s+(?:table\s+)?([\w.]+)/g];
    for (const re of W) for (const m of body.matchAll(re)) { const t = resolve(m[1]); if (t) add(f, 'writes', t); }
    for (const m of body.matchAll(/\b(?:from|join|using)\s+(?:only\s+)?([a-z_][\w.]*)/g)) { const t = resolve(m[1]); if (t) add(f, 'reads', t); }
  }
  const code = [...walk('supabase/functions').filter((f) => /\.(ts|mts|mjs)$/.test(f) && !/_test\.ts$/.test(f) && !f.includes('database.types')),
    ...fs.readdirSync(path.join(ROOT, 'public')).filter((f) => f.endsWith('.jsx')).map((f) => `public/${f}`)];
  for (const f of code) {
    const text = fs.readFileSync(path.join(ROOT, f), 'utf8');
    for (const m of text.matchAll(/(?:\.schema\(\s*["'`](\w+)["'`]\s*\)\s*)?\.from\(\s*["'`](\w+)["'`]\s*\)([\s\S]{0,300})/g)) {
      const t = `${m[1] || 'public'}.${m[2]}`;
      if (!tables.has(t)) continue;
      const chain = m[3].split(/;|\n\s*\n/)[0];
      add(f, /\.(insert|update|upsert|delete)\s*\(/.test(chain) ? 'writes' : 'reads', t);
    }
  }
  return out;
}

const found = scan();
if (process.argv.includes('--shrink')) {
  for (const [t, o] of Object.entries(own.tables)) {
    o.writers = o.writers.filter((f) => found.get(f)?.writes.has(t));
  }
  for (const p of Object.values(own.parts)) if (p.readers)
    for (const [t, fs_] of Object.entries(p.readers)) p.readers[t] = fs_.filter((f) => found.get(f)?.reads.has(t));
  fs.writeFileSync(OWNERS, JSON.stringify(own, null, 1) + '\n');
  console.log('owners.json: writers and readers lowered to what the code has now');
}

for (const [f, { writes, reads }] of found) {
  for (const t of writes) if (!own.tables[t].writers.includes(f))
    problems.push(`${f} writes ${t} (owner: ${own.tables[t].part}): call the owner's function, or list it as a writer in supabase/owners.json`);
  for (const t of reads) {
    const part = own.tables[t].part;
    const r = own.parts[part]?.readers;
    if (!r || own.parts[part].files.some((p) => f.startsWith(p))) continue;
    if (!(r[t] || []).includes(f)) problems.push(`${f} reads ${t} (owner: ${part}): read it through the owner's functions`);
  }
}
for (const [t, o] of Object.entries(own.tables)) if (!own.parts[o.part]) problems.push(`owners.json: ${t} names unknown part ${o.part}`);

if (problems.length) {
  console.log(problems.map((p) => 'OWNERS ' + p).join('\n'));
  console.log(`\n${problems.length} owner finding${problems.length === 1 ? '' : 's'}.`);
  process.exit(1);
}
console.log('owners check: clean');
