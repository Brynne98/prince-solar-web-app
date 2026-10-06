# Panel capacity in Settings — handoff

Written 17 Sep 2026. **Status: built 17 Sep and proved on the local stack only. Not committed, not
pushed, no `supabase db push`.** Two decisions made while building: By panel with no filled rows
never saves over a stored Total, but against a saved list the switch itself counts as a change (Total
on screen saves one figure and drops the list, even at the same kW) and removing every row clears
capacity; a Total must be above 0. Numbers are compared as numbers, so a figure typed and taken back
out leaves nothing unsaved. Reworked after Brynne's review: no × anywhere (units "panels" and "W each", a bin to
remove), the total sits under the rows, and errors show under the boxes once a row is left or Save
is pressed, never in the save bar.

## The ask

Settings gets a panel capacity field, set one of two ways:

1. **Total** — one kW figure.
2. **By panel** — a count and a wattage, with several groups allowed (20 × 450 W + 8 × 400 W).

Brynne's own plant: 28 × 450 W = 12.6 kW, which is what SunSynk already has on record.

## What is there today

- `plant_config.system_kwp` (kW) *was* copied once from SunSynk's plant `totalPower` when a plant
  was first seen. **0054 (18 Sep) ends that**: the seed writes no capacity, the figures already
  stored are cleared unless the row has a panel list, `plant_cfg` no longer falls back to
  app_config's `SYSTEM_KWP`, and the Solar tab asks with a "Set panel capacity" link. The row in
  Settings is the only source. Settings also opens on **By panel** when nothing is set.
- Its only user is the Solar tab's "N% of your X kW of panels" line (`public/tabs.jsx`, SolarTab,
  `kwp` from `snap.config.systemKwp`). Calibration reads app_config `SYSTEM_KWP`
  instead (`0025_scope_functions.sql:368-369`).
- **Bug to fix on the way:** `api_overview` reads config through `plant_cfg()`
  (`0048_sync_status.sql:16`, `:113`), which falls back to app_config `SYSTEM_KWP` (12.6, Brynne's
  plant) for **every** plant with no value (`0042_plant_shapes.sql:109`). A stranger's plant with no
  SunSynk figure reads "of your 12.6 kW of panels". Battery size already falls back only for the
  calibration plant (`0042_plant_shapes.sql:113`); do the same.
- Settings reads the raw row: `api_me` returns `to_jsonb(plant_config)` (`0027_plant_config.sql:215`),
  so a new column arrives without touching `api_me`.
- Writes: table grant `select, update` to authenticated and RLS `plant_config_write`
  (`0027_plant_config.sql:56-62`) already cover a new column. Settings saves through
  `window.savePlantConfig` (`public/data.jsx`), a supabase-js `update` on `plant_config`.
- The service role also updates this row (recover watermarks, `supabase/functions/recover/index.ts:188`;
  feature and battery-sign detection in 0041/0042). Existing BEFORE triggers only act when
  `auth.uid() is not null` for that reason.
- Removing the last SunSynk login deletes `plant_config` (`0050_remove_wipes_plant.sql:98`); a re-link
  re-seeds SunSynk's figure. Same as battery size and rate today; acceptable.

## Plan

1. **Database (migration 0053).**
   - Add `plant_config.panel_groups jsonb`, null when unused: `[{"count": 28, "watts": 450}, ...]`.
   - An immutable SQL function `panel_kwp(jsonb)` that returns the total in kW (3 dp), or null for
     null, `[]`, a non-array, or any entry that is not whole numbers with count 1–2000 and watts
     50–1000. Guard `jsonb_typeof(...)` with `coalesce(..., '')`, or a missing key slips through as null.
   - A CHECK: `panel_groups is null or round(system_kwp::numeric, 3) = public.panel_kwp(panel_groups)`.
     So a list is always valid, non-empty and matches the stored total.
   - **No trigger.** Both reviewers said so and the code agrees: service-role updates would fire it,
     and a raise there takes down recover.
   - Redefine `plant_cfg()` with `create or replace` (not `drop ... cascade`), changing only the
     `system_kwp` line to fall back for the calibration plant alone.
