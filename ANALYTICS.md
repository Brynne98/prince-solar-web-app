# Analytics and error reports

What the web app and the edge functions send to PostHog, and what the phone apps must
send so their data lands in the same place (SOLAR-423). PostHog holds usage events and
errors; there is no Sentry. Set up in `public/config.js` (web) and
`supabase/functions/_shared/errors.ts` (functions).

## One project, split by platform

PostHog project: EU cloud, host `https://eu.i.posthog.com`, project key `POSTHOG_KEY` in
`public/config.js` (public by design). Web, functions and phone apps all send here.

Every event and error carries:

| Property | Value |
|---|---|
| `app` | `prince-solar-hub` (the project is shared; filter on this) |
| `platform` | `web`, `ios`, `android` or `edge` (a function) |
| `app_version` | The release: `APP_VERSION`, e.g. `v0.49.7` |

The person is the Supabase user id (`auth.users.id`) and nothing else. Signed out, the
id is anonymous. Function events with no user use `edge:<function>`.

Never send an email, a name, a SunSynk login, a token, or a reading (power, energy,
battery, voltage) as a property. Error messages have email addresses masked before they
are sent.

## Event names

snake_case. The thing, then a past-tense verb: `plant_linked`, `theme_changed`.
A finished user action ends in `_done`: `sign_in_done`, `plant_kept_done`. Don't rename an
existing event: its history stays under the old name. A phone app sends the same name for
the same feature, so one chart covers every platform.

## Events today

Web (`public/*.jsx`):

