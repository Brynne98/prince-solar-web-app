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
| `notice_opened`, `notice_closed`, `notice_action_done` | Billing banners |
| `alerts_page_opened`, `alerts_filter_done`, `alerts_read_all_done`, `notification_opened` | Alerts list and pop-ups |
| `email_pref_change_done`, `push_pref_change_done`, `push_enabled_done`, `push_disabled_done` | Notification settings |
| `account_delete_done` | Account deleted |

Functions (`track()` in `_shared/errors.ts`): `payment_failed`, `plan_cancelled`,
`winback_resubscribed_done`, `winback_email_sent_done`, `need_a_hand_login_linked_done`,
`need_a_hand_email_sent_done`. `sunsynk_calls_counted` (SOLAR-468): once a day from `poll` as
`edge:poll`, no person; yesterday's SunSynk calls, failed calls, calls per plant and slowest
poll run, from `private.sunsynk_calls` (0178). No user data.

Not sent on purpose: menu opens, hovers, day arrows after the first, chart series toggles.

## Errors

- Web: uncaught errors and failed promises go to PostHog error tracking (`$exception`),
  each message once per page load, at most 20 (`public/config.js`). PostHog reads the
  public `build/*.js.map` files to show the source lines.
- Functions: anything a handler throws (`serve()` in `_shared/errors.ts`), with the
  signed-in user's id when the request has one.
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
