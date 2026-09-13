---
name: Prince Solar
description: A household's solar ledger, read in the dark. Calm, precise, honest.
colors:
  night-ground: "#0a0d12"
  panel: "#11161d"
  panel-raised: "#141a22"
  hairline: "rgba(255,255,255,0.07)"
  hairline-strong: "rgba(255,255,255,0.12)"
  paper-text: "#e7ecf2"
  muted-text: "#8b96a4"
  dim-text: "#738396"
  solar-green: "#3ddc84"
  battery-violet: "#a78bfa"
  grid-amber: "#facc15"
  home-coral: "#f87171"
  charge-cyan: "#22d3ee"
  sun-core: "#ffd56b"
  sun-mid: "#f4a93a"
  sun-rim: "#e07a1f"
  warn-amber: "#f59e0b"
  fault-red: "#ef4444"
  ambient-blue: "rgba(91,157,255,0.06)"
  ambient-green: "rgba(52,211,153,0.05)"
  ink-on-green: "#06210f"
typography:
  display:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "30px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "-0.01em"
  headline:
    fontFamily: "JetBrains Mono, ui-monospace, monospace"
    fontSize: "44px"
    fontWeight: 700
    lineHeight: 1
  title:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "18px"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "-0.01em"
  body:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.2
    letterSpacing: "0.16em"
  small:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.5
  numeral:
    fontFamily: "JetBrains Mono, ui-monospace, monospace"
    fontSize: "20px"
    fontWeight: 600
    lineHeight: 1
    letterSpacing: "-0.01em"
  unit:
    fontFamily: "JetBrains Mono, ui-monospace, monospace"
    fontSize: "24px"
    fontWeight: 700
    lineHeight: 1
  serial:
    fontFamily: "JetBrains Mono, ui-monospace, monospace"
    fontSize: "22px"
    fontWeight: 700
    lineHeight: 1
  flow-node:
    fontFamily: "JetBrains Mono, ui-monospace, monospace"
    fontSize: "21px"
    fontWeight: 700
    lineHeight: 1
  gauge:
    fontFamily: "JetBrains Mono, ui-monospace, monospace"
    fontSize: "40px"
    fontWeight: 700
    lineHeight: 1
  headline-phone:
    fontFamily: "JetBrains Mono, ui-monospace, monospace"
    fontSize: "34px"
    fontWeight: 700
    lineHeight: 1
  legal-title:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "28px"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.02em"
  display-phone:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "23px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "-0.01em"
  tab:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 500
    lineHeight: 1.2
  form-label:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.2
    letterSpacing: "0.04em"
  micro:
    fontFamily: "Space Grotesk, system-ui, sans-serif"
    fontSize: "10px"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "0.2em"
rounded:
  hairline: "2px"
  meter: "4px"
  meter-thick: "5px"
  xs: "7px"
  sm: "9px"
  md: "12px"
  lg: "16px"
  xl: "18px"
  control: "10px"
  login-input: "11px"
  card-phone: "14px"
  pill: "999px"
spacing:
  xs: "8px"
  sm: "12px"
  md: "16px"
  lg: "20px"
  xl: "26px"
  card-x: "24px"
components:
  button-primary:
    backgroundColor: "{colors.solar-green}"
    textColor: "#06210f"
    rounded: "{rounded.sm}"
    padding: "8px 18px"
  button-secondary:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.paper-text}"
    rounded: "{rounded.control}"
    padding: "10px 22px"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.muted-text}"
    rounded: "{rounded.sm}"
    padding: "7px 14px"
  button-danger:
    backgroundColor: "transparent"
    textColor: "{colors.home-coral}"
    rounded: "{rounded.sm}"
    padding: "8px 14px"
  card:
    backgroundColor: "{colors.panel}"
    rounded: "{rounded.lg}"
    padding: "22px 24px"
  card-inset:
    backgroundColor: "{colors.panel-raised}"
    rounded: "{rounded.md}"
    padding: "16px 18px"
  input:
    backgroundColor: "{colors.panel-raised}"
    textColor: "{colors.paper-text}"
    rounded: "{rounded.sm}"
    padding: "10px 12px"
  chip:
    backgroundColor: "{colors.panel-raised}"
    textColor: "{colors.paper-text}"
    rounded: "{rounded.pill}"
    padding: "6px 13px"
  badge:
    backgroundColor: "transparent"
    textColor: "{colors.muted-text}"
    rounded: "{rounded.pill}"
    padding: "4px 11px"
  tab:
    backgroundColor: "transparent"
    textColor: "{colors.muted-text}"
    padding: "12px 18px"
