# Deploying

Runbook for shipping this project. Two independent halves — the frontend goes out via
Cloudflare Pages (app.princesolarhub.com; showcase at princesolarhub.com), the backend via the Supabase CLI — and **they do
not deploy together**.

> The deploy thread ships and verifies. It does not write feature code. Broken builds,
> leftover debug code, uncommitted work or migration drift get reported, not fixed.
> The one file it edits is `public/config.js`, to bump the version.

---

## Order

**Backend first, frontend second.** New UI must never call an RPC that isn't there yet.
Migrations and Edge Functions are backward-compatible with the old frontend; the reverse
is not true.

---

## 1. Pre-flight

```bash
git status --short                  # must be clean at the end, not the start
git log --oneline origin/main..HEAD # anything unpushed?
supabase migration list             # Local and Remote columns must match
grep -rn "TEMPORARY\|console.log\|debugger" public/ supabase/functions/
```

Then build. `npm run build` compiles `public/*.jsx` into `public/build/*.js` with the same
Babel settings the browser used to apply (SOLAR-131). It exits 1 on a syntax error; Cloudflare
runs the same build and keeps the last good deploy live if it fails:

```bash
npm run build
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
supabase db push                                  # pending migrations
supabase functions deploy poll                    # only what changed
supabase functions deploy alerts-due recover sync-plant-energy
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
# expect {"stale": false, "ageSeconds": <small>}
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
