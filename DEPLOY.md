# Deploying

Runbook for shipping this project. Two independent halves — the frontend goes out via
Cloudflare Pages (app.princesolarhub.com; showcase at princesolarhub.com), the backend via the Supabase CLI — and **they do
not deploy together**.

> The deploy thread ships and verifies. It does not write feature code. Broken builds,
> leftover debug code, uncommitted work or migration drift get reported, not fixed.
> The only files it edits are `public/config.js` and `supabase/functions/_shared/errors.ts`, to bump the version.

---

## Order

**Backend first, frontend second.** New UI must never call an RPC that isn't there yet.
Migrations and Edge Functions are backward-compatible with the old frontend; the reverse
is not true.

---

## 1. Pre-flight

Supabase CLI v3 (Homebrew): database commands aim at the local stack unless given `--linked`.
Function deploys use the linked project on their own.

```bash
git status --short                  # must be clean at the end, not the start
git log --oneline origin/main..HEAD # anything unpushed?
supabase migration list --linked    # Local and Remote columns must match
grep -rn "TEMPORARY\|console.log\|debugger" public/ supabase/functions/
```

Then build and test. `npm test` runs `npm run build`, which compiles `public/*.jsx` into
`public/build/*.js` with the same Babel settings the browser used to apply (SOLAR-131), then
the warning tests and the reuse check. The reuse check fails when the functions' `APP_VERSION`
differs from `config.js`. Any failure exits 1; Cloudflare runs only the build and keeps the
last good deploy live if it fails:

```bash
npm test
```

A missing function or bad reference will NOT be caught by that — it is a syntax check,
not a correctness one. Load the page and click through the affected tabs.

## 2. Version

Ask which number to use. Semver: patch for fixes, minor for features, major for a
rewrite. Then edit the one line:

```js
// public/config.js
window.APP_VERSION = 'v1.2.3';
```

Set the same number in `supabase/functions/_shared/errors.ts` (`APP_VERSION`): it is the
release on the functions' errors and events. `npm test` fails while the two differ.

Backend-only deploys need no bump — `APP_VERSION` tracks the web app, and bumping it
would drag a Pages rebuild along for nothing.

## 3. Backend

> **Releasing the official-API / multi-tenant change (migrations 0024–0025):**
> set secrets **before** `db push`, because the first `poll` after the migration
> bootstraps your plant from them. `0024` re-keys `agg_minute`, drops `private.auth`
> and moves tokens into Vault — **there is no rollback short of a database restore.**
> Take a backup first. `link-sunsynk` is new and must be deployed. `api_health()`
> keeps its global no-argument behaviour, so the health workflow is unchanged.
>
> ```bash
> supabase secrets set SUNSYNK_APP_KEY=… SUNSYNK_APP_SECRET=… BOOTSTRAP_USER_EMAIL=brynneprince98@gmail.com
> supabase db push
> supabase functions deploy poll link-sunsynk recover sync-plant-energy alerts-due
> ```

> **Releasing the sharded poller (migration 0030):** push the migration **before**
> deploying `poll`. The new function calls `poll_commit()`, which does not exist
> until `0030` lands; the old function ignores the shard body the new cron job
> sends, so the reverse order is the only one that stops the logger. `0030` also
> reschedules `sunsynk-poll` with a 55 s pg_net timeout. Nothing is dropped and
> the old accessor RPCs stay in place, so rolling back is redeploying the previous
> `poll`.
>
> ```bash
> supabase db push
> supabase functions deploy poll
> ```

```bash
supabase db push --linked                         # pending migrations
supabase functions deploy poll                    # only what changed
supabase functions deploy alerts-due recover sync-plant-energy
```

**Poller v3 lanes (0259, SOLAR-656): function first, then migration, then poll.** 0259's
cron jobs call `poll-lane` for the chores (share login retry, call report) from the start,
and the new `poll` no longer runs them. Set `POLLER_DB_URL` to the pooler's transaction
address (port 6543) first; without it the lanes use `SUPABASE_DB_URL`, the direct one.

```bash
supabase secrets set POLLER_DB_URL=...            # pooler, port 6543
supabase functions deploy poll-lane
supabase db push --linked                         # 0259: mode stays 'edge'
supabase functions deploy poll
```

**New tables, sequences and functions get no access by default** (0108, SOLAR-145).
Since 0108, and on Supabase from 2026-10-30, a new object in `public` is open to no
one but its owner, and service_role for functions. The migration that creates it grants
exactly what the app and the server need, in the same file:

```sql
create table public.foo (id bigserial primary key, ...);
alter table public.foo enable row level security;
create policy foo_read on public.foo for select to authenticated using (...);
grant select on public.foo to authenticated;            -- only what the app reads or writes
grant all    on public.foo to service_role;             -- edge functions and cron
grant usage, select on sequence public.foo_id_seq to service_role;  -- whoever inserts

create function public.api_foo() ... security definer ...;
grant execute on function public.api_foo() to authenticated;   -- anon only if signed-out pages call it
```

anon gets nothing unless a signed-out page needs it. A local `supabase db reset` replays
migrations the same way (`auto_expose_new_tables = false`), so a missing grant shows up
there as "permission denied" before it reaches production.

**"Only what changed" includes `_shared/`.** Every function bundles the files it
imports from `supabase/functions/_shared/` at deploy time, so a change there is a
change to every importer — even if the importer's own `index.ts` is untouched.
`git log -- supabase/functions/<name>` will say the function is current when it is
not. Check the shared files too:

```bash
git log --name-only --since="<last deploy time>" -- supabase/functions/_shared
```

Then redeploy everything that imports a file in that list. When in doubt, deploy
all five; the CLI skips any whose bundle is unchanged ("No change found in
Function"), so over-deploying costs nothing. It also means `UPDATED_AT` in
`supabase functions list` is not proof a function is stale — a deploy from an
uncommitted working tree can land before the commit.

```bash
supabase functions deploy poll recover alerts-due link-sunsynk sync-plant-energy
```

After deploying `poll`, confirm the logger survived:

```bash
curl -s -X POST https://pmakzojwhouamawgszrc.supabase.co/rest/v1/rpc/api_health \
  -H "apikey: sb_publishable_PTYy9-EiqSFUVaFMLlCMnQ_DejfmixB" \
  -H 'Content-Type: application/json' -d '{}'
# expect {"stale": false}
```

## 4. Frontend

```bash
git add -A && git commit && git push origin main
```

Cloudflare Pages rebuilds from `main` on every push: build command `npm ci && npm run build`,
output directory `public`. Its build settings live in the Cloudflare dashboard, not in this
repo. `public/build/` is not in git; the build makes it.

`.github/workflows/secrets-guard.yml` scans the whole repo and its history for secrets with
gitleaks (`.gitleaks.toml`) on every push to main; GitHub's secret scanning and push
protection are also on in the repo settings.
A failed check does not stop Cloudflare; read the run. GitHub Pages is switched off
(SOLAR-110).

## 5. Verify — do not assume

```bash
until curl -s "https://app.princesolarhub.com/config.js?v=$(date +%s)" \
  | grep -q "v1.2.3"; do sleep 20; done
```

Typically 1–2 minutes. If it doesn't land, check the run:

```bash
curl -s "https://api.github.com/repos/Brynne98/prince-solar-web-app/actions/runs?per_page=5"
```

Logs need authentication, so an unauthenticated fetch gets 403 — read the failure in the
Actions tab instead.

---

## Things that have actually gone wrong

**Pages returned 503 for hours.** Two consecutive runs failed inside
`actions/configure-pages` and `actions/deploy-pages` during an open GitHub.com incident,
while the status page still showed Pages as operational. Nothing to fix; re-run later.

**Confusing localhost for production.** The local stack looks identical and can hold
replayed fixture data. The version in **Settings** is the tell. Local runs on `:3003` /
`:3011` against Supabase on `127.0.0.1:55321`.

**Legacy API keys are disabled** on this project (since 2026-08-05). The old `anon` /
`service_role` JWTs return `401 Legacy API keys are disabled`. Use the publishable key,
or the `sb_secret_` key. `supabase projects api-keys` still prints the dead JWTs, so do
not trust it.

**Debug code nearly shipped more than once** — a `?skeleton=1` flag, CSS guide lines, and
a temporary branch inside `poll`. Grep before committing.

**Never point a seeding script at production.** Local fixtures replay real logged days
onto today; that must stay local.

---

## Going live

Until the Paystack account is verified, production runs on the test key: only the
accounts in `PAYSTACK_TEST_USERS` can pay (Paystack test cards), everyone else gets
"Paid plans open soon" (SOLAR-267). When the live key arrives, in this order:

1. Remove the tester's test billing and every fake SunSynk login (`name@mock`, SOLAR-270)
   with its fake plants (the tester's real plants and readings stay):
   `supabase db query --linked -f scripts/sql/go-live-tester-cleanup.sql`
2. `supabase secrets set PAYSTACK_SECRET_KEY=<live key>` (paste it yourself).
3. `supabase secrets unset PAYSTACK_TEST_USERS`
4. `supabase functions delete mock-sunsynk` (fake SunSynk, SOLAR-270).
5. Paystack dashboard, live mode → Settings → API Keys & Webhooks: webhook URL
   `https://pmakzojwhouamawgszrc.supabase.co/functions/v1/billing/webhook`. Test and live
   modes keep separate URLs; without it refunds and disputes never arrive.

Fake SunSynk logins came back for testers on 2026-11-10 (SOLAR-477): `mock-sunsynk` is
deployed again, and only user ids in the `TESTER_USERS` secret may link `name@mock`
(`scripts/set-test-users.sh` sets it; today the +test account), or whose confirmed email
matches the `TESTER_EMAIL_PATTERN` secret (a regular expression; today every
brynneprince98+testN@gmail.com). Email sign-up must stay confirm-first, or anyone could
claim a matching address. Everyone else gets
"SunSynk rejected those credentials". Billing ignores the list: testers pay on the live
key. To switch it off: `supabase secrets unset TESTER_USERS TESTER_EMAIL_PATTERN`, then
`supabase functions delete mock-sunsynk` and the fake-login part of
`go-live-tester-cleanup.sql`.

Tester events (`upgrade_done` and the rest) are in PostHog under the tester's user id;
filter that id out of sales numbers.

## Billing switch-over (SOLAR-641)

The new `billing` schema (migrations 0240 on) ships empty and unused. Backend first,
frontend second, in this order:

1. Push the migrations (0240 to 0247): `supabase db push --linked`. Nothing changes what runs
   today: the new tables stay empty, the old RPCs answer as before, and every new rule
   waits for `billing.switch_on()`.
2. Deploy the functions that read the new state but fall back to the old rules until the
   switch: `supabase functions deploy poll recover sync-plant-energy job-check link-sunsynk claim-share notify`.
   link-sunsynk and claim-share also write each new login and claim into the new tables;
   notify sends `billing.outbox` only after the switch.
3. Turn the old billing job off (`select cron.unschedule('billing-run')`) and stop new old
   payments: `supabase db query --linked "select billing.pause_old('new_payments')"`. Pay and
   plan changes on the old screens now answer an error; links and readings carry on. Settle or
   refund the old payments still open, until
   `select count(*) from private.billing_charges where status = 'pending'` is 0. Step 6 turns
   the job back on for the new billing function.
4. Copy today's accounts, once: `supabase db query --linked "select billing.copy_from_old()"`.
   A rerun keeps each account's id and clears only the events the copy wrote, so it is safe
   until the first payment lands in `billing.invoices`; after that it refuses. Saved cards
   come across, so renewals keep charging them. Old charges still open, or settled in the
   last 120 days, come across with their Paystack reference: a webhook or a return from the
   card page after the switch is applied under the new rules (or refunded if stale there),
   not refunded as unknown. An old one still open after step 3 is fine. At any age, the copy
   also brings across what is still unresolved: a refund not done (asked: pending; owed:
   retried by the new job; 7 tries made or hello@ told: left for a hand refund), an open
   dispute (blocks deleting the account) and a lost dispute not yet charged (owed on its
   bill). The copy does not refuse for any of them. Its answer counts them (`refunds`,
   `refunds_to_send`, `disputes_open`, `owed`). Every settled old reference, at any age, is
   kept in `billing.old_references` (`old_references`): Paystack sending an old paid one
   again is answered as already applied, never refunded; a first dispute on one brings its
   bill and try back, so it blocks a delete while open and is owed if lost. A switch to yearly
   already paid (`prepaid_on` on the billing date) copies as the yearly plan from that date to
   a year after it, with nothing charged on it; the paid switch's bill is that year, so a lost
   dispute ends it. Before step 4, count them:
   `select count(*) from private.billing where prepaid_on is not null`; in step 5 check each
   one is yearly with that start and end date.
5. Compare `billing.account_state` for each account with today's screens, next charges and
   poll decisions. By hand: the old refunds that failed and now wait for a hand refund,
   `select * from billing.refunds where reason = 'manual' and status = 'failed'`. Each one is
   paid back from the Paystack dashboard; the copy never sends them.

   Before step 6 (go-live review, 2026-11-23):
   - Backup, kept outside the repo: `supabase db dump --linked --data-only --schema private,billing,public -f ~/backups/solar-pre-switch-<date>.sql`.
     Note the time. Supabase's daily backup is the second copy.
   - Alerts reach admin@: in PostHog (the admin@ Chrome), the alert on `job_check_failed` is on
     and emails admin@, and the error-tracking destination (`error-alert`) is on. A repeated
     `billing_command_failed`, `run_charge_failed` or `webhook_failed` then arrives as an email.
   - One person watches from step 6 until the first billing run after it (04:00 to 06:00 the
     next morning) has a heartbeat: `select * from billing.job_heartbeats where job = 'billing-run'`.
   - Agreed: going back (below) is allowed until step 7 or the first new payment, whichever
     comes first. After that, fix forward.
6. The switch, in this order, so no billing email is sent twice or lost, and no change made
   since step 4 is lost (logins, plant choices and payments made since the first copy are in
   the old tables only):
   1. Freeze the old billing tables: `supabase db query --linked "select billing.pause_old('all')"`.
      From here every write to them fails ("billing is paused for an update"): linking a login
      and the old billing function answer an error, and Paystack sends a refused webhook again
      later. Keep this window to a few minutes.
      Then empty the old wipe queue, which stands down once switched and would otherwise keep
      its plants forever. Run the call on its own, not inside `begin; ... commit;`: it commits
      after each plant.
      `supabase db query --linked "call private.purge_plants()"` (answers `CALL`), then
      `supabase db query --linked "select count(*) from private.plant_purge"` must say 0.
      Not 0: run the call again; still not 0, `select billing.resume_old()` and find out why
      before step 2. (Tried 2026-11-23 on the local database with `--local` and one queued
      plant: `CALL`, then 0.)
   2. Copy again and switch in one transaction:
      `supabase db query --linked "begin; select billing.copy_from_old(); select billing.switch_on(); commit;"`.
      If either fails, nothing is switched: `select billing.resume_old()` and start step 6 again.
      Then `supabase db query --linked "select count(*) from private.plant_purge"` again: still 0.
      Not 0: a plant was queued between the call and the switch, and the old wipe no longer
      runs for it. Note its id on SOLAR-641 and look at that plant before step 3.
   3. `supabase functions deploy billing`. The billing function reads and writes the new tables
      (through `public.billing_v2`).
   4. Resume: `supabase db query --linked "select billing.resume_old()"`. The old tables are no
      longer the record; old paths that still write them (linking) work again. The old screens'
      plan and plant changes stay refused (`switch_on` revoked them): an app tab opened before
      the switch errors there until it is reloaded.

   `switch_on` refuses while `billing.accounts` is empty (step 4 not run). It turns reading,
   deleting and history fetches over to the new state, turns the old jobs off (`unpaid-delete`,
   `plant-wipe`, `plant-purge`, `free-trim`, `free-week-mail`, `offer-end-mail`,
   `card-expiry-mail`; the old plant wipe, stop wipe, unpaid delete and the old run's drop also
   do nothing once switched, whoever calls them), schedules `billing-history` (every minute,
   `recover?queue=1`; the new delete job waits for step 7), and turns `billing-run` back on
   (stopped in step 3), now calling the new billing function. From then
   on the old billing, free-week and history emails are not queued (0247
   `email_queue_old_billing`); notify sends their replacements from `billing.outbox`, each
   checked against the account's state when it goes. To check it:
   `select billing.alerts()`, `select * from billing.job_heartbeats` and
   `select key, status, drop_reason, count(*) from billing.outbox group by 1, 2, 3`.

   Right after step 6, before step 7, for each of today's accounts: `billing.account_state`
   shows the plan, interval, next charge date and amount, and chosen plants noted in step 5;
   `select billing.alerts()` is `[]`; `billing.job_heartbeats` has `history` from the last 10
   minutes; the health check (`/functions/v1/health`) answers 200; each chosen
   plant has a reading under 5 minutes old. Any of these wrong: go back (below), then find out why.

   If the switch has to be undone (before step 7 and before any payment in the new tables):
   1. Stop new payments, on its own: `supabase db query --linked "select billing.pause_payments()"`.
      From here no new try starts, the daily run charges nothing, and Paystack's notices and
      card-page returns are refused (Paystack sends a notice again later, to whichever billing
      is live then).
   2. `supabase db query --linked "select billing.switch_off()"`. It refuses when a payment,
      refund or Paystack notice has landed in the new tables since the switch, or a cancel,
      downgrade, interval switch or account delete was booked there ("fix forward"),
      or when a try since the switch is still open ("verify it first": the pause also stops it
      being settled, so run `billing.resume_payments()`, wait until it settles or Paystack says
      it failed, then decide again from step 1). Fix forward means: stay switched and start
      payments again, `supabase db query --linked "select billing.resume_payments()"`. Otherwise it
      puts the old jobs back as they were, stops `billing-history` and `billing-run`, lets the
      old screens' plan and plant calls work again, and answers: how many plants were deleted
      since the switch (only by an owner's own stop or login removal: the delete job has not
      started), and `since_switch`, the logins, share claims and plant choices made since the
      switch. Those went to the new tables only: for each, ask the owner to link the login,
      claim the plant or choose the plants again once the old billing is back.
   3. Deploy the old billing function from `main` before the merge: `git worktree add /tmp/solar-old <old main sha>`,
      then `supabase functions deploy billing` from that folder.
   4. Only then the daily run again:
      `supabase db query --linked "select cron.schedule('billing-run', '*/5 4-5 * * *', \$\$select private.call_fn('billing/run', '{}', 120000)\$\$)"`.
   5. `supabase db query --linked "select billing.resume_old()"` if the old tables are still paused.
   The old tables were frozen at step 6.1 and took only links after it, so they hold every
   account as it was. Plant choices made in the new tables since the switch are not carried
   back. Tried on the local database (state test Z10).
7. Frontend: push `main` (Cloudflare builds it). Every account, plan, plant-choice and
   billing screen reads `api_account_state` and the text catalog
   (`supabase/functions/_shared/text.ts`, built into `public/build/text.js`). It must not
   ship before step 6: before the switch the new tables are not the record.
   From here the switch is not undone. Start the new delete job:
   `supabase db query --linked "select billing.start_delete_job()"` (schedules `billing-delete`,
   every 5 minutes, `billing.delete_due()`). Until now nothing was deleted on a schedule.
8. After the new frontend is live and 24 to 48 hours of polls, payments and emails look right
   (`billing.alerts()` empty, no new `billing_command_failed` in PostHog):
   `supabase db push --linked` for `0252_billing_drop_old.sql` (written as 0260 in
   `supabase/after-switch-over`; pushed 2026-11-24, SOLAR-655). It refuses to run before
   `billing.switch_on()`. It drops `plant_picks`, the `held` flag, `plant_users.paused`, the
   old billing tables (`private.billing`, `billing_charges`, `free_week_logins`,
   `offer_members`, `offers`, `plant_week`), every function they feed, the old billing cron
   jobs, the one-off copy, the switch-over pause and the way back (`switch_off`), and skips old
   billing emails still queued.
   It keeps `api_offer`, now read from the billing tables, so the website keeps its prices. It
   checks that nothing left reads or calls them, or it stops.

## Changing the domain

Two places know the origin:

- **Browser → link-sunsynk (CORS).** `DEFAULT_ORIGINS` in `link-sunsynk/index.ts` lists
  app.princesolarhub.com only (SOLAR-116); princesolarhub.com no longer runs the app. A change needs
  `supabase functions deploy link-sunsynk`. Another origin can be added without a code
  change: `supabase secrets set LINK_ALLOWED_ORIGINS=https://app.example.com`.
- **Supabase Auth.** Dashboard → Authentication → URL Configuration: Site URL and
  the redirect list must include the new origin, or confirmation and reset links land on the old one.

- **www.** A Cloudflare Redirect Rule ("www to princesolarhub.com (SOLAR-113)", Rules →
  Redirect Rules) sends `https://www.princesolarhub.com/*` to `https://princesolarhub.com/${1}`
  with a 301, keeping the query. Sign-in is stored per site, so without it a www visit
  looked signed out. The www DNS record must stay proxied for the rule to run.
- **Showcase at the apex.** One Pages project answers on both princesolarhub.com and
  app.princesolarhub.com. A Cloudflare URL rewrite ("apex / shows showcase (SOLAR-116)",
  Rules → Transform Rules → URL Rewrite) serves `/welcome` when the host is
  princesolarhub.com and the path is `/`, so visitors and search engines land on the
  showcase; its sign-in links go to app.princesolarhub.com.

The cron jobs (0009, 0030) POST to `https://<project-ref>.functions.supabase.co`, which
does not change with the site's domain.

## Layout

| Path | What |
|---|---|
| `public/` | the whole frontend, published as-is |
| `public/config.js` | version + per-environment Supabase URL/key |
| `supabase/migrations/` | schema and RPCs |
| `supabase/functions/` | `poll`, `recover`, `sync-plant-energy`, `alerts-due`, `link-sunsynk` |
| `supabase/functions/_shared/` | code bundled into every function that imports it; a change here needs those functions redeployed |
| `.github/workflows/secrets-guard.yml` + `.gitleaks.toml` | fails if a secret is anywhere in the repo or its history |
| `.github/workflows/health.yml` | half-hourly logger check, emails on failure |

Project ref `pmakzojwhouamawgszrc` · app https://app.princesolarhub.com, showcase https://princesolarhub.com, on Cloudflare Pages (SOLAR-86, SOLAR-116) · GitHub Pages switched off (SOLAR-110)