---

# Design System: Prince Solar

## Overview

**Creative North Star: "The Home Ledger"**

Prince Solar is a household's energy diary, kept in the dark. The page is a near-black
ground with two faint tints of blue and green breathing at its corners, and on it sit
flat panels edged in hairlines. Numbers are the content: big, monospaced, tabular, each
tinted by the one thing it measures. Everything else, labels, notes, chrome, steps back
to a muted grey so the figures read first. The single warm object on the page is the sun
orb in the brand mark, and its glow is the only decorative light allowed.

The mood is calm, precise and honest. Calm: no card floats, nothing pulses except a
status dot, and motion is reserved for data that is actually moving (the flow lines, a
meter filling). Precise: one mono face for every number, tabular figures so columns
line up, units set smaller and lighter than their value. Honest: a missing minute is a
gap, a stale reading is amber, an estimate is marked "approx", and empty states say
plainly what is not there yet.

The declared anti-reference is the gamer dashboard. No neon glow beyond the sun, no
gradients laid over data, no skeuomorphic gauges, no glass. Where a competitor would
add a glowing ring, this system adds a hairline and a smaller grey label.

**Key Characteristics:**
- Dark-only, tonal layering, hairline edges, no shadows at rest
- Five semantic energy colours, each meaning exactly one thing everywhere
- Mono numerals with tabular figures; sans for everything that is a word
- Uppercase, wide-tracked micro-labels over big values
- Motion only for live data and status; skeletons hold the layout while data lands

## Colors

A near-black ground, three grey text levels, and five saturated colours that are
semantic, not decorative.

### Primary
- **Solar Green** (`solar-green`): solar production everywhere it appears, and by
  extension "good": the live status dot, the active tab underline, the active
  Settings tab, the primary Save and Sign-in buttons, the switch when on,
  positive trend badges, and input focus on the login card. It is the product's one
  accent as well as its first data colour.

### Secondary
- **Battery Violet** (`battery-violet`): battery power and battery-side extras in the
  flow diagram. Never used for status; success is always Solar Green.
- **Grid Amber** (`grid-amber`): grid import and export, and the focus border on
  Settings inputs. Also the "connected but unverified" dot on a SunSynk account row.
- **Home Coral** (`home-coral`): home load, and the warning tone: the danger button,
  the inverter warning strip, negative trend badges, a grid-down chip, error text on
  the login card.
- **Charge Cyan** (`charge-cyan`): the house running on its own: the self-sufficiency
  tile and its meter, the runtime estimate line, the range slider thumb, and the
  plant-switched status dot. The battery gauge and charge bar are Battery Violet.

### Tertiary
- **Sun** (`sun-core` → `sun-mid` → `sun-rim`): a radial gradient inside the brand orb
  and nowhere else. Its halo is the login page's ambient glow. It is a mark, not a
  palette entry for UI.
- **Warn Amber** (`warn-amber`, CSS `--warn`) and **Fault Red** (`fault-red`, CSS
  `--bad`): status only. The stale and offline states of the topbar pill, the
  "approx" and "gap" pills on the day chart, a hot battery, a battery pack drifting
  towards "watch". Kept distinct from Grid Amber so a status colour is never mistaken
  for a data series. Warning surfaces (a drifting pack, an inverter warning strip, a
  delete confirmation) tint with Home Coral at 6% to 9% and edge it at 25% to 55%; a
  bad string card takes the coral edge at 35% and no tint.

