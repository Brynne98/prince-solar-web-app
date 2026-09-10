# Launch readiness — 6 Sep 2026

What stands between the current deployment (live for one plant) and a stranger
signing up. Web-only PWA, so app-store items do not apply. Sections follow the
indie launch checklist.

## State on 6 Sep 2026

- Production is live: all 35 migrations match remote, GitHub Pages serves the
  app, `api_health` read 8 s fresh.
- Sign-up, password reset, the SunSynk connect screen, per-user isolation
  (RLS via `plant_users`), per-plant config and account deletion all exist.
- Multi-tenancy has only ever been verified on the owner's own plant.

## Checklist

| # | Section | Result | Next fix |
|:-:|---|:-:|---|
| 1 | Scope | pass | One job: connect SunSynk, see your dashboard. Backlog is in `FEATURES.md`. |
| 2 | Identity | partial | Add Google sign-in. Run the full new-user round trip on production with a non-team email: sign up → confirm → sign in → connect → sign out → sign in → delete. |
| 3 | Analytics | fail | No product analytics or crash reporter. Add PostHog with three events: `signup_completed`, `plant_linked`, `dashboard_viewed`. Add Sentry or equivalent. |
| 4 | Payments | pass (for now) | Free service. `profiles.plan` exists for later. Stripe when needed. |
| 5 | Legal / trust | fail | `public/legal.jsx` is placeholder copy, flagged on screen. Review and replace. Add a support link and contact email inside the app (Settings → About). |
| 6 | Onboarding | partial | Path is short (sign up → connect → dashboard). Gaps: an account with no visible plants gets a one-line warning and no "ask your installer to share the plant" guidance; the forecast card reads "unavailable" for every plant except the calibration plant. |
| 7 | Distribution | fail | `public/manifest.webmanifest` `start_url` is `/`, which on GitHub Pages is a 404 — installed PWAs open a dead page. `orientation: landscape` blocks portrait on phones. No custom domain; `link-sunsynk` CORS allow-list is hardcoded to `brynne98.github.io`. |
| 8 | First week | fail | No dashboards, no bug-report path. Depends on 3 and 5. Schedule a metrics review a week after the first outside user. |

## Blockers outside the checklist

- **Auth email.** Supabase's built-in mailer only sends to project team members
  and a few per hour. Sign-up confirmation and password reset for anyone else
  need a custom SMTP provider set in the Supabase dashboard (Auth → SMTP). Also
  confirm Site URL and redirect URLs there include the production origin.
- **SunSynk app key terms.** The app key/secret was issued to the owner. Whether
  SunSynk permits polling other people's accounts with it, and the rate limit
  across accounts, is not written down. Email SunSynk support before inviting
  anyone. See memory: one poll per minute per inverter is known fine.
- **Cost per customer.** ~450 MB per inverter per year of storage; one poll per
  minute per inverter. No plan cap or per-user limit exists.
- **Single-site features.** `forecast` and the clear-sky potential line are
  fitted to the calibration plant only. Alert delivery lives in `prince-todo-app`,
  so other users get no alerts.

## Order of work

1. Fix `manifest.webmanifest` start URL and orientation.
2. Custom SMTP; run the production sign-up round trip with an outside email.
3. Support email in-app; real terms and privacy copy.
4. PostHog + crash reporting with the three events above.
5. One real second user (own SunSynk login) end to end.
6. Then: Google sign-in, custom domain, per-plant forecast, alerts for all users.
