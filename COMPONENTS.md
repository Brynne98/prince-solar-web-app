# Components

What the app already has. Before you build a piece of UI or write a helper, look here.
If something here is close, use it or give it a prop; don't make a second one.

`node scripts/reuse-check.mjs` (part of `npm test`) catches the common repeats: native
`<select>`, date inputs and checkboxes, `title=` tooltips, raw `.skel`, `confirm()` and
`alert()`, hand-drawn copies of icons, hand-made tooltip rows, meters, sign-in cards,
timeouts and saved-tab reads, CSS classes nothing uses, two files declaring the same
top-level name, a hidden or recoloured focus ring, an icon off the icon line or sizes, a transition or animation not timed with `--dur-*` and `--ease-*`, and a "Click here" email link. A line can opt out with a `reuse-check: allow` comment; give the reason
next to it.

How it is wired: every `public/*.jsx` shares one global scope. `auth`, `link`, `data`,
`components` and `app` load first; `flow`, `chart` and `tabs` load later, on demand.
So anything an early file needs lives in an early file. An early file reaching for
something in a late file calls it as `window.X` at run time, never at load.

Look and feel (sizes, colours, radii) is in `DESIGN.md`. This file is about code.

## Building blocks (`components.jsx`)

| Name | Use it for |
|---|---|
| `Card` | Any panel. Passes `className`, `style` and the rest through. |
| `StatTile` | A big number with label, unit, sub-line, optional `bar` and `loading`, `locked`. |
| `Segmented` | A row of 2 to 5 options, one selected. `block` fills the row. |
| `Switch` | An on/off control in a row. `busy`, `loading` (shows a skeleton). |
| `Toggle` | A labelled checkbox-style choice with a `hint`. `loading`. |
| `BusyButton` | A button whose text swaps while it works: `busy`, `busyText`. |
| `LegendChip` | A chart series chip that turns a series on and off. |
| `SectionTitle` | A heading with something on the `right`. |
| `Tip` | Hover or tap help on any element. Use instead of `title=`. |
| `InfoDot` | The small (i) with a `Tip`. |
| `TipRow` | One line in a chart tooltip: `color`, `label`, value as children; `sq` for a square key. |
| `Meter` | A thin progress bar: `pct`, `color`. |
| `Skeleton` | A loading shape: `w`, `h`, `r`, `as`. |
| `SkelLine` | A one-line text skeleton: `w`, `h`, `max`. |
| `LockIcon` | The lock beside a locked plant's name. |

Formatting and dates (also `components.jsx`):

| Name | Gives |
|---|---|
| `fmtPower`, `fmtPowerParts` | W/kW text, or `[number, unit]`. |
| `fmtKwh`, `fmtEnergySmart`, `fmtEnergyParts` | kWh text, or `[number, unit]`. |
| `fmtMoney`, `fmtMoneySmart`, `moneySymbol` | Money in the user's currency. |
| `fmtTime`, `fmtPlantTime`, `plantHour` | Times, in the plant's time zone where it matters. |
| `fmtDuration(mins)` | "2h 5m", "12 min". |
| `localDateStr(d)` | Today, or `d`, as `YYYY-MM-DD` in local time. |
| `plantDateStr(tz, d)` | Today, or `d`, as `YYYY-MM-DD` at the plant (`tz`, e.g. `window.PLANT_TZ`); local time when `tz` is unknown. Every day picker opens on it. |
| `shiftDate(s, days)` | A `YYYY-MM-DD` moved by whole days. |
| `dayText(s, opts)` | A `YYYY-MM-DD` as "Mon 3 Nov", or with your own `Intl` options. |
| `plantLabel(p)` | A plant's name, or "Plant 123". |
| `battShown`, `cleanTemp` | Battery power and temperatures with sensor junk removed. |
| `COLORS` | The series colours as `var(--…)`, so charts follow the theme: solar, home, grid, battery, charge. |
| `COLORS_TEXT` | The same colours for small text (a darker shade in light, SOLAR-427). |

## Account text and state (`supabase/functions/_shared/text.ts`, `link.jsx`)