### Neutral
- **Night Ground** (`night-ground`): page background, the wall-display backdrop in
  fullscreen, and the login card's input wells.
- **Panel** (`panel`): every card, the status pill, the secondary button, and the
  selected segment inside a segmented control.
- **Panel Raised** (`panel-raised`): the inset layer inside a card: inputs, selects,
  chips, segmented-control tracks, string cards, mini panels, small icon buttons.
- **Hairline** (`hairline`) at 7% white: every card border, divider and row rule.
  **Hairline Strong** (`hairline-strong`) at 12%: inputs (the day-chart date input keeps
  the plain hairline), the status pill, floating surfaces, and a hovered card.
- **Paper Text** (`paper-text`): values and titles. **Muted Text** (`muted-text`): labels,
  legends, chart axes, notes, inactive tabs. **Dim Text** (`dim-text`): sub-notes,
  meter scales, version numbers. Muted and Dim both clear WCAG AA 4.5:1 on all three surfaces.

### Named Rules
**The One Meaning Rule.** A series colour means one thing. Green is solar, violet is
battery, amber is grid, coral is home, cyan is self-sufficiency. A new metric that is none of
these gets grey, never a sixth hue.

**The Sun Stays In The Orb Rule.** The warm gradient and its glow belong to the brand
mark and the login backdrop only. No other element is warm-lit.

**The Tinted Number Rule.** Colour goes on the value, not the tile. Cards stay Panel; the
big number and its meter take the series colour, and an optional 2px left accent on
the card edge is the most colour a container gets.

## Typography

**Display Font:** Space Grotesk (with system-ui, sans-serif)
**Body Font:** Space Grotesk
**Label/Mono Font:** JetBrains Mono (with ui-monospace, monospace), tabular figures

**Character:** A geometric sans for words, a crisp mono for every figure. The pairing
reads like a meter face: the mono gives numbers weight and alignment, the sans keeps
labels and notes quiet. Neither face is antialiased artificially; on the dark ground the
browser default renders crisper.

### Hierarchy
- **Display** (700, 30px, line-height 1, tracking -0.01em): the brand name in the
  topbar only. 23px on phones.
- **Headline** (mono 700, 44px, line-height 1): the hero figure in a stat tile, with
  its unit at 24px and 85% opacity riding the baseline; the unit inherits the 700. On
  phones 34px with an 18px unit. The battery gauge value is 40px (34px on phones);
  flow-diagram node values are 21px mono at 700.
- **Title** (600, 18px, tracking -0.01em): Settings section titles; the login title is
  22px at 700 with -0.02em.
- **Numeral** (mono 600, 20px, tracking -0.01em): overview mini-stat values, legend-chip
  readouts. Inverter serials are 22px at 700 (18px on phones); tooltip times 12px at 600.
- **Body** (400, 14px, line-height 1.5): notes and the flow narrative; form labels
  at 12px. Notes run the width of their card.
- **Small** (400, 13px, line-height 1.5): sub-lines under a value, section notes,
  hints, confirmation text, save-row text.
- **Label** (400, 11px, tracking 0.16em, uppercase): the micro-label above a stat-tile
  value; mini-stat, metric and throughput labels loosen to 0.06em to 0.1em. Section
  titles are 600 at 12px with 0.16em; flow column titles 600 at 10px with 0.2em.

### Named Rules
**The Mono Numbers Rule.** Any figure the user might compare, add or scan down a column
is set in JetBrains Mono with tabular figures. Words never are.

**The Small Unit Rule.** A unit is set at roughly half the size of its value, in the same
face, sitting on the same baseline, slightly lighter.

**The Whisper Label Rule.** The label above a value is tiny, uppercase, wide-tracked and
muted. It is found after the number, never before.

## Layout

One centred column, max 1320px, with 20px side gutters (8px on phones) and 30px top
padding. The shell is a flex column so the version line sits at the true bottom of the
page. Content is a vertical stack of cards with 20px gaps; inside a tab, cards group
into fixed grids: four-up for stat rows, three-up for trios, two-up for pairs, and
auto-fit grids with 168px or 220px minimums where the count varies.

