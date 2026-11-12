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
| `Locked`, `HistoryLock`, `LockIcon` | Paid-only content behind the free-week lock. |

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

## Forms and sign-in (`auth.jsx`)

| Name | Use it for |
|---|---|
| `AuthCard` | A signed-out card: `title`, `sub`, `onSubmit`, `busy`. |
| `FieldLabel` | A field's label with its error or hint on the same row. |
| `useFieldErrors()` | `{ bad, setBad, flag, edited }`: which fields are wrong, cleared on edit. |
| `invalidProps` | `aria-invalid` and `aria-describedby` for a field. |
| `PasswordInput`, `PasswordField` | A password box with the eye, bare or with label. |
| `BotCheck` | Cloudflare's bot check box: `hold` (a ref; `await hold.current?.()` gives the `captchaToken` for a Supabase sign-in, sign-up, reset or resend), `quiet` (shown only when a tap is needed). Any new call to those needs one. |
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
| `PayReview` | The price, next bill and card before a saved card is charged. `parts`: the lines the bill is made of. Its `.pay-review-box` is also Billing's darker box. |
| `PLAN_NAME` | A plan id as its name: "Home". |
| `billingFmt.rand(n, narrow)` | A price in rand: "R1 799". `narrow` for the large prices on the plan cards, where a full space reads as a gap (SOLAR-364). |
| `billingFmt.offerLine`, `offerCap`, `Was` | An offer price (SOLAR-330): its terms under the price, the members cap, the list price struck out. |
| `withTimeout(call, ms)` | A Supabase call that must give up: after `ms` it resolves as `{ data: null, error: { message: 'timed out' } }`. |
| `edgePost(path, body, signal)` | A POST to one of our edge functions as the signed-in user; returns `[response, json]`. |
| `mountNode(node)` | Render something into its own root outside the app (dialogs opened from plain code). |
| `payFailed(e, fallback)` | The toast for a payment call that failed. |

## Data (`data.jsx`)

Every Supabase read and write goes through a `fetch*` or `save*` here; don't call
`window.sb` from a screen. New ones use `must(call, fallback, failed)`, which throws on
an error and returns `fallback` when there is no row. `fetchFlags` and `saveFlag` cover
a row of on/off settings (email and push preferences); `saveFlag` sends its own event. `emptyText` is the message for a plant with no data yet.
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
| `StatusBits` | The dot and word of a status pill. |
| `fmtAgo`, `readAgo`, `useNow` | "5 min ago", "Read 2 h ago", a ticking clock. |
| `plantStatus` | A plant's status word and tone from its last reading. |
| `StepField` | A number box with a unit, as in First steps. |
| `stepNum`, `wholeNum`, `cfgFields`, `sumPatch` | Reading, checking and saving system config (size, panels, reserve, rate). |
| `savedTab`, `writeTab`, `TAB_KEY` | The last tab and plant, kept across visits. `writeTab` adds a history entry for a new page; pass `replace` for a change the app made itself. |
| `usePageHistory(tab, plant, onBack)`, `usePageTitle(tab)` | The address follows the page and Back/Forward show the entry's page; the browser tab reads "Solar · Prince Solar Hub" (SOLAR-515). |
| `window.toast(text)` | A short message at the bottom. Use instead of `alert()`. `{ error: true }` for a failure (red), `{ info: true }` for a note that is neither (no tick). One sent just before sign-out shows on the sign-in screen. Signed in, a red one with no `action` offers "Report this"; `noReport: true` turns that off. Goes after 5 s; one with a link stays until closed (×, Esc). A click on any toast closes it. |
| `PageBoundary` | Wraps each page in `Frame`: a crash shows a card with Reload and Report this, not a blank screen. |
| `openFeedback(report)` | The feedback box; `report` = { text, id } makes it "Report a problem" with the error attached. |
| `NotifRows`, `alertSpan` | Alert rows under day headings (the bell list, the full Notifications page); "14:02 to 16:47, 2h 45m" (SOLAR-327). Billing notices (`NoticeRows`) lead the Today group in both, one list (SOLAR-353). |
| `billNotice`, `BillCards` | A billing notice from `api_notifications`' pinned facts, in the emails' words; the cards above every page (SOLAR-212). On a phone each card shows `short` and `bodyShort` (SOLAR-384). |
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
| `KeepPicker` | The plants a cancel or smaller plan keeps, grouped by login: circles for 1, else tick boxes; too-many and last-tick lines (SOLAR-496). In the cancel and downgrade pop-ups and in `KeepDialog`. |
| `billingFmt.lossLine(links, cancel)` | What a booked cancel or smaller plan deletes, in one line: which plants stay, which go, and for a cancel all history. Billing's Plan card, the bell and the banner all use it (link.jsx, SOLAR-505). `billingFmt.andList(names)`: "A, B and C". `pickableLogins(links)`: the plants such a change can keep. |
| `PayFirstDialog` | In place of the cancel and downgrade pop-ups while a payment has failed: "Pay the failed payment first", with Pay with another card (SOLAR-497). |
| `KeepDialog` | Billing's Choose plant(s) pop-up: changes a booked cancel's or smaller plan's pick (api_billing_keep_set) (SOLAR-496). |
| `PlanCard`, `PlanNote`, `BookedNotice` | A card in Billing's Plan section (name and price top left, control top right); a tinted note in it with its buttons right (failed payment, kept plants); a change booked for the billing date with its undo, as a `PlanNote` (SOLAR-512). |
| `SettingsSection` | A Settings card with title, note and an `action`. `head`: the section is the whole page, its title the page's. |
| `SettingRow` | One row in a Settings card: `label`, `note`, `action`, `lead`. |
| `AppearanceSection` | Account's Theme switch: Device, Light, Dark. Calls `window.setTheme` from `theme.js` (SOLAR-318). |
| `PlantLine` | A plant's name with an "off" marker, in Settings lists. |
| `DayField` | A date box that opens `CalendarPop`. |
| `EqTable` | A table with a column per inverter: row label, then one cell each (`v`, `sub`, `cls`). Equipment's cards (SOLAR-392). |
| `EqSpark` | A small day chart in a tile: `vals` as `[minute, value]`, `lo`/`hi`, a `stroke` (with `fill` for an area) or `heat` for the temperature shading, `outages` shaded red (SOLAR-397). |
| `EqMore` | Rows folded under "More detail" (a native `details`); rows with no value are left out. |
| `scaleParts`, `totalTile`, `changePct`, `PERIODS` | Shared maths and pieces behind the Solar, Home and Grid tabs. |

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
