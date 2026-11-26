#!/usr/bin/env node
// Production release, from this Mac only (SOLAR-679 F2, F3). `npm run release`, on Brynne's say-so.
// One commit, in a fixed order, stopping at the first failure:
//   1. checks    on main, clean, HEAD = origin/main, every GitHub check green for that commit
//   2. database  functions_url Vault secret if missing; live functions match their files
//                (except those the pending migrations change); supabase db push
//   3. functions supabase functions deploy (unchanged ones are skipped); every live function
//                matches its file
//   4. frontend  built from a clean copy of the commit; source maps to PostHog (key from the
//                macOS keychain), never published; wrangler pages deploy; live version and no
//                public .map checked
// Logins are this Mac's own: the Supabase CLI (keychain) and wrangler. No key is read from a file.
// The frontend is built in a plain copy of the commit (git archive), so this checkout is untouched.
// The PostHog key: security add-generic-password -s prince-solar-posthog-cli -a admin -w
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const GH_REPO = 'Brynne98/prince-solar-web-app';
const PAGES_PROJECT = 'prince-solar-web-app';
const APP = 'https://app.princesolarhub.co.za';
const POSTHOG_PROJECT = '321817';
const WRANGLER = 'wrangler@4.20.0';
const POSTHOG_CLI = '@posthog/cli@0.19.4';

const out = (cmd, args, opts = {}) => execFileSync(cmd, args, { cwd: REPO, encoding: 'utf8', maxBuffer: 1 << 28, ...opts }).trim();
const run = (cmd, args, opts = {}) => {
  const r = spawnSync(cmd, args, { cwd: REPO, stdio: 'inherit', ...opts });
  if (r.status !== 0) fail(`${cmd} ${args.join(' ')} exited ${r.status}`);
};
function fail(why) { console.error(`\nRELEASE STOPPED: ${why}`); process.exit(1); }
const stage = (n, what) => console.log(`\n=== ${n}. ${what} ===`);

// ---- 1. checks ----
stage(1, 'checks');
if (out('git', ['rev-parse', '--abbrev-ref', 'HEAD']) !== 'main') fail('not on main');
if (out('git', ['status', '--porcelain'])) fail('the working tree has changes');
run('git', ['fetch', '-q', 'origin', 'main']);
const sha = out('git', ['rev-parse', 'HEAD']);
if (sha !== out('git', ['rev-parse', 'origin/main'])) fail('HEAD is not origin/main: push first, or pull');
const runs = JSON.parse(out('gh', ['api', `repos/${GH_REPO}/commits/${sha}/check-runs?per_page=100`])).check_runs;
const need = ['node', 'deno', 'sql', 'staging'];
for (const n of need) if (!runs.some((c) => c.name === n)) fail(`no "${n}" check for ${sha.slice(0, 7)} yet`);
const notGreen = runs.filter((c) => c.status !== 'completed' || !['success', 'skipped', 'neutral'].includes(c.conclusion));
if (notGreen.length) fail(`checks not green: ${notGreen.map((c) => `${c.name} ${c.status}/${c.conclusion}`).join(', ')}`);
const version = fs.readFileSync(path.join(REPO, 'public/config.js'), 'utf8').match(/APP_VERSION = '([^']+)'/)?.[1];
if (!version) fail('no APP_VERSION in public/config.js');
// the production project is the one the web app talks to
const ref = fs.readFileSync(path.join(REPO, 'public/config.js'), 'utf8').match(/url: 'https:\/\/([a-z0-9]{20})\.supabase\.co'/)?.[1];
if (!ref) fail('no production project address in public/config.js');
console.log(`commit ${sha.slice(0, 7)}, version ${version}, project ${ref}, ${runs.length} checks green`);

// ---- 2. database ----
stage(2, 'database');
const query = (sql, ro = false) => out('supabase', ['db', 'query', `--remote=${ref}`, ...(ro ? ['--read-only'] : ['--yes']), '--output-format', 'json', sql]);
query(`select vault.create_secret('https://${ref}.functions.supabase.co', 'functions_url')
        where not exists (select 1 from vault.secrets where name = 'functions_url')`);
