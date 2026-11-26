# Rework step 1: foundations

SOLAR-679, part of SOLAR-678. Signed by Brynne 2026-11-26.

Tooling only. No product behaviour changes. Users see nothing. Interfaces for payment,
email and brand are not built here; each comes with its first real user in steps 2–5.

## What this step owns

- `.github/workflows/` (test and nightly workflows); `scripts/release.mjs` (the release)
- `supabase/schemas/` (new: one file per database function)
- `supabase/config.toml` (`schema_paths`)
- `scripts/` test runners and the guardrail check (`scripts/reuse-check.mjs`)
- Frontend build: `package.json`, `vite.config.*`, `public/index.html` script tags
- `DEPLOY.md` (rewritten for the new release path)
- A second Supabase project (staging) and a Better Stack account (free plan)

## Rules

Each rule has the check that proves it. The step is done when every check passes.

**Release**

- **F1. Every push runs all tests.** Node tests, Deno `*_test.ts` (13 files today, run by
  nothing), SQL state tests (`npm run test:state`, `scripts/sql/*-tests.sql`) against a
  fresh local database in CI.
  *Check:* a deliberate failing test on a branch turns the run red.
- **F2. A red run cannot reach production.** Cloudflare's build-on-push is turned off.
  Production publishes only through the release script, which needs the commit's checks green.
  *Check:* push a commit with a failing test; the live site does not change.
- **F3. Release order is fixed: database, functions, frontend, from one commit.** The
  release script (`npm run release`) runs from Brynne's Mac, on his say-so; no production key
  lives in GitHub (changed 2026-11-26: he is the only developer).
  *Check:* one release run to production (after a backup, on Brynne's say-so), log shows
  the three stages in order.
- **F4. Long tests run nightly, not per push.** Billing simulator, abuse and scale runs.
  *Check:* nightly run present and green once.

**What runs is readable**

- **F5. Every database function has one file** under `supabase/schemas/functions/<schema>/<name>.sql`,
  holding its full current body, taken from production.
  *Check:* count of files = count of live functions.
- **F6. CI fails when a live body differs from its file.** Build a database from all
  migrations, compare every function body to its file.
  *Check:* hand-edit one function in a migration only; CI turns red.
- **F7. No migration patches function text.** `pg_get_functiondef` plus `replace` is
  banned in new migrations.
  *Check:* guardrail rule in `reuse-check.mjs`; a test migration using it fails.
- **F8. Tables, grants, partitions and cron stay in numbered migrations.** Supabase's diff
  tool does not track partitions or column grants, so only functions go declarative.
  *Check:* written in `DEPLOY.md`; the diff of a schema-only change produces no
  function noise.
- **F9. Types are generated from the database** (`supabase gen types typescript`) and
  checked in; CI fails if they are stale.
  *Check:* change a function's arguments without regenerating; CI turns red.

**Staging (local until paying customers)**

Decided 2026-11-26: no paid staging project yet. With only Brynne and his father on
production, production is where the last checks run, after a backup. A paid staging project
is a launch requirement (SOLAR-678): it goes in before sign-ups open.

- **F10. A local staging setup runs in CI and on this machine:** fresh local Supabase, the
  fake SunSynk, Paystack test key, Resend as mail sender, no live user data. Data moves are
  rehearsed on a local copy of production data. A tunnel carries Paystack test notices when
  needed.
  *Check:* in a local run, sign up, link a fake plant, pay with a test card.
- **F11. No database or function names the production address.** Cron jobs and
  `private.call_fn` read the project address from settings (absorbs SOLAR-670).
  *Check:* on a local database, `cron.job` and function logs show only local calls.

**Knowing when it breaks**

- **F12. A stopped reader or a failed job pages Brynne's phone within 5 minutes.**
  Better Stack heartbeats on the reader, `job-check` and the billing clock; uptime check on
  `health`. The 30-minute GitHub check stays as a backup.
  *Check:* send a test heartbeat miss from production (no real outage needed); the phone
  alert arrives.
- **F13. Bounced and spam-flagged mail is recorded and not sent again.** Resend webhook
  for bounced, complained and suppressed; the address is marked and skipped.
  *Check:* send to Resend's bounce test address on staging; the next send to it is skipped.
- **F14. Mail sends at the speed the provider allows,** read from its rate-limit reply,
  not a fixed 550 ms wait (`notify/index.ts:34`).
  *Check:* a batch on staging finishes in the expected time with no rate-limit errors.

**Frontend build**

- **F15. The frontend builds with Vite and ES modules.** No shared global scope, no
  runtime scripts from unpkg or jsDelivr, no Babel regex patches (`build-jsx.js:41-66`).
  *Check:* `npm run build` exit 0; the CSP lists no CDN script hosts.
- **F16. JavaScript is type-checked** (`checkJs`), with generated database types.
  Conversion to TypeScript happens file by file in later steps.
  *Check:* a call to a missing function fails the build.
- **F17. Pages look the same before and after.** Every page at phone and desktop width,
  light and dark.
  *Check:* before-and-after screenshots match.
- **F18. supabase-js in the browser matches the functions' version,** and the private
  `_removeSession` / `_notifyAllSubscribers` calls in `auth.jsx:725,741` are gone.
  *Check:* sign in, sign out, expired session on staging.
- **F19. Source maps go to PostHog privately,** not to the public.
  *Check:* `/build/*.map` returns 404 on the live site.

**Guardrails for agents**

- **F20. Hard-coded market and vendor strings are blocked** outside their own files:
  `Africa/Johannesburg`, `ZAR`, `sunsynk`, `paystack`, `resend`, `infobip`. Existing
  uses are listed as known and shrink as each step removes them.
  *Check:* a new use in another file fails `npm test`.

## Order of work

1. F1, F4, F7, F20: tests and guardrails in CI (nothing deploys yet).
2. F5, F6, F8, F9: one file per function, drift check, types.
3. F10, F11: local staging setup, production address removed.
4. F2, F3: release script, Cloudflare build-on-push off.
5. F12–F14: paging, bounces, send speed.
6. F15–F19: Vite. Last, because other threads are changing `public/*.jsx` now
   (SOLAR-648, 661, 642, 659, 637); it starts once those are merged.

## Costs

| Item | Cost a month |
|---|---|
| Staging Supabase project | $0 now (local); about $10 from launch (assumed; confirm before creating) |
| Better Stack | $0 (free plan: 10 monitors, 10 heartbeats) |
| GitHub Actions | $0 at this size (assumed) |
| Vite, type-check | $0 |

## Needs Brynne

- Signed 2026-11-26 (rules F1–F20).
- Create the Better Stack account when asked (sign-ups are his).
- Each production release stays on his say-so.

## Case against

About 1–2 weeks with no visible change. The drift check and declarative functions are new
to this repo, and Supabase's diff tool has known gaps; F8 limits it to functions to avoid
them.
