// Card layout tests: which emails stack their cards on a phone, at the edges of the rule.
//   node scripts/card-tests.mts <out-dir>   exits 1 on any failure; writes each case's HTML
import { copyFileSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const copy = join(mkdtempSync(join(tmpdir(), "email-")), "email.mts");
copyFileSync(new URL("../supabase/functions/_shared/email.ts", import.meta.url), copy);
const { plantEvent, report, sunsynkDown } = await import(copy);

const U = "https://app.princesolarhub.co.za/?unsubscribe=t";
const bank = (names: string[]) => plantEvent("Home", 538820, { kind: "bank_drift", banks: names.map((name, i) => ({ name, chargePct: 70 - i * 12 })) }, U);
const cases: [name: string, html: string, wantStack: boolean, cards: number][] = [
  ["grid down, short labels", plantEvent("Home", 538820, { kind: "grid_down", at: "14:32", chargePct: 62 }, U).html, false, 2],
  ["grid back, 8-char value (limit)", plantEvent("Home", 538820, { kind: "grid_back", at: "16:05", lasted: "123 h 45 min" }, U).html, false, 2],
  ["grid back, 9-char value (over)", plantEvent("Home", 538820, { kind: "grid_back", at: "16:05", lasted: "1234 h 45 min" }, U).html, true, 2],
  ["banks, short names", bank(["Garage", "Kitchen"]).html, false, 2],
  ["banks, 13-char name (limit)", bank(["ABCDEFGHIJKLM", "Kitchen"]).html, false, 2],
  ["banks, 14-char name (over)", bank(["ABCDEFGHIJKLMN", "Kitchen"]).html, true, 2],
  ["banks, serial names", bank(["Inverter 2508290475", "Inverter 2512082438"]).html, true, 2],
  ["banks, three short", bank(["Garage", "Kitchen", "Roof"]).html, false, 3],
  ["string dead, long label", plantEvent("Home", 538820, { kind: "string_dead", string: "String 3", inverter: "Inverter 2512082438", since: "11:40" }, U).html, true, 2],
  ["battery hot, one card", plantEvent("Home", 538820, { kind: "batt_hot", at: "13:20", tempC: 42 }, U).html, true, 1],
  ["SunSynk down, one card", sunsynkDown("Home", 538820, "09:10", U).html, true, 1],
  ["report, never stacks", report({ period: "week", label: "6 – 12 Oct 2026", prevLabel: "last week", plant: "Home", plantId: 538820, madeKwh: 191, homeKwh: 209, importKwh: 47, exportKwh: null, independencePct: 77, savedRand: 495, change: { made: 4 }, unsubscribeUrl: U }).html, false, 5],
];

const out = process.argv[2];
mkdirSync(out, { recursive: true });
let fail = 0;
cases.forEach(([name, html, wantStack, cards], i) => {
  const stacking = (html.match(/class="card flow"/g) ?? []).length;
  const boxes = (html.match(/display:inline-block;width:49%/g) ?? []).length;
  const ok = boxes === cards && (wantStack ? stacking === cards : stacking === 0);
  if (!ok) fail++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}: ${boxes} cards, ${stacking ? "stack" : "side by side"} on a phone`);
  writeFileSync(join(out, `case-${i}.html`), html);
});
writeFileSync(join(out, "cases.json"), JSON.stringify(cases.map(([name, , wantStack]) => ({ name, wantStack }))));
console.log(fail ? `${fail} failed` : "all passed");
process.exitCode = fail ? 1 : 0;