Density is medium-high: card padding 22px by 24px (16px by 15px on phones), 16px to
18px grid gaps, 14px between small tiles. Section titles sit 18px above their content.

Breakpoints are three: 980px collapses four-up and three-up grids to two columns and
stacks the battery gauge; 900px turns the Settings tab column into a horizontally
scrolling row with a faded right edge; 600px is the phone layout, where big-number rows
go to one column, metric grids stay two-up, the tab bar scrolls sideways, the flow
diagram becomes a vertical card stack, and the four flow chips become a 2×2 grid. The
login card caps at 400px and tightens at 480px.

On phones every small control grows to a 40px minimum height (day-nav arrows, the date
input, legend chips, ghost and danger buttons, Settings tabs) and segments to 36px,
while the topbar shrinks: 38px orb, 23px name, 38px status pill and Refresh, 14px tabs.
Desktop keeps its sizes.

Settings is tabbed: a 150px column of vertical tabs beside one 720px card, the
section chosen. On phones the tabs become a horizontal scrolling row above the card.

A fullscreen "wall display" mode centres the flow card on the bare ground with safe-area
padding, caps the diagram at 72vh, and hides the cursor.

## Elevation & Depth

Flat by default. Depth is tonal: Night Ground, then Panel, then Panel Raised for inset
controls, each step separated by a hairline rather than a shadow. Cards cast nothing.
Hover on a card only strengthens its hairline.

Shadows exist for three jobs: things that float (tooltips, info bubbles and the
drag-range readout), the login card's front-door presence, and the selected segment in a
segmented control, which gets a 1px drop to read as lifted from its track. The sun orb
and status dots use a soft halo ring rather than a shadow.

### Shadow Vocabulary
- **Floating** (`box-shadow: 0 12px 30px rgba(0,0,0,0.5)`): chart tooltips and the range
  readout, on a 96% to 97% opaque near-black surface with a strong hairline.
- **Bubble** (`box-shadow: 0 14px 34px rgba(0,0,0,0.55)`): the info bubble that opens
  from an info dot.
- **Front door** (`box-shadow: 0 24px 60px -30px rgba(0,0,0,0.9), inset 0 0 0 1px rgba(0,0,0,0.25)`):
  the login card only.
- **Lifted segment** (`box-shadow: 0 1px 2px rgba(0,0,0,0.3)`): the active button in a
  segmented control.
