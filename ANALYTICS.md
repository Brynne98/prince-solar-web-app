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
are sent. Every address the web app sends (`$current_url`, `$referrer`, an error's `page`,
an address inside an error message) is cut to host and path: no query, no `#` part (SOLAR-533).

## Event names

snake_case. The thing, then a past-tense verb: `plant_linked`, `theme_changed`.
A finished user action ends in `_done`: `sign_in_done`, `plant_kept_done`. Don't rename an
existing event: its history stays under the old name. A phone app sends the same name for
the same feature, so one chart covers every platform.

## Events today

Web (`public/*.jsx`):

| Event | Sent when |
|---|---|
| `screen_viewed` | A screen or tab opens (`screen`: the page id; Settings is `prefs`, `account`, `notifications`, `plants`, `billing`, `plans` since SOLAR-513) |
| `sign_up_done` | First sign-in of a new account (`method`) |
| `sign_in_done` | Signed in (`method`: `password`, `google`) |
| `sign_out_done` | Signed out |
| `email_resend_done` | Confirm or reset email sent again |
| `password_reset_sent_done` | Asked for a reset link |
| `password_reset_done` | New password set from the link |
| `email_link_done` | Confirm or reset link's button tapped and accepted (`kind`: `signup`, `recovery`; SOLAR-586) |
| `password_change_done` | Password changed in Settings |
| `feedback_sent_done` | Feedback sent from the account menu (`page`, `image`). Never the message |
| `error_toast_shown` | A red toast showed (`page`: the tab, `error_id`: the PostHog id of a browser error reported in the last 2 minutes, or null). Never the toast text: it can name a plant (SOLAR-588) |
| `plant_linked` | SunSynk login linked, or a shared plant taken |
| `share_check_done`, `link_mode_picked`, `share_taken_email_done` | Linking steps |
| `plant_switched` | Another plant picked |
| `plant_pick_done` | Locked plants ticked to run (`from`: link, plants or upgrade, `count`, `of`: how many could be ticked, `plan`, `asked`: false when one plant started with no pop-up). Not sent since SOLAR-641 |
| `plant_change_refused_done` | The owner tried to untick a running plant; picks are final while a plan runs, fixed in the free week (`plan`) (SOLAR-583). Not sent since SOLAR-641 |
| `plant_swap_email_done` | "Email us" tapped under that refusal, to swap a plant by hand (`plan`). Not sent since SOLAR-641 |
| `plant_kept_done` | Plant kept from deletion. Not sent since SOLAR-641 |
| `plant_switch_done` | Chosen plants saved in the one plant pick, after its confirm when a plant goes out (`from`: plants, link, billing, upgrade; `going`, `coming`: how many; `state`) (SOLAR-641) |
| `checkout_pick_done` | The final plant choice made before a first plan, a restart or an upgrade is paid (`plan`, `count`) (SOLAR-641) |
| `plan_start_done` | A first plan or a restart paid (`plan`, `period`) (SOLAR-641; an upgrade stays `upgrade_done`) |
| `plan_cancel_done` | Cancel plan booked (`plan`) (SOLAR-641) |
| `login_remove_done` | SunSynk login removed |
| `plant_settings_save_done` | Plant settings saved (field names only) |
| `setup_turn_on_done` | Setup card |
| `pay_wall_shown` | The pay screen shown: no plan, and the free week or the paid time is over (`plants`: plants ticked, `after`: `free_week` or `plan`; SOLAR-552) |
| `email_unsubscribe_done` | Unsubscribe pressed on `unsubscribe.html` (`kind`: the email choice, `reminders`; SOLAR-552) |
| `first_steps_hidden_done`, `first_steps_shown_done`, `first_steps_finished_done` | First steps card |
| `past_day_viewed` | A past day picked on a chart (once per page load) |
| `wall_view_opened` | Full-screen power flow opened |
| `theme_changed` | Theme picked |
| `data_download_done` | CSV downloaded |
| `plan_page_shown`, `offer_pick_done`, `checkout_opened`, `pay_review_done`, `upgrade_done` | Choosing and paying for a plan |
| `downgrade_done`, `plan_change_undone`, `extra_plants_done`, `yearly_switch_done` | Plan changes (`downgrade_done`: `plan`, `drop`; `yearly_switch_done`: `plan`, `interval`; `extra_plants_done` not sent since SOLAR-641) |
| `start_keep_done` | The plants to keep ticked before a first plan with fewer places is paid (`plan`, `kept`; SOLAR-552). Not sent since SOLAR-641 |
| `pay_first_shown` | Cancel or downgrade asked for while a payment has failed: the pay-first pop-up (`plan`, `want`: cancel or downgrade). Not sent since SOLAR-641 |
| `keep_pick_done` | Keep pick saved in Billing's Choose plant(s) pop-up while a cancel or smaller plan is booked (`plan`, `room`). Not sent since SOLAR-641 |
| `card_change_done`, `website_plan_done`, `more_plants_email_done` | Billing |
| `notice_closed`, `notice_action_done` | Account cards on Live and in the bell (`kind` since SOLAR-641: `past_due`, `must_choose`, `trial`, `trial_ends_soon`, `cancel_soon`; `notice_opened` until SOLAR-384: the phone banner's tap) |
| `free_week_card_shown` | A free-week card shown, once a session each (`stage`: `price` on Live days 1 to 4, `ends_soon` on every page days 5 to 7; SOLAR-553). Its taps and closes are `notice_action_done` and `notice_closed` with `kind` `free_week_price` or `free_week_soon` |
| `notification_opened` | An alert is tapped (`source`: `push` for a pop-up, `bell` for the bell list, SOLAR-598). `alerts_page_opened`, `alerts_filter_done`, `alerts_read_all_done` went with the full Notifications page in SOLAR-598 |
| `email_pref_change_done`, `push_pref_change_done`, `push_enabled_done`, `push_disabled_done` | Notification settings |
| `account_delete_done` | Account deleted |

Showcase (`public/welcome-track.js`, princesolarhub.co.za, SOLAR-472), no person:

| Event | Sent when |
|---|---|
| `screen_viewed` | The page opens (`stage`: `website`, `screen`: `welcome`, or a help or compare page's `<body data-screen>`: `alternative`, `feature_<topic>`, `help`, `help_<topic>`; SOLAR-216, SOLAR-490) |
| `website_section_viewed` | A section crosses the middle of the screen, once per visit (`section`: its id, e.g. `day`, `pricing`, `questions`) |
| `website_button_tapped` | `button`: `try_free`, `sign_in`, `see_pricing`, `get_home`, `get_family`; `section` it sits in, or `header` |

Functions (`track()` in `_shared/errors.ts`): `payment_failed`, `plan_cancelled`,
`account_email_sent_done` (SOLAR-641: a billing, free-week or history email from `billing.outbox` went out; `kind`: its outbox key, e.g. `receipt`, `payment_failed`, `trial_ended`, `history_deleted`. Since the switch-over it replaces `free_week_ended_email_sent_done`, `unpaid_*_email_sent_done`, `winback_email_sent_done` and the email side of `plan_cancelled`), `plants_linked_done` (SOLAR-584: a login or shared plant linked; `via`: login or share, `count`,
`seen_before`: plants that had their free week before this account was made and no other account
holds, the sign of an account deleted and made again), `plan_started_done` (SOLAR-584: a first
payment applied; `returning`: the account paid before and that plan ended, `days_since_plan`), `winback_resubscribed_done`, `winback_email_sent_done`, `need_a_hand_login_linked_done`,
`need_a_hand_email_sent_done` (`choose`: true for the SOLAR-567 version to a login whose plants
all wait to be chosen), `free_week_ended_email_sent_done` (SOLAR-475: the day-7 report that says the
free week has ended went out), `unpaid_reminder_email_sent_done` and `unpaid_last_email_sent_done`
(SOLAR-552: the two emails to an account with no plan, 14 and 27 days after its free week or
paid time ended, went out), `unpaid_deleted_email_sent_done` (SOLAR-559: the email after its
history was deleted went out). `sunsynk_calls_counted` (SOLAR-468): once a day from `poll` as
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
`partitions:readings` / `partitions:strings` (0249, as `edge:ensure-partitions`): the table has
day partitions for fewer than 6 UTC days from today (made 7 ahead), with `days_covered`.
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
  and a message of the code plus at most 80 characters of the error text with quoted values,
  bracketed values and long numbers masked (SOLAR-533),
  one issue per RPC and code (`rpc:<name>:<code>`), at most 5 per page load. One 42501 is
  reported: "permission denied ..." to a signed-in user (status 403), which means a table or
  function right is missing (SOLAR-536). A 5xx from
  sign-in, sign-up or a reset request is reported as `rpc: auth` (often a failed sign-in
  email). 4xx refusals and no connection are not sent.
- Outside: an uptime service calls `/functions/v1/health` every 5 min and emails admin@ on a
  503 (database down, or job-check silent over 15 min) (SOLAR-469). It sees no user data.
- Web: a page that throws while drawing shows "This page stopped working" with Reload
  (`PageBoundary`, `app.jsx`); the crash is reported with its component stack. A red toast
  sends `error_toast_shown` (SOLAR-588). No "Report this" link on either since SOLAR-588.
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
  calls. A kind about one day also sends `days` (`"<plant id>:<YYYY-MM-DD>"`, up to 50)
  (SOLAR-525): recover's `history_day_given_up` (a first-load day that failed 3 tries) and
  `gap_day_given_up` (the 14-day window's oldest day, still missing minutes because
  SunSynk history did not answer), sent every time, not hourly.
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
