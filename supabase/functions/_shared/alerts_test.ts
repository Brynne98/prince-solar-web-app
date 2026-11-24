// The alert words in text.ts (SOLAR-645 step 6). The list and pop-up lines below are what
// private.alert_text (0233) and private.push_text (0229) wrote for the same rows before 0264
// dropped them, so a change here is a change of words on screen.
//   npx --yes deno@2.5.6 test --node-modules-dir=none supabase/functions/_shared/alerts_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { alertLine, alertMail, alertPush } from "./text.ts";

const TZ = "Africa/Johannesburg", CREATED = 1764000060;
// kind, data, list title, list body, list time, page, pop-up with two plants [title, body]
const ROWS: [string, Record<string, unknown>, string, string, string, string, [string, string]][] = [
  ["grid_down", {"since": 1764000000, "chargePct": 62}, "Grid down", "Since 18:00. Battery 62%.", "18:00", "grid", ["Prince Home", "Grid down since 18:00. Battery 62%."]],
  ["grid_down", {"from": 1763995000, "since": 1764000000}, "Grid down", "Between 16:36 and 18:00.", "18:00", "grid", ["Prince Home", "Grid down between 16:36 and 18:00."]],
  ["grid_back", {"at": 1764000000, "since": 1763994420}, "Grid back", "Down for 1h 33m.", "18:00", "grid", ["Prince Home", "Grid back. Down for 1h 33m."]],
  ["batt_hot", {"at": 1764000000, "since": 1763999000, "tempC": 46.5}, "Battery hot", "46.5 °C since 17:43.", "18:00", "inverters", ["Prince Home", "Battery hot. 46.5 °C since 17:43."]],
  ["batt_hot_back", {"at": 1764000000, "since": 1763996400, "tempC": 42}, "Battery cooled", "42 °C. Hot for 1h.", "18:00", "inverters", ["Prince Home", "Battery cooled. 42 °C. Hot for 1h."]],
  ["bank_drift", {"banks": [{"name": "Inv A", "chargePct": 70}, {"name": "Inv B", "chargePct": 52}], "since": 1764000000}, "Battery charge uneven", "Inv A 70%, Inv B 52%.", "18:00", "inverters", ["Prince Home", "Battery charge uneven. Inv A 70%, Inv B 52%."]],
  ["bank_drift_back", {"at": 1764000000, "banks": [{"name": "Inv A", "chargePct": 61}, {"name": "Inv B", "chargePct": 58}], "since": 1763997000}, "Battery charge even again", "Inv A 61%, Inv B 58%. Uneven for 50 min.", "18:00", "inverters", ["Prince Home", "Battery charge even again. Inv A 61%, Inv B 58%. Uneven for 50 min."]],
  ["string_dead", {"since": 1764000000, "string": "String 3", "inverter": "Inverter 2512082438"}, "Some panels stopped producing", "Inverter 2512082438, string 3, since 18:00.", "18:00", "inverters", ["Prince Home", "Some panels stopped producing. Inverter 2512082438, string 3, since 18:00."]],
  ["string_back", {"at": 1764000000, "since": 1763992200, "string": "Strings 1 and 2", "inverter": "Inverter 2512082438"}, "Panels producing again", "Inverter 2512082438, strings 1 and 2. Stopped for 2h 10m.", "18:00", "inverters", ["Prince Home", "Panels producing again. Inverter 2512082438, strings 1 and 2. Stopped for 2h 10m."]],
  ["logger_stale", {"since": 1764000000}, "No readings", "Since 18:00.", "18:00", "live", ["Prince Home", "No readings since 18:00."]],
  ["logger_stale", {"since": 1764000000, "inverter": "2504193036"}, "No readings from Inverter 2504193036", "Since 18:00.", "18:00", "live", ["Prince Home", "No readings from Inverter 2504193036 since 18:00."]],
  ["logger_back", {"at": 1764000000, "since": 1763993580, "inverter": "2504193036"}, "Readings back from Inverter 2504193036", "No readings for 1h 47m.", "18:00", "live", ["Prince Home", "Readings back from Inverter 2504193036. No readings for 1h 47m."]],
  ["sunsynk_down", {"since": 1764000000}, "SunSynk is down", "No new readings since 18:00.", "18:00", "live", ["SunSynk", "SunSynk is down. No new readings since 18:00."]],
  ["sunsynk_back", {"at": 1764000000, "since": 1763998500}, "SunSynk is back", "Down for 25 min.", "18:00", "live", ["SunSynk", "SunSynk is back. Down for 25 min."]],
  ["needs_relink", {"since": 1764000000, "plants": ["Home"]}, "Sign in to SunSynk again", "Login stopped working at 18:00.", "18:00", "account", ["SunSynk", "Sign in to SunSynk again. Login stopped working at 18:00."]],
  ["needs_relink", {"since": 1764000000, "plants": ["Home", "Gran", "Shop"]}, "Sign in to SunSynk again", "Login for Home, Gran and Shop stopped working at 18:00.", "18:00", "account", ["SunSynk", "Sign in to SunSynk again. Login for Home, Gran and Shop stopped working at 18:00."]],
  ["relinked", {"at": 1764000000, "since": 1763992800, "plants": ["Home", "Gran"]}, "SunSynk reconnected", "Home and Gran were signed out for 2h.", "18:00", "account", ["SunSynk", "SunSynk reconnected. Home and Gran were signed out for 2h."]],
];

