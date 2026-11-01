// One long-lived psql session. Statements go in on stdin, answers come back as one JSON line each.
import { spawn } from 'node:child_process';

export const PSQL = '/opt/homebrew/opt/libpq/bin/psql';
export const DB_URL = process.env.SIM_DB_URL || 'postgresql://postgres:postgres@127.0.0.1:55322/postgres';

export class Db {
  constructor() {
    this.p = spawn(PSQL, ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=0', DB_URL], { stdio: ['pipe', 'pipe', 'pipe'] });
    this.out = ''; this.err = ''; this.queue = []; this.cur = null; this.gotOut = false; this.gotErr = false;
    this.p.stdout.on('data', (d) => { this.out += d; this.check(); });
    this.p.stderr.on('data', (d) => { this.err += d; this.check(); });
    this.p.on('exit', () => { if (this.cur) this.cur.rej(new Error('psql exited')); });
    this.n = 0;
  }
  check() {
    if (!this.cur) return;
    if (!this.gotOut && this.out.includes('@@END@@\n')) this.gotOut = true;
    if (!this.gotErr && this.err.includes('@@END@@\n')) this.gotErr = true;
    if (this.gotOut && this.gotErr) {
      const lines = this.out.split('\n').filter((l) => l && l !== '@@END@@');
      const err = this.err.split('\n').filter((l) => l && l !== '@@END@@' && !/^(WARNING|NOTICE|INFO|DEBUG|CONTEXT|HINT|DETAIL|LINE \d)/.test(l)).join('\n');
      const c = this.cur; this.cur = null; this.out = ''; this.err = ''; this.gotOut = this.gotErr = false;
      c.res({ lines, err }); this.next();
    }
  }
  next() {
    if (this.cur || !this.queue.length) return;
    this.cur = this.queue.shift();
    this.p.stdin.write(this.cur.sql + "\n;\n\\echo @@END@@\n\\warn @@END@@\n");
  }
  // raw: returns {lines, err}
  run(sql) { return new Promise((res, rej) => { this.queue.push({ sql, res, rej }); this.next(); }); }
  // a statement that must not fail
  async exec(sql) {
    const r = await this.run(sql);
    if (r.err) throw new Error(`SQL error: ${r.err}\n--- ${sql.slice(0, 400)}`);
    return r.lines;
  }
  // pg_temp.t: runs one statement inside a savepoint-like block. {ok, v} or {ok:false, err, code}
  async t(sql) {
    const r = await this.run(`select pg_temp.t($sim$${sql}$sim$);`);
    if (r.err || r.lines.length !== 1) throw new Error(`t() failed: ${r.err} ${r.lines.join('|')}\n--- ${sql.slice(0, 400)}`);
    return JSON.parse(r.lines[0]);
  }
  // same, as the signed-in user (auth.uid())
  async u(uid, sql) {
    const r = await this.run(`select pg_temp.u('${uid}', $sim$${sql}$sim$);`);
    if (r.err || r.lines.length !== 1) throw new Error(`u() failed: ${r.err} ${r.lines.join('|')}\n--- ${sql.slice(0, 400)}`);
    return JSON.parse(r.lines[0]);
  }
  async json(sql) { const l = await this.exec(sql); return l.length ? JSON.parse(l[0]) : null; }
  close() { this.p.stdin.end('\\q\n'); }
}

// Helpers living in the session's pg_temp schema. `fix` gives rows written in this transaction
// distinct, increasing timestamps, because now() is one value for a whole transaction here
// (in production every call is its own transaction).
export const SESSION_SQL = `
create or replace function pg_temp.fix() returns void language sql as $f$
  update private.billing_charges set created_at = clock_timestamp() where created_at = now();
  update private.billing_charges set settled_at = clock_timestamp() where settled_at = now();
$f$;
create or replace function pg_temp.t(q text) returns text language plpgsql as $f$
declare r jsonb;
begin
  execute q into r;
  perform pg_temp.fix();
  return jsonb_build_object('ok', true, 'v', r)::text;
exception when others then
  return jsonb_build_object('ok', false, 'err', sqlerrm, 'code', sqlstate)::text;
end $f$;
create or replace function pg_temp.u(uid uuid, q text) returns text language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  return pg_temp.t(q);
end $f$;
create or replace function pg_temp.snap(uid uuid) returns jsonb language plpgsql as $f$
declare st jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  st := public.api_billing_status();
  return jsonb_build_object(
    'b', (select to_jsonb(b) - 'card' - 'created_at' - 'updated_at' from private.billing b where b.user_id = uid),
    'card', (select card->>'last4' from private.billing where user_id = uid),
    'plants', coalesce((select jsonb_agg(jsonb_build_object('id', plant_id, 'paused', paused) order by linked_at, plant_id)
                          from public.plant_users where user_id = uid), '[]'),
    'st', st,
    'due', public.billing_amount_due(uid));
end $f$;
`;
