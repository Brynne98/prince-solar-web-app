// SOLAR-686 H20: a plant's local day, whatever its length.
import { assertEquals } from "jsr:@std/assert@1";
import { dayClock, dayStartEpoch } from "./localtime.ts";

Deno.test("H20 Johannesburg: midnight is 22:00 UTC the day before, a day is 24 h", () => {
  assertEquals(dayStartEpoch("Africa/Johannesburg", "2026-11-27"), Date.UTC(2026, 10, 26, 22) / 1000);
  const c = dayClock("Africa/Johannesburg", "2026-11-27");
  assertEquals(c.end - c.start, 86400);
  assertEquals(c.at(3600), c.start + 3600);
});

Deno.test("H20 London, clocks forward (31 Mar 2030): midnight is GMT, the day is 23 h", () => {
  const c = dayClock("Europe/London", "2030-03-31");
  assertEquals(c.start, Date.UTC(2030, 2, 31) / 1000);   // the offset at midnight, not at noon (was an hour off)
  assertEquals((c.end - c.start) / 60, 1380);
  assertEquals(c.at(3 * 3600), Date.UTC(2030, 2, 31, 2) / 1000);   // 03:00 BST = 02:00 UTC
});

Deno.test("H20 London, clocks back (27 Oct 2030): the day is 25 h", () => {
  const c = dayClock("Europe/London", "2030-10-27");
  assertEquals(c.start, Date.UTC(2030, 9, 26, 23) / 1000);   // 00:00 BST
  assertEquals((c.end - c.start) / 60, 1500);
  assertEquals(c.at(12 * 3600), Date.UTC(2030, 9, 27, 12) / 1000);   // noon GMT
});