console.log('functions_url secret: present');
const applied = new Set(JSON.parse(query('select version from supabase_migrations.schema_migrations', true)).rows.map((r) => r.version));
const pending = fs.readdirSync(path.join(REPO, 'supabase/migrations')).filter((f) => /^\d{4}_.*\.sql$/.test(f) && !applied.has(f.slice(0, 4)));
console.log(`pending migrations: ${pending.join(', ') || 'none'}`);
// functions a pending migration writes may differ from their files until it lands
const changing = new Set(pending.flatMap((f) => [...fs.readFileSync(path.join(REPO, 'supabase/migrations', f), 'utf8')
  .matchAll(/function\s+(?:if\s+exists\s+)?"?(\w+)"?\."?(\w+)"?\s*\(/gi)].map((m) => `${m[1].toLowerCase()}/${m[2].toLowerCase()}.sql`)));
run('node', ['scripts/db-files.mjs', '--live', ...[...changing].flatMap((f) => ['--except', f])], { env: { ...process.env, SUPABASE_PROJECT_REF: ref } });
if (pending.length) run('supabase', ['db', 'push', `--remote=${ref}`, '--yes']);

// ---- 3. functions ----
stage(3, 'functions');
run('supabase', ['functions', 'deploy', `--remote=${ref}`, '--use-api', '--jobs', '4', '--yes']);
run('node', ['scripts/db-files.mjs', '--live'], { env: { ...process.env, SUPABASE_PROJECT_REF: ref } });

// ---- 4. frontend ----
stage(4, 'frontend');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'prince-release-'));
let built;
try {
  execFileSync('sh', ['-c', `git archive ${sha} | tar -x -C "${tmp}"`], { cwd: REPO });
  const inCopy = { cwd: tmp };
  run('npm', ['ci', '--silent'], inCopy);
  // CI=1: files named after their content (build/* is cached a year), pages rewritten to match
  run('npm', ['run', 'build'], { ...inCopy, env: { ...process.env, CI: '1', SOURCEMAPS: '1' } });
  const key = spawnSync('security', ['find-generic-password', '-s', 'prince-solar-posthog-cli', '-w'], { encoding: 'utf8' });
  if (key.status === 0 && key.stdout.trim()) {
    const env = { ...process.env, POSTHOG_CLI_API_KEY: key.stdout.trim(), POSTHOG_CLI_PROJECT_ID: POSTHOG_PROJECT };
    const ph = (verb, extra = []) => spawnSync('npx', ['-y', POSTHOG_CLI, '--host', 'https://eu.posthog.com', 'sourcemap', verb,
      '-d', 'public/build', '--release-name', 'prince-solar-hub', '--release-version', version, ...extra], { cwd: tmp, env, stdio: 'inherit' });
    if (ph('inject').status !== 0 || ph('upload', ['--delete-after']).status !== 0)
      console.warn('WARNING: source maps did not reach PostHog; carrying on without them');
  } else console.warn('WARNING: no PostHog key in the keychain (prince-solar-posthog-cli): source maps not uploaded');
  const pub = path.join(tmp, 'public');
  for (const f of fs.readdirSync(pub, { recursive: true }).map(String).filter((f) => f.endsWith('.map'))) fs.rmSync(path.join(pub, f));
  if (fs.readdirSync(pub, { recursive: true }).map(String).some((f) => f.endsWith('.map'))) fail('source maps left in public/');
  run('npx', ['-y', WRANGLER, 'pages', 'deploy', 'public', '--project-name', PAGES_PROJECT, '--branch', 'main',
    '--commit-hash', sha, '--commit-message', `release ${version}`, '--commit-dirty=false'], inCopy);
  built = fs.readdirSync(path.join(pub, 'build')).filter((f) => f.endsWith('.js'));
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

// live checks
let live = false;
for (let i = 0; i < 30 && !live; i++) {
  const r = await fetch(`${APP}/config.js?v=${Date.now()}`).then((x) => x.text()).catch(() => '');
  live = r.includes(`APP_VERSION = '${version}'`);
  if (!live) await new Promise((r) => setTimeout(r, 10_000));
}
if (!live) fail(`${APP} does not serve ${version}`);
for (const f of built) {
  const s = (await fetch(`${APP}/build/${f}.map`)).status;
  if (s !== 404) fail(`build/${f}.map answers ${s}`);
}
console.log(`\nRELEASED ${version} (${sha.slice(0, 7)}): database, functions, frontend; ${built.length} scripts, no public map`);