| Event | Sent when |
|---|---|
| `screen_viewed` | A screen or tab opens (`screen`) |
| `sign_up_done` | First sign-in of a new account (`method`) |
| `sign_in_done` | Signed in (`method`: `password`, `google`) |
| `sign_out_done` | Signed out |
| `email_resend_done` | Confirm or reset email sent again |
| `password_reset_sent_done` | Asked for a reset link |
| `password_reset_done` | New password set from the link |
| `password_change_done` | Password changed in Settings |
| `feedback_sent_done` | Feedback sent from the account menu or "Report this" (`page`, `image`, `report`: true or false, `error_id`: the PostHog error id or null). Never the message |
| `plant_linked` | SunSynk login linked, or a shared plant taken |
| `share_check_done`, `link_mode_picked`, `share_taken_email_done` | Linking steps |
| `plant_switched` | Another plant picked |
| `plant_stop_done`, `plant_start_done`, `plant_kept_done` | Plant stopped, started, kept from deletion |
| `login_remove_done` | SunSynk login removed |
| `add_login_full_done` | Add plant pressed on a full plan |
| `plant_settings_save_done` | Plant settings saved (field names only) |
| `setup_turn_on_done`, `free_week_card_done` | Setup and free-week cards |
| `first_steps_hidden_done`, `first_steps_shown_done`, `first_steps_finished_done` | First steps card |
| `past_day_viewed` | A past day picked on a chart (once per page load) |
| `wall_view_opened` | Full-screen power flow opened |
| `theme_changed` | Theme picked |
| `data_download_done` | CSV downloaded |
| `lock_tapped` | A paid-only lock tapped |
| `plan_page_shown`, `offer_pick_done`, `checkout_opened`, `pay_review_done`, `upgrade_done` | Choosing and paying for a plan |
| `downgrade_done`, `plan_change_undone`, `extra_plants_done`, `yearly_switch_done` | Plan changes |
| `card_change_done`, `website_plan_done`, `more_plants_email_done` | Billing |
| `notice_closed`, `notice_action_done` | Billing cards (`notice_opened` until SOLAR-384: the phone banner's tap) |
| `alerts_page_opened`, `alerts_filter_done`, `alerts_read_all_done`, `notification_opened` | Alerts list and pop-ups |
| `email_pref_change_done`, `push_pref_change_done`, `push_enabled_done`, `push_disabled_done` | Notification settings |
| `account_delete_done` | Account deleted |

Showcase (`public/welcome-track.js`, princesolarhub.co.za, SOLAR-472), no person:

| Event | Sent when |
|---|---|
| `screen_viewed` | The page opens (`stage`: `website`, `screen`: `welcome`, or a help or compare page's `<body data-screen>`: `alternative`, `feature_<topic>`, `help`, `help_<topic>`; SOLAR-216, SOLAR-490) |
| `website_section_viewed` | A section crosses the middle of the screen, once per visit (`section`: its id, e.g. `day`, `pricing`, `questions`) |
| `website_button_tapped` | `button`: `try_free`, `sign_in`, `see_pricing`, `get_home`, `get_family`; `section` it sits in, or `header` |

Functions (`track()` in `_shared/errors.ts`): `payment_failed`, `plan_cancelled`,
`winback_resubscribed_done`, `winback_email_sent_done`, `need_a_hand_login_linked_done`,
`need_a_hand_email_sent_done`, `free_week_ended_email_sent_done` (SOLAR-475: the day-7 report that says the
free week has ended went out). `sunsynk_calls_counted` (SOLAR-468): once a day from `poll` as
`edge:poll`, no person; yesterday's SunSynk calls, failed calls, calls per plant and slowest
poll run, from `private.sunsynk_calls` (0178). No user data.

Job checks (SOLAR-428, `job-check`, every 5 min from pg_cron, 0180), no person:
`job_check_failed` and `job_check_recovered` once each time a check changes state, as
`edge:<job>` (`edge:poll`, `edge:notify`, `edge:sunsynk`, `edge:<cron job name>`), with
`check` (`poll:s<n>`, `cron:<job>`, `sunsynk`, `email-queue`) and its numbers; a cron
failure carries the first 200 characters of pg_cron's message, emails masked.
`call:<fn>` (SOLAR-472): the last answered timed call to poll, notify, billing, recover,
sync-plant-energy or job-check was not 2xx, timed out, or had no answer 2 min past its
timeout. The cron jobs call through `private.call_fn` (0181), which keeps each pg_net
request id in `private.fn_calls`, joined to `net._http_response`. `signin-email`
(SOLAR-469): a sign-in email sent in the last hour was UNDELIVERABLE, REJECTED or EXPIRED
in Infobip's email logs (`INFOBIP_API_KEY`, `INFOBIP_BASE_URL`); recovers after a clean hour.
`job_check_ran` once a run as `edge:job-check`, with the checks still failing. PostHog
alerts: "Timed job failed or recovered" (hourly) and "Job check stopped running" (no run
in 15 min).

Not sent on purpose: menu opens, hovers, day arrows after the first, chart series toggles.

## Errors

- Web: uncaught errors and failed promises go to PostHog error tracking (`$exception`),
  each message once per page load, at most 20 (`public/config.js`). PostHog reads the
  public `build/*.js.map` files to show the source lines.
- Web: an error with no code location (a thrown string, "Script error.") is grouped by its
  message (`$exception_fingerprint` `message:<text>`), so a new one opens a new issue (SOLAR-472).
- Web: a Supabase call that fails on the server (5xx, or a Postgres error other than a
  deliberate refusal: classes 22, 23, 28, P0 and 42501) is reported by `must()` in `data.jsx`
  through `reportServerError` in `config.js`, with `rpc` (RPC or table), `code` and `status`,
  one issue per RPC and code (`rpc:<name>:<code>`), at most 5 per page load. A 5xx from
  sign-in, sign-up or a reset request is reported as `rpc: auth` (often a failed sign-in
  email). 4xx refusals and no connection are not sent.
- Outside: an uptime service calls `/functions/v1/health` every 5 min and emails admin@ on a
  503 (database down, or job-check silent over 15 min) (SOLAR-469). It sees no user data.
- Web: a page that throws while drawing shows "This page stopped working" with Reload and
  Report this (`PageBoundary`, `app.jsx`); the crash is reported with its component stack.
  Red toasts offer "Report this" too. Both open the feedback box with the error and its
  PostHog id.
- Functions: anything a handler throws (`serve()` in `_shared/errors.ts`), with the
  signed-in user's id when the request has one.
- Functions, caught failures (SOLAR-336): a failure the code handles and carries on from
  calls `noteError(kind, error, {user, plant, ref, hourly})`. `serve()` sends them when the
  request ends, one `$exception` per kind with `kind`, `count`, `plant_ids` (up to 50) and
  `reference` (a payment reference), fingerprinted `<function>:<kind>` so each kind is its
  own issue. `hourly: true` kinds (SunSynk calls, Resend, email sweeps) go at most once an
  hour, kept in `app_config`; billing kinds go every time. Covered: billing (refunds,
  wrong currency or amount, payment not applied, disputes, webhook, daily run, pay),
  claim-share and link-sunsynk 502s (not a wrong password), poll, notify (retryable Resend
  errors as `resend_<status>`, emails given up as `email_failed`, push), recover, SunSynk
  calls.
- Alerts: a new or reopened issue calls `error-alert` (PostHog webhook with the
  `x-alert-key` secret header, `ERROR_ALERT_KEY`), which emails admin@theronprince.co.za.
  The insight alerts above and "Web app errors jumped" email admin@ from PostHog.
- `app_version` is the release. The functions' copy in `_shared/errors.ts` must match
  `public/config.js`; `npm test` fails when it doesn't.

## Phone apps (Expo)

Each app (iOS and Android from one codebase) must:

1. Use `posthog-react-native` with the same project key and host
   `https://eu.i.posthog.com`.
2. Register `app: 'prince-solar-hub'`, `platform: Platform.OS` (`ios` or `android`) and
   `app_version` (the app's version, same `vX.Y.Z` form) on start.
3. `identify(<Supabase user id>)` on sign-in, `reset()` on sign-out. No person properties.
4. Turn off autocapture and session replay. Send `screen_viewed` with `screen` by hand,
   using the web's screen names where the screen is the same.
5. Send the event from the table above for every feature it shares with the web. A
   phone-only feature gets a new name by the rule above, and a line in this file.
6. Turn on exception capture, and upload the Hermes source maps for each build with
   `posthog-cli`, tagged with `app_version`.
7. Never send the properties listed under "One project".
8. Name PostHog and what it collects in the store privacy labels (usage data, crash
   data, user id; not linked to identity beyond the account id).