Deno.test("alert list and pop-up: the words SQL wrote, per kind", () => {
  for (const [kind, data, title, body, time, tab, push] of ROWS) {
    const t = alertLine({ kind, data, created: CREATED, tz: TZ })!;
    assertEquals([t.title, t.body, t.time, t.tab, t.day], [title, body, time, tab, "2025-11-24"], kind);
    assertEquals(alertPush(kind, t, "Prince Home", 1), { title, body }, kind);
    assertEquals(alertPush(kind, t, "Prince Home", 2), { title: push[0], body: push[1] }, kind);
  }
  // every alert kind is covered
  assertEquals(new Set(ROWS.map((r) => r[0])).size, 14);
});

Deno.test("alert list: a time over 12 hours before the row reads as the row's time", () => {
  const t = alertLine({ kind: "logger_stale", data: { since: CREATED - 50000 }, created: CREATED, tz: TZ })!;
  assertEquals([t.at, t.time, t.body], [CREATED, "18:01", "Since 04:07."]);
});

Deno.test("alert list: a missing fact leaves the line out, as SQL did", () => {
  assertEquals(alertLine({ kind: "batt_hot", data: { at: CREATED }, created: CREATED, tz: TZ })!.body, null);
  assertEquals(alertPush("batt_hot", alertLine({ kind: "batt_hot", data: { at: CREATED }, created: CREATED, tz: TZ })!, null, 3),
    { title: "Your plant", body: null });
  assertEquals(alertLine({ kind: "welcome", data: {}, created: CREATED, tz: TZ }), null);
});

Deno.test("alert email: subjects and switch line, per kind", () => {
  const p = "Prince Home";
  const cases: [Parameters<typeof alertMail>[0], string, string | null][] = [
    [{ kind: "grid_down", at: "14:32" }, "Grid down at Prince Home", "grid"],
    [{ kind: "grid_back", since: "14:32", at: "16:05", lasted: "1h 33m" }, "Grid back at Prince Home", "grid"],
    [{ kind: "batt_hot", at: "13:20", tempC: 47 }, "Battery hot at Prince Home", "battery"],
    [{ kind: "bank_drift", banks: [{ name: "A", chargePct: 70 }, { name: "B", chargePct: 50 }] }, "Batteries charging unevenly at Prince Home", "battery"],
    [{ kind: "string_dead", string: "String 3", inverter: "Inverter 1", since: "11:40" }, "Panels stopped producing at Prince Home", "panel"],
    [{ kind: "string_back", string: "String 3", inverter: "Inverter 1", since: "11:40", at: "12:00", lasted: "20 min" }, "Panels producing again at Prince Home", "panel"],
    [{ kind: "logger_stale", since: "08:15" }, "No readings from Prince Home", "reading"],
    [{ kind: "logger_back", since: "08:15", at: "09:00", lasted: "45 min", inverter: "Inverter 9" }, "Readings back from Inverter 9", "reading"],
    [{ kind: "sunsynk_down", since: "09:10" }, "SunSynk is down", "SunSynk"],
    [{ kind: "sunsynk_back", since: "09:10", at: "10:00", lasted: "50 min" }, "SunSynk is back", "SunSynk"],
    [{ kind: "needs_relink", plants: ["A", "B", "C", "D"] }, "Sign in to SunSynk again for A, B, C and 1 more", null],
    [{ kind: "relinked", plants: ["A"], at: "09:00", lasted: "2h" }, "SunSynk reconnected for A", null],
  ];
  for (const [e, subject, what] of cases) {
    const m = alertMail(e, p);
    assertEquals([m.subject, m.footer], [subject, what && `You get ${what} alerts for Prince Home. Turn them off in notification settings.`], e.kind);
  }
});