2. **Settings → Plant section** (`<SettingsSection id="plant">`, `public/tabs.jsx:1410`). Add a
   "Panel capacity" row in the existing `conn-row sset-row` pattern, with the `Segmented` control
   (`public/components.jsx:154`) for **Total / By panel**.
   - **Total:** one number input, unit kW.
   - **By panel:** rows of `[count] panels × [watts] W` with a remove button each, an "Add panels"
     button, and the running total ("12.2 kW").
   - The mode is its own `useState`, not a key on `f`. `dirty` today is
     `JSON.stringify(f) !== JSON.stringify(cfg)` (`:1346`), so a mode kept on `f` would leave the
     save bar permanently dirty. Flipping the switch alone is not an unsaved change; a changed number
     or list is.
   - `save()` (`:1350`) sends a fixed whitelist. Add the capacity fields only when they changed:
     Total sends `{ system_kwp, panel_groups: null }`; By panel drops blank rows and sends
     `{ panel_groups, system_kwp }` with the total rounded to 3 dp exactly as `panel_kwp` does.
   - An empty Total saves `system_kwp: null`.
3. **Opening state:** By panel when `panel_groups` is a non-empty array, else Total pre-filled with
   `system_kwp` (blank when null).
4. **Copy** (run the ui-copy cut-first pass): label "Panel capacity"; hint "Used for the % of your
   panels on the Solar tab."; switch "Total" / "By panel"; button "Add panels".
5. **Nothing else changes.** The Solar tab already reads `systemKwp`.

## Proof before calling it done

- Apply the migration to the local database (not production) and try the CHECK by hand: a valid
  list, `[]`, a string, count 0, watts 1200, and a total that doesn't match. Each bad one must fail.
- `for f in public/*.jsx; do npx --yes esbuild@0.24.0 --loader:.jsx=jsx --outfile=/dev/null "$f"; done`
- In the browser pane at phone and desktop width: save 20 × 450 W + 8 × 400 W, reload, Settings shows
  both rows and the Solar tab reads "of your 12.2 kW of panels"; then save a Total and see the list
  clear.
- Run the council (`consult`) on the diff before reporting.

**Local preview with real data** (the local stack's readings stop on 14 Sep): sign in as
`dev@local.test` with a magic link from the local admin API written into a throwaway
`public/_signin.html` meta-refresh (never paste the link; delete the file after), and use plant 6004,
which holds copies of Brynne's real readings. Details in memory `local-preview-with-real-data`.

## Shipping (only on Brynne's say-so, every time)

Backend first, then frontend (`DEPLOY.md`):

```bash
supabase db push
git push origin main
```

Bump `public/config.js` to v0.22.0 (a feature) in its own "Version 0.22.0." commit before the push,
then confirm Pages serves it.

## Review record (17 Sep 2026)

- **Fable and Grok agreed:** no trigger, write both columns from Settings, keep the mode out of `f`;
  the `plant_cfg` 12.6 kW fallback leaks to other plants; `[]` must not count as "By panel". All
  checked against the code above.
- **Fable:** use a CHECK tying `system_kwp` to the list, so the database guarantees they match.
- **Grok:** a `capacity_source` column (like `features_source`) only if the owner wants to switch
  back to a saved list after saving a Total. Not in scope.
- **Astra:** no answer (usage window nearly spent).
- **Settled 18 Sep:** SunSynk's `totalPower` is stale, not just unverified. Tshigabe Family 2 reads
  12 kW on SunSynk and about 19 kW in its own log (6 strings, best minute 18.2 kW), because
  panels were added in chunks. The owner's figure must win.
- **Open:** SunSynk's `totalPower` is assumed to be kW. It is for Brynne's plant (12.6) and the mock
  server; unverified for other accounts.
