// The database the billing state and lock tests run on (SOLAR-661). They commit or roll back
// made-up accounts, so they need a local database of their own, at the newest migration:
// STATE_DB_URL must name it, on 127.0.0.1 / localhost, with no setting that can send psql
// elsewhere (host, hostaddr or service in the URL or the environment).
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function refuse(why) {
  console.error(`refusing to run: ${why}`);
  process.exit(1);
}

export const DB = process.env.STATE_DB_URL;
if (!DB) refuse('set STATE_DB_URL to a local database of its own (supabase start in a copy of supabase/)');
let url;
try { url = new URL(DB); } catch { refuse('STATE_DB_URL is not a URL'); }
if (!/^postgres(ql)?:$/.test(url.protocol)) refuse('STATE_DB_URL is not a postgres URL');
if (!['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) refuse('not a local database');
const sendsElsewhere = [...url.searchParams.keys()].filter((k) => /^(host|hostaddr|service|servicefile)$/i.test(k));
if (sendsElsewhere.length) refuse(`STATE_DB_URL sets ${sendsElsewhere.join(', ')}`);

export const ENV = { ...process.env };
for (const k of ['PGHOST', 'PGHOSTADDR', 'PGSERVICE', 'PGSERVICEFILE']) delete ENV[k];

export const PSQL = process.env.PSQL || ['/opt/homebrew/opt/libpq/bin/psql', '/usr/local/opt/libpq/bin/psql'].find(existsSync) || 'psql';
export const psql = (input, flags = []) =>
  spawnSync(PSQL, ['-X', '-q', '-v', 'ON_ERROR_STOP=1', ...flags, DB], { input, encoding: 'utf8', env: ENV });

const newest = readdirSync(path.join(REPO, 'supabase/migrations')).filter((f) => /^\d{4}_.*\.sql$/.test(f)).sort().at(-1).slice(0, 4);
const at = psql('select max(version) from supabase_migrations.schema_migrations', ['-At']);
if (at.status !== 0) refuse(`cannot read the database's migrations: ${at.stderr.trim()}`);
if (at.stdout.trim() !== newest) refuse(`the database is at migration ${at.stdout.trim()}, the newest file is ${newest}`);