Every line about accounts, logins, chosen plants, plans, prices, billing, the free week and
history kept or deleted, on a screen or in an email, comes from the text catalog, filled only
from the account's state. No count, price, plan name or date is worked out in JSX or email
code (SOLAR-641; `npm test` refuses the old billing reads, `PLAN_NAME` and hand-made prices).

| Name | Use it for |
|---|---|
| `AccountText` (`AT`) | The catalog: `_shared/text.ts`, typed, with zero/one/many forms. `npm run build` makes `public/build/text.js` (`window.AccountText`); notify imports the file itself. `money`, `day`, `forms`, `names` are its only formatters. A new line goes here. |
| `useAccount()`, `reloadAccount()` | The signed-in account's state (`api_account_state`, 0247), read once and shared; `reloadAccount` reads it again and tells every screen. |
| `ChooseDialog` | The one plant pick (link.jsx): `mode` `choose` (Plants, after a link, after a payment), `checkout` (the final choice before paying), `keep` (a smaller plan's plants). Which changes are confirmed in `SwitchConfirm`: `pickNext`. |
| `acctLogins(acct, keep)` | The account's plants under their logins, in `KeepPicker`'s shape. |
| `pickLogins(acct, mode)`, `pickNext(mode, going, coming)`, `pickWaiting(acct)` | What a pick lists (every plant, deleted ones too; `keep`: the chosen), when its button confirms first, and whether the pick after a payment opens (link.jsx). Tested in `scripts/billing-screen-test.mjs`. |
| `planRows(acct, view)`, `planStep(acct, row)` | The plans pop-up's rows for the monthly/yearly switch (a running plan changes plan at its own interval) and what a plan's button does first (`interval`, `keep`, `checkout`; `pick: false` goes on with no plants) (tabs.jsx). |
| `startPlan`, `bookChange`, `settlePayment`, `changeCard` | Pay for a plan or an upgrade (quote, review, card page), book or undo a change for the billing date, pay a failed renewal, change the card. |
| `outboxMail(m, unsub)` | An outbox email (`AccountText.mail`) laid out in `_shared/email.ts`'s look. |
| `alertLine(row)`, `alertPush(kind, line, plant, plants)`, `alertMail(event, plant, on)` | Every alert's words (SOLAR-645): the bell list's title, body, time and page from an `api_alerts` item's facts (`data`, `created`, `tz`), the pop-up's title and body, and the alert and login emails' parts. The database sends facts only (0264). `alertEmail(m, plantId)` in `_shared/email.ts` lays an email out; `popup(r)` in `notify/index.ts` builds a pop-up. Tested in `_shared/alerts_test.ts`. |

## Reading inverters (`supabase/functions/_shared/poller.ts`, `_shared/db.ts`)

The per-minute reading of a login, for any host that runs the poller (SOLAR-656).

| Name | Use it for |
|---|---|
| `pollAccount(acc, jobs, ts)` | Read every inverter of a login's plants for one minute and save it (`poll_commit_v2`). `fetchInverter`, `readingRow`, `carryAllowed`, `canCarry`, `uploadNotDue`, `wantEndpoints`, `fetchInto`, `bankTodayTemps` are its steps. |
| `readAccount(acc, jobs, ts, opts)` | The read half of `pollAccount`: the row to save (`CommitRow`, `poll_commit_batch`'s shape) and `finish(committed)` for what follows the save. `opts.cached` takes inverters read for many logins at once; `opts.lead: false` leaves the list refresh and plant sync to another read of the login. |
| `accountFailed(acc, jobs, e)`, `emailOutcome(result)` | A login whose read or save threw (marked, noted), and how a login's minute counts for `email_poll_step`. |
| `rpc(fn, args)`, `dbHandle()`, `useDb(handle)` | The database the SunSynk and reading code use: PostgREST (`postgrest`) unless a host gives its own `Db` once at start. `db` (supabase-js) stays for the callers outside the reading path. |
| `directDb(url)` (`_shared/pgdb.ts`) | A `Db` over one direct Postgres connection, answering as PostgREST does. For the always-on poller (stage 2); nothing uses it yet. |
| `setFleetCap(n)`, `watchCalls(f)` (`_shared/sunsynk.ts`) | A cap on SunSynk calls in flight across logins, and a listener on every call's time and result. |

## Fake SunSynk (`supabase/functions/_shared/mock-fetch.mts`)

| Name | Use it for |
|---|---|
| `mockFetch(base, idOffset, url, init)` | Answers a fake (`@mock`) SunSynk call inside the function, with no network call. `_shared/sunsynk.ts` uses it for every fake call in production (SOLAR-637). |

## Forms and sign-in (`auth.jsx`)

| Name | Use it for |
|---|---|
| `AuthCard` | A signed-out card: `title`, `sub`, `onSubmit`, `busy`. |
| `FieldLabel` | A field's label with its error or hint on the same row. |
| `useFieldErrors()` | `{ bad, setBad, flag, edited }`: which fields are wrong, cleared on edit. |
| `invalidProps` | `aria-invalid` and `aria-describedby` for a field. |
| `PasswordInput`, `PasswordField` | A password box with the eye, bare or with label. |
| `BotCheck` | Cloudflare's bot check box: `hold` (a ref; `await hold.current?.()` gives the `captchaToken` for a Supabase sign-in, sign-up, reset or resend), `quiet` (shown only when a tap is needed). Any new call to those needs one. No token (script blocked, no tap in 10 s): gives `undefined`, the call goes and Supabase decides. |
| `SignOutButton`, `signOutHere` | Sign out, as a button or a call. |
| `checkSession` | Moves a tab to sign-in when its session ended elsewhere or its account is gone. Runs when a tab is back on screen and when `must()` fails. |
| `explainAuthError` | A Supabase auth error as a sentence for people. |
| `restoreDeepLink` | An email's `?tab`, `?section`, `?plant`, `?pay`, `?add`, kept a day at load and put back in the address once signed in. A new deep-link key goes in `DEEP_KEYS`, not a keeper of its own. |

## Dialogs and SunSynk (`link.jsx`)

| Name | Use it for |
|---|---|
| `Dialog` | Any modal. `label`, `onClose`, `keep` (no outside-click close), `busy` (dims, blocks closing), `size`. With `onClose` it draws its own X (`.pop-x`) top right (SOLAR-516); never add a second close button. No `onClose` (the working spinner): no X. A phone shows the same centred box, and the page behind an open pop-up does not scroll (SOLAR-521). |
| `LinkForm` | The SunSynk sign-in form, inline (`compact`) or as a card. |
| `LinkDialog` | `LinkForm` in a `Dialog` with a `title` and `note`: add a plant, re-link, change login. |
| `PayReview` | The review before a saved card is charged: `r` is `AccountText.quoteReview`'s title, due and lines, `card` the saved card. Its `.pay-review-box` is also Billing's darker box. |
| `withTimeout(call, ms)` | A Supabase call that must give up: after `ms` it resolves as `{ data: null, error: { message: 'timed out' } }`. |
| `edgePost(path, body, signal)` | A POST to one of our edge functions as the signed-in user; returns `[response, json]`. |
| `mountNode(node)` | Render something into its own root outside the app (dialogs opened from plain code). |
| `payFailed(e, fallback)` | The toast for a payment or a booked change that failed, in `AccountText.refused`'s words. |

## Data (`data.jsx`)

Every Supabase read and write goes through a `fetch*` or `save*` here; don't call
`window.sb` from a screen. New ones use `must(call, fallback, failed)`, which throws on
an error and returns `fallback` when there is no row. `fetchFlags` and `saveFlag` cover
a row of on/off settings (email and push preferences); `saveFlag` sends its own event. `emptyText` is the message for a plant with no data yet.
`dayFor(day, date)` is a `fetchDay` series only when it is that day's (just past midnight today's can
still be yesterday's, SOLAR-648); `realPoints(day)` counts its buckets with a reading (a line needs two).
`dayPeak(day, 'pv' | 'load' | 'grid')` is the day's top minute and its time (SOLAR-676); never scan the 5-minute points for a peak.
Errors go to PostHog through `config.js`: `window.reportClientError(err, props)` for a
crash, `window.reportServerError(name, error, status)` for a failed Supabase call (`must()`
and the sign-in screens already call it; it drops refusals and offline).

## The shell (`app.jsx`)

| Name | Use it for |
|---|---|
| `Icon` | Any icon in `NAV_ICONS`: `<Icon id="next" />`. Add new icons to `NAV_ICONS`, not inline. A drawn icon elsewhere is `<svg className="ico">` (`ico-sm` for 14 px) with no width, height or strokeWidth of its own. |
| `useEscape(on, fn)` | Close something on Escape. |
| `usePopover()` | A menu or popover's open state, outside-click and Escape. Stays open while it leaves. |
| `useExit(on)` | `[shown, leaving]`: keeps a closing pop-up on screen for `--dur-fast` so its CSS can play it out. |
| `motionMs(name)` | A `--dur-*` step in ms; 0 under reduced motion. |
| `MenuList`, `PickMenu` | A dropdown menu; `PickMenu` is the replacement for `<select>`. |
| `Sheet` | A phone bottom sheet. |
| `StatusBits` | The word of a status pill; no dot (SOLAR-556). |
| `fmtAgo`, `readAgo`, `useNow` | "5 min ago", "Read 2 h ago", a ticking clock. |
| `plantStatus` | A plant's status word and tone from its last reading. |
| `StepField` | A number box with a unit, as in First steps. |
| `stepNum`, `wholeNum`, `cfgFields`, `sumPatch` | Reading, checking and saving system config (size, panels, reserve, rate). |
| `savedTab`, `writeTab`, `TAB_KEY` | The last tab and plant, kept across visits. `writeTab` adds a history entry for a new page; pass `replace` for a change the app made itself. |
| `usePageHistory(tab, plant, onBack)`, `usePageTitle(tab)` | The address follows the page and Back/Forward show the entry's page; the browser tab reads "Solar · Prince Solar Hub" (SOLAR-515). |
| `window.toast(text)` | A short message in the bottom-right corner (bottom middle on phones). Use instead of `alert()`. The first sentence shows bold; any sentences after it go on the line below (SOLAR-638). `{ error: true }` for a failure (red), `{ info: true }` for a note that is neither (no tick). One sent just before sign-out shows on the sign-in screen. A red one sends `error_toast_shown` (SOLAR-588). Goes after 5 s; one with a link stays until closed (×, Esc). A click on any toast closes it. |
| `PageBoundary` | Wraps each page in `Frame`: a crash shows a card with Reload, not a blank screen, and goes to PostHog. |
| `openFeedback(report)` | The feedback box; `report` = { text, id } makes it "Report a problem" with the error attached. |
| `NotifRows` | Alert cards under day headings in the bell list, laid out as the phone pop-up: kind icon, the plant's name on its own top line (2+ plants), title and time, then the numbers; a tap opens the alert's page (SOLAR-598). Billing notices (`NoticeRows`) lead the Today group, same card with a button (SOLAR-353). The full Notifications page went in SOLAR-598. |
| `acctNotices`, `BillCards` | The account's notices (`AccountText.notices`: failed payment, plants to choose, the free week, a cancel's last days) with their actions; the cards at the top of Live only, and the bell's Today (SOLAR-641). On a phone each card shows `short` and `bodyShort` (SOLAR-384). |
| `NoticeCard` | A notice to act on: Overview-card height, 2 columns of the Overview grid, tone bad/warn/info, one quiet button, optional ×. Billing and the grid-off prompt. Wrap in `.notice-cards`. Plant problems go in `HeaderStatus` instead (SOLAR-384). |

## Charts (`chart.jsx`)

| Name | Use it for |
|---|---|
| `useChartSize` | A chart's width that follows its box. |
| `useDayPicker`, `DateBar` | The day arrows and calendar above a day chart. |
| `CalendarPop`, `CalIcon` | The calendar. Use instead of a date input. |
| `dayFace(s)` | "Today", "Yesterday" or the date. |
| `seriesPath`, `seriesArea` | An SVG line or filled area from a series. |
| `ChartPlaceholder` | A chart-sized box while loading or with nothing to show. |
| `gridOffRuns`, `useLiveOffFrom`, `lastSlot` | Today's grid-off band: SunSynk history runs joined with our readings' off buckets, grown to now while the grid is off (SOLAR-421). |

## Tabs and Settings (`tabs.jsx`)

| Name | Use it for |
|---|---|
| `MiniStat` | A small stat with trend, info and `loading`. |
| `SharePie` | A hollow pie of a day's parts with their sum in the middle and each part's kWh beside it. `dayFlows` gives the parts. `empty`: a note for a day with nothing to share; the bare ring keeps the card's shape (SOLAR-345). |
| `DaysPanel` | The per-day bars with retry and the free-week lock. |
| `TabSkeleton` | A whole tab while it loads. |
| `ConfirmCard` | Any "are you sure". Inline or `modal`; `danger`, `busy`. Use instead of `confirm()`. |
| `KeepPicker` | A pick of plants, grouped by login (`acctLogins`): circles for exactly 1, else tick boxes; `ask` above, `full` when past `room`; `min={0}` lets the last tick go (link.jsx). Inside `ChooseDialog`. `tag(p)`: a word on a plant's row (`Free week used`, SOLAR-572). `lock(p)`: that row can't be ticked (`Deleting history`, SOLAR-659). |
| `PlanCard`, `PlanNote` | A card in Billing's Plan section (name and price top left, control top right); a tinted note in it with its buttons right (failed payment, plants to choose, a booked change and its undo) (SOLAR-512). |
| `SettingsSection` | A Settings card with title, note and an `action`. `head`: the section is the whole page, its title the page's. |
| `SettingRow` | One row in a Settings card: `label`, `note`, `action`, `lead`. |
| `AppearanceSection` | Account's Theme switch: Device, Light, Dark. Calls `window.setTheme` from `theme.js` (SOLAR-318). |
| `PlantLine` | A plant's name with an "off" marker, in Settings lists. |
| `DayField` | A date box that opens `CalendarPop`. |
| `EqTable` | A table with a column per inverter: row label, then one cell each (`v`, `sub`, `cls`). Equipment's cards (SOLAR-392). |
| `EqSpark` | A small day chart in a tile: `vals` as `[minute, value]`, `lo`/`hi`, a `stroke` (with `fill` for an area) or `heat` for the temperature shading, `outages` shaded red (SOLAR-397). |
| `EqMore` | Rows folded under "More detail" (a native `details`); rows with no value are left out. |
| `scaleParts`, `totalTile`, `changePct`, `PERIODS` | Shared maths and pieces behind the Solar, Home and Grid tabs. |

## Edge function sending (`supabase/functions/_shared`)

| Name | Use it for |
|---|---|
| `Pacer`, `retryAfterMs` (`pace.ts`) | The one Resend pace in a run: `slot(deadline)` before each call, `hold(retryAfter)` on a 429. notify-email's three lanes share one (SOLAR-645). |
| `sendOutboxOne` (`outbox.ts`) | One outbox email under its row's own key (`ob-<id>`; `msgKey` gives `ms-<id>` for `msg.outbox` emails). |

## CSS

Website pages outside the app (Terms, Privacy, PAIA, the help and feature pages of SOLAR-216 and SOLAR-490)
share `public/legal.css`. A new help or feature page copies one of them: header, lede, one
screenshot from `public/img/`, FAQ as `<details>` with matching ld+json, the `cta` section,
footer, and `welcome-track.js` with its own `data-screen`. Add it to `sitemap.xml` and `help.html`.

The floating surfaces (menus, the notifications panel, calendar, popovers, the save bar,
toasts, chart tooltips, info bubbles) share one rule and the `--pop-shadow`,
`--dlg-shadow` and `--tip-bg` variables; a new floating thing joins that rule. Spinners
use `@keyframes spin`. A white or black tint is `rgba(var(--ink-rgb), a)` or
`rgba(var(--shade-rgb), a)`, never a raw rgba, so it works in light and dark (SOLAR-318). Don't add a class that nothing uses: the check fails on it.
