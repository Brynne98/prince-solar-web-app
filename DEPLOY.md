# Deploying

Runbook for shipping this project. Two independent halves — the frontend goes out via
GitHub Pages, the backend via the Supabase CLI — and **they do not deploy together**.

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

Then check the JSX actually parses. There is no build step — the `.jsx` is transpiled in
the browser by Babel, so a syntax error ships silently and blanks the page:

```bash
for f in public/*.jsx; do npx --yes esbuild@0.24.0 --loader:.jsx=jsx --outfile=/dev/null "$f"; done
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
> supabase functions deploy poll link-sunsynk recover sync-plant-energy forecast alerts-due
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
supabase functions deploy forecast alerts-due recover sync-plant-energy
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

Pushing to `main` triggers `.github/workflows/pages.yml`.

**It only fires on changes under `public/**` or the workflow file itself.** A docs- or
migration-only push deploys nothing, and an empty commit cannot retrigger it — it needs
a real change under `public/`.

## 5. Verify — do not assume

```bash
until curl -s "https://brynne98.github.io/prince-solar-web-app/config.js?v=$(date +%s)" \
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

## Layout

| Path | What |
|---|---|
| `public/` | the whole frontend, published as-is |
| `public/config.js` | version + per-environment Supabase URL/key |
| `supabase/migrations/` | schema and RPCs |
| `supabase/functions/` | `poll`, `recover`, `sync-plant-energy`, `forecast`, `alerts-due` |
| `.github/workflows/pages.yml` | the Pages deploy |
| `.github/workflows/health.yml` | half-hourly logger check, emails on failure |

Project ref `pmakzojwhouamawgszrc` · site https://brynne98.github.io/prince-solar-web-app
