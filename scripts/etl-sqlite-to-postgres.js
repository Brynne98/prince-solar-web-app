#!/usr/bin/env node
/**
 * One-time (and re-runnable) migration of the local SQLite history into Postgres.
 *
 *   node scripts/etl-sqlite-to-postgres.js              # -> local supabase stack
 *   node scripts/etl-sqlite-to-postgres.js --url=postgresql://...   # -> remote
 *   node scripts/etl-sqlite-to-postgres.js --dry-run
 *
 * Deliberately skips the `raw` table: 46 MB of the 96 MB file, gzipped API payloads
 * with no dashboard consumer that may embed account identifiers.
 *
 * Re-runnable by design — every table stages into a TEMP table and then upserts, so
 * running it again at cutover only banks the delta. Conflict behaviour mirrors db.js:
 * agg_minute is INSERT OR IGNORE (a poller row always wins), the rest are
 * INSERT OR REPLACE.
 *
 * Streams CSV straight into psql; no pg driver needed. Locally psql is reached
 * through the stack's container, since there's no psql on the host.
 */
const { DatabaseSync } = require('node:sqlite');
const { spawn } = require('node:child_process');
const path = require('node:path');

const args = process.argv.slice(2);
const has = (f) => args.some((a) => a === f || a.startsWith(f + '='));
const val = (f) => { const a = args.find((x) => x.startsWith(f + '=')); return a ? a.slice(f.length + 1) : null; };

const DRY = has('--dry-run');
const URL = val('--url');
const CONTAINER = val('--container') || 'supabase_db_sunsynk-dashboard';
const SQLITE = val('--sqlite') || path.join(__dirname, '..', 'data', 'sunsynk.db');
const BATCH = Number(val('--batch')) || 20000;

// Locate psql. Homebrew's libpq is keg-only, so it is installed but NOT on PATH —
// look there before giving up. Override with --psql=/path/to/psql.
function findPsql() {
  const explicit = val('--psql');
  if (explicit) return explicit;
  const candidates = [
    '/opt/homebrew/opt/libpq/bin/psql', // Apple Silicon Homebrew (keg-only)
    '/usr/local/opt/libpq/bin/psql',    // Intel Homebrew (keg-only)
    '/opt/homebrew/bin/psql',
    '/usr/local/bin/psql',
    '/usr/bin/psql',
  ];
  for (const c of candidates) { try { require('node:fs').accessSync(c, 1); return c; } catch {} }
  return 'psql'; // fall back to PATH
}

// psql invocation: a URL means a real psql binary, otherwise go through the container.
const psqlCmd = URL
  ? [findPsql(), [URL, '-v', 'ON_ERROR_STOP=1', '-q']]
  : ['docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q']];

/** Tables in dependency-free order. `conflict` mirrors the SQLite upsert semantics. */
const TABLES = [
  {
    name: 'public.agg_minute',
    cols: ['ts', 'pv_w', 'load_w', 'batt_w', 'grid_w', 'soc', 'source'],
    key: 'ts',
    conflict: 'do nothing', // INSERT OR IGNORE — never overwrite a measurement
    from: 'agg_minute',
  },
  {
    name: 'public.readings',
    cols: ['ts', 'sn', 'status', 'pv_w', 'pv_today_kwh', 'pv_total_kwh', 'batt_power_w', 'batt_w',
      'batt_soc', 'batt_voltage_v', 'batt_current_a', 'batt_temp_c', 'batt_chg_today_kwh',
      'batt_dischg_today_kwh', 'batt_chg_total_kwh', 'batt_dischg_total_kwh', 'grid_w',
      'grid_import_today_kwh', 'grid_export_today_kwh', 'grid_import_total_kwh',
      'grid_export_total_kwh', 'grid_freq_hz', 'grid_pf', 'load_w', 'load_today_kwh',
      'load_total_kwh', 'load_freq_hz', 'output_w', 'output_volt_v', 'output_freq_hz'],
    key: 'ts, sn',
    conflict: 'update',
    from: 'readings',
  },
  {
    name: 'public.strings',
    cols: ['ts', 'sn', 'no', 'volt_v', 'current_a', 'power_w', 'today_kwh'],
    key: 'ts, sn, "no"',
    conflict: 'update',
    from: 'strings',
  },
  {
    name: 'private.meta',
    cols: ['sn', 'updated_ts', 'alias', 'model', 'soft_ver', 'hmi_ver', 'gsn', 'comm_type',
      'capacity_ah', 'number_of_batteries', 'plant_id', 'plant_name'],
    key: 'sn',
    conflict: 'update',
    from: 'meta',
  },
  {
    name: 'private.gaps',
    cols: ['from_ts', 'to_ts'],
    key: 'from_ts',
    conflict: 'do nothing',
    from: 'gaps',
  },
];