- **Halo** (`0 0 0 3px <colour at 14% to 18%>`): status, connection and grid-presence
  dots; the switch knob has none. The brand sun uses a 6px ring at 10% plus a 34px glow
  at 45% (4px and 22px at 40% on the login card's 30px orb).

### Named Rules
**The Nothing Floats At Rest Rule.** A surface gets a shadow only because it sits over
other content. Cards in the flow of the page never do.

## Shapes

Softly rounded rectangles throughout, with radius scaling to the element's size: 16px
for cards (14px on phones), 18px for the login card, 12px for inset panels and string
cards, 9px to 11px for inputs and buttons, 10px for the status pill, the Refresh button
and the segmented track, 7px for the segment inside it, and full pills for chips and
badges. Dots are circles at 6px to 10px. Meters are 5px to 13px tall with 4px to 5px
radius. Borders are always 1px hairlines; the one dashed line is the 2px legend key for
a reference series.
The card's optional 2px left edge in a series colour is the only asymmetric border.

## Components

### Buttons
- **Shape:** softly rounded (9px to 11px).
- **Primary:** Solar Green fill with near-black text (`#06210f` on the login card,
  `#07130c` on the save bar), 600 to 700 weight, 13px to 14.5px. The login submit adds a
  green under-glow and brightens 6% on hover, drops 1px on press. Disabled: 60% opacity,
  no glow.
- **Secondary (Refresh):** Panel fill, strong hairline, 10px radius, 14px 500, 40px tall
  (38px on phones). Hover moves
  to Panel Raised with a muted border. While refreshing, the border and icon turn green
  and the icon spins once.
- **Ghost:** no fill, strong hairline, muted text, 12.5px. Hover to Paper Text; active
  state takes a green border and green text.
- **Icon:** 30px square (40px on phones), Panel Raised, hairline, 9px radius: the day-nav
  arrows. The fullscreen button is the same surface at 12px text with 5px 11px padding.
  The password eye is a bare 32px square at 7px radius, muted, Paper Text on hover.
- **Keyboard focus:** buttons, Settings tabs and the password eye show a 2px Solar Green
  inset outline; fields change border colour instead.
- **Danger:** no fill, Home Coral border and text, 13px.
- **Link:** bare green text at 13px 600, underlined on hover with 3px offset; a "quiet"
  variant in Muted Text.

### Chips
- **Legend chip:** Panel Raised, hairline, full pill, 12.5px, a 10px ring-dot that fills
  when the series is on, and a mono readout separated by a vertical hairline reserving
  9.5ch. Off state dims the text and empties the dot.
- **Badge:** uppercase 11px 600 with 0.06em tracking, full pill, 1px border in the tone
  colour at 40% and a fill at 8%: ok (green), warn (coral), neutral (muted with strong
  hairline). Optional 6px dot in currentColor.
- **Approx / gap pill:** 11px (10px on phones), hairline border, 7px radius, warn amber
  text, `cursor: help`. The gap pill is mono, the approx pill sans.

### Cards / Containers
- **Corner Style:** 16px (14px on phones).
- **Background:** Panel, with Panel Raised for inset panels and string cards, a 1.5%
  white wash for lightweight rows (trend stat cells, mobile flow tiles, the connect
  form) and 2% for the battery banner. The login card alone runs a top-to-bottom
  gradient from Panel Raised to Panel.
- **Shadow Strategy:** none; see Elevation.
- **Border:** hairline; strengthens on hover for mini-stats; a series-coloured 2px left
  edge marks a stat tile's subject; a coral border at 35% to 55% marks a warning card or
  a drifting battery banner, with a matching 6% to 9% tint; a bad string card gets the
  edge without the tint.
- **Internal Padding:** 22px 24px; 16px 18px for mini-stats; 26px 28px for hero solar
  tiles; chart cards pull side padding to 12px.
- **Sub-lines:** the note under a mini-stat or flow tile clamps to two lines, then clips.

### Inputs / Fields
- **Style:** Panel Raised well, strong hairline, 9px radius, 10px 12px padding, 14px.
  Text inputs are mono; selects are sans with a custom 12px chevron inset 14px from the
  right and `color-scheme: dark` for a dark native menu. Login inputs sit on Night
  Ground at 11px radius with 12px 14px padding, in Space Grotesk at 14.5px.
- **Focus:** border turns Grid Amber in Settings; Solar Green with a 3px green ring at 14%
  on the login card. No outline on fields.
- **Autofill:** forced dark with an inset box-shadow so Chrome never paints a white well.
- **Range:** 6px track at 10% white, 18px Charge Cyan thumb with a 3px ground-coloured
  border and a 1px cyan ring (16px and no ring in Firefox).
- **Switch:** 42×24 pill, 10% white off, Solar Green on, white 18px knob sliding 18px.
- **Field label:** 12px muted with 0.04em tracking, 7px above; login labels are 11px
  uppercase 600 at 0.12em in Dim Text. Notes below are 12px Dim Text at 1.55 line-height.

### Navigation
- **Topbar:** brand (46px sun orb, 30px name, 12.5px muted sub-line with the plant
  selector) on the left; status pill and Refresh on the right, both 40px tall. On phones
  the orb is 38px, the name 23px, the pill and Refresh 38px, and the actions wrap to a
  full-width row.
- **Tab bar:** text tabs, 15px 500, muted, 12px 18px padding (14px, 11px 13px on phones),
  on a hairline rule. Hover
  lifts to Paper Text on a 2% wash; active is Paper Text with a 2px Solar Green underline
  that overlaps the rule. Scrolls horizontally on phones with the scrollbar hidden and
  the right edge faded to Night Ground so the tabs past the screen read as "more".
- **Status pill:** 9px dot plus a 600-weight word and a muted detail behind a vertical
  hairline. Live: green with a breathing halo (off under reduced motion). Stale: warn
  amber. Offline: fault red. Idle: muted. Plant just switched: Charge Cyan.
- **Plant switcher:** the plant name in 12.5px mono under the brand, with a 10px muted
  chevron. Transparent at rest so it reads as text; Panel with a strong hairline on
  hover, a Solar Green border on focus.
- **Settings tabs:** a 150px column of 14px muted buttons with a 2px transparent left
  edge; hover a 3% wash, active a green left edge and Paper Text. Below 900px the
  column becomes a horizontal scrolling row with a faded right edge, and the active tab
  gets a Panel pill instead.

### Segmented control
A Panel Raised track with hairline, 10px radius and 3px padding; 13px 500 buttons at 7px
radius. The selected button is Panel with a 1px lift. Small size is 12px with tighter
padding. On phones an overflowing control scrolls sideways.

### Save bar
A row under the Settings card, in the page flow: Panel, strong hairline, 12px radius,
13px muted text on the left and the primary Save button on the right. With unsaved
edits the border turns Solar Green at 40%. It never floats or blurs.

### Scrollbar
An 11px transparent track with a 14% white thumb inset 3px from the edge (26% on hover,
34% while dragging), so the page never shows a bright seam. Firefox gets the thin
standard bar at 22%.

### Stat tile (signature)
The reason the system exists: a Whisper Label, a Headline mono figure tinted in its
series colour with a Small Unit, an optional 7px meter in the same colour on a 7% track,
and a 13px muted sub-line with bold Paper Text figures. Loading swaps the figure for a
65% wide shimmer of the same height so nothing jumps.

### Power flow (signature)
An SVG diagram of sources, inverters and home, with dashed links animated along their
length only while power is moving; each link takes its series colour. Node values are
21px mono, labels 10.5px tracked sans, column titles 10px at 0.2em. Below it a 14px
narrative sentence and four legend chips. On phones it becomes three source tiles in a
row, animated links down to an inverter node, and a home row.

### Tooltips
Chart tooltips and info bubbles share one surface: 96% to 98% opaque near-black,
strong hairline, 10px radius, 10px 12px padding, Floating shadow, 12px text with
mono times. The info dot is a 13px outlined "i" in Dim Text that turns Grid Amber on
hover or focus and reveals a 210px bubble with a 6px caret. `cursor: help` marks
anything that carries an inference: battery-bank stats, the split bar, the approx and
gap pills, the info dot.

### Skeleton
A 5.5% white block with a 7% highlight sweeping across every 1.5s, sized to the element
it stands in for. The sweep stops under reduced motion.

## Do's and Don'ts

### Do:
- **Do** set every number in JetBrains Mono with tabular figures, and every word in
  Space Grotesk.
- **Do** put colour on the value and its meter, and keep the card Panel with a hairline.
- **Do** keep Solar Green as the single accent for focus, active and success, and Home
  Coral for warning and danger.
- **Do** hold the layout with a skeleton of the same height while data loads.
- **Do** mark estimates, gaps and stale data with an amber pill or word rather than
  hiding them.
- **Do** respect `prefers-reduced-motion`: the breathing dot, the skeleton sweep, the
  flow dashes and any new motion stop under it.
- **Do** keep Muted and Dim text at or above 4.5:1 on Panel Raised.

### Don't:
- **Don't** put a shadow on a card that sits in the page flow.
- **Don't** add a sixth series colour or reuse one of the five for a different meaning.
- **Don't** use the sun gradient or its glow anywhere but the brand orb and the login
  backdrop.
- **Don't** lay a gradient over data, draw a skeuomorphic gauge, or add glass or neon.
- **Don't** apply `-webkit-font-smoothing: antialiased`; it thins light text on the dark
  ground.
- **Don't** ship a light scheme by accident: the app is dark-only today, and `color-scheme:
  dark` on native controls is part of that.
