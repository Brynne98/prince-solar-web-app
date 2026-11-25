// The database the billing state and lock tests run on (SOLAR-661). They commit or roll back
// made-up accounts, so they need a local database of their own, at the newest migration:
// STATE_DB_URL must name it, on 127.0.0.1 / localhost. psql never sees the URL: it gets the
// checked host, port, user and database as separate arguments, so nothing in the URL or the
// environment (host, hostaddr, service) can send it elsewhere.
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function refuse(why) {
  console.error(`refusing to run: ${why}`);
  process.exit(1);
}

const raw = process.env.STATE_DB_URL;
if (!raw) refuse('set STATE_DB_URL to a local database of its own (supabase start in a copy of supabase/)');
if (/[?#]/.test(raw)) refuse('STATE_DB_URL may not carry settings (? or #)');
let url;
try { url = new URL(raw); } catch { refuse('STATE_DB_URL is not a URL'); }
if (!/^postgres(ql)?:$/.test(url.protocol)) refuse('STATE_DB_URL is not a postgres URL');
if (!['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) refuse('not a local database');
const dbname = decodeURIComponent(url.pathname.slice(1)) || 'postgres';
if (!/^\w+$/.test(dbname)) refuse('STATE_DB_URL names an odd database');

// psql's connection: the checked parts only; the password through the environment
export const DB_ARGS = ['-h', url.hostname.replace(/^\[|\]$/g, ''), '-p', url.port || '5432',
  '-U', decodeURIComponent(url.username) || 'postgres', '-d', dbname];
export const ENV = { ...process.env, PGPASSWORD: decodeURIComponent(url.password) };
for (const k of Object.keys(ENV)) if (/^PG/.test(k) && k !== 'PGPASSWORD') delete ENV[k];

export const PSQL = process.env.PSQL || ['/opt/homebrew/opt/libpq/bin/psql', '/usr/local/opt/libpq/bin/psql'].find(existsSync) || 'psql';
export const psql = (input, flags = []) =>
  spawnSync(PSQL, ['-X', '-q', '-v', 'ON_ERROR_STOP=1', ...flags, ...DB_ARGS], { input, encoding: 'utf8', env: ENV });

// the newest file, by number and name (a renumbered file with the same number does not count)
const newest = readdirSync(path.join(REPO, 'supabase/migrations')).filter((f) => /^\d{4}_.*\.sql$/.test(f)).sort().at(-1)
  .replace(/^(\d{4})_(.*)\.sql$/, '$1|$2');
const at = psql('select version || \'|\' || name from supabase_migrations.schema_migrations order by version desc limit 1', ['-At']);
if (at.status !== 0) refuse(`cannot read the database's migrations: ${at.stderr.trim()}`);
if (at.stdout.trim() !== newest) refuse(`the database is at migration ${at.stdout.trim()}, the newest file is ${newest}`);