const q = (id) => (id.startsWith('"') ? id : `"${id}"`);

/** CSV field. NULL is an unquoted empty field; an empty string is `""` — distinct. */
function csv(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : '';
  if (typeof v === 'bigint') return String(v);
  const s = String(v);
  return '"' + s.replace(/"/g, '""') + '"';
}

function upsertSql(t) {
  const cols = t.cols.map(q).join(', ');
  if (t.conflict === 'do nothing') {
    return `insert into ${t.name} (${cols}) select ${cols} from _stage on conflict (${t.key}) do nothing;`;
  }
  const keyCols = t.key.split(',').map((s) => s.trim().replace(/"/g, ''));
  const sets = t.cols.filter((c) => !keyCols.includes(c))
    .map((c) => `${q(c)} = excluded.${q(c)}`).join(', ');
  return `insert into ${t.name} (${cols}) select ${cols} from _stage on conflict (${t.key}) do update set ${sets};`;
}

async function main() {
  const db = new DatabaseSync(SQLITE, { readOnly: true });
  const existing = new Set(
    db.prepare("select name from sqlite_master where type='table'").all().map((r) => r.name));

  console.log(`source : ${SQLITE}`);
  console.log(`target : ${URL ? URL.replace(/:[^:@/]+@/, ':***@') : `container ${CONTAINER}`}`);
  console.log(`mode   : ${DRY ? 'DRY RUN (no writes)' : 'live'}\n`);

  const plan = [];
  for (const t of TABLES) {
    if (!existing.has(t.from)) { console.log(`  skip ${t.name} — no source table "${t.from}"`); continue; }
    const n = db.prepare(`select count(*) c from "${t.from}"`).all()[0].c;
    plan.push({ ...t, rows: n });
    console.log(`  ${t.name.padEnd(20)} ${String(n).padStart(8)} rows`);
  }
  const total = plan.reduce((a, t) => a + t.rows, 0);
  console.log(`\n  total ${total} rows (raw table intentionally skipped)\n`);
  if (DRY) return;

  for (const t of plan) {
    if (!t.rows) { console.log(`${t.name}: empty, skipping`); continue; }
    process.stdout.write(`${t.name}: `);
    const started = Date.now();

    const child = spawn(psqlCmd[0], psqlCmd[1], { stdio: ['pipe', 'pipe', 'pipe'] });
    let stderr = '';
    child.stderr.on('data', (d) => { stderr += d; });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });

    // If psql exits early (bad password, unreachable host, SQL error) the pipe
    // closes and every subsequent write raises EPIPE. Swallow it here so the real
    // diagnosis — which is on psql's stderr — is what actually gets reported.
    let broken = false;
    child.stdin.on('error', (e) => {
      if (e.code === 'EPIPE') broken = true;
      else throw e;
    });

    const done = new Promise((resolve, reject) => {
      child.on('error', (e) => reject(new Error(`could not run ${psqlCmd[0]}: ${e.message}`)));
      child.on('close', (code) => code === 0
        ? resolve()
        : reject(new Error(`psql exited ${code}\n\n${(stderr + out).trim() || '(no output)'}`)));
    });

    const w = (s) => new Promise((res) => {
      if (broken || !child.stdin.writable) return res(); // let `done` report the cause
      child.stdin.write(s) ? res() : child.stdin.once('drain', res);
    });

    // Stage -> upsert, all in one transaction so a failure leaves nothing behind.
    await w(`begin;\n`);
    await w(`create temp table _stage (like ${t.name} including defaults) on commit drop;\n`);
    await w(`\\copy _stage (${t.cols.map(q).join(', ')}) from stdin with (format csv, null '')\n`);

    const stmt = db.prepare(`select ${t.cols.map((c) => `"${c}"`).join(',')} from "${t.from}"`);
    let sent = 0, buf = [];
    for (const row of stmt.iterate()) {
      buf.push(t.cols.map((c) => csv(row[c])).join(','));
      if (buf.length >= BATCH) {
        await w(buf.join('\n') + '\n'); sent += buf.length; buf = [];
        process.stdout.write('.');
      }
    }
    if (buf.length) { await w(buf.join('\n') + '\n'); sent += buf.length; }
    await w('\\.\n');
    await w(upsertSql(t) + '\n');
    await w(`select 'INSERTED ' || count(*) from _stage;\n`);
    await w('commit;\n');
    try { child.stdin.end(); } catch { /* already closed; `done` reports why */ }

    await done;
    const secs = ((Date.now() - started) / 1000).toFixed(1);
    console.log(` ${sent} rows in ${secs}s`);
  }

  console.log('\ndone.');
}

main().catch((e) => { console.error('\nETL FAILED:', e.message); process.exit(1); });
