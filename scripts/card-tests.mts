// Card layout tests: reports keep their side-by-side cards on a phone; alerts have none
// since SOLAR-415 (one box of rows instead), whatever their labels' length.
//   node scripts/card-tests.mts <out-dir>   exits 1 on any failure; writes each case's HTML
import { copyFileSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const copy = join(mkdtempSync(join(tmpdir(), "email-")), "email.mts");
copyFileSync(new URL("../supabase/functions/_shared/email.ts", import.meta.url), copy);
const { plantEvent, report, sunsynkDown } = await import(copy);

const bank = (names: string[]) => plantEvent("Home", 538820, { kind: "bank_drift", banks: names.map((name, i) => ({ name, chargePct: 70 - i * 12 })) });
const cases: [name: string, html: string, wantStack: boolean, cards: number][] = [
  ["grid down, short labels", plantEvent("Home", 538820, { kind: "grid_down", at: "14:32", chargePct: 62 }).html, false, 0],
  ["grid back, 8-char value ", plantEvent("Home", 538820, { kind: "grid_back", since: "14:32", at: "16:05", lasted: "123h 45m" }).html, false, 0],
  ["grid back, 9-char value ", plantEvent("Home", 538820, { kind: "grid_back", since: "14:32", at: "16:05", lasted: "1234h 45m" }).html, false, 0],
  ["banks, short names", bank(["Garage", "Kitchen"]).html, false, 0],
  ["banks, 13-char name ", bank(["ABCDEFGHIJKLM", "Kitchen"]).html, false, 0],
  ["banks, 14-char name ", bank(["ABCDEFGHIJKLMN", "Kitchen"]).html, false, 0],
  ["banks, serial names", bank(["Inverter 2508290475", "Inverter 2512082438"]).html, false, 0],
  ["banks, three short", bank(["Garage", "Kitchen", "Roof"]).html, false, 0],
  ["string dead, long label", plantEvent("Home", 538820, { kind: "string_dead", string: "String 3", inverter: "Inverter 2512082438", since: "11:40" }).html, false, 0],
  ["battery hot", plantEvent("Home", 538820, { kind: "batt_hot", at: "13:20", tempC: 47 }).html, false, 0],
  ["SunSynk down", sunsynkDown("Home", 538820, "09:10").html, false, 0],
  ["report, never stacks", report({ period: "week", label: "6 – 12 Oct 2026", prevLabel: "last week", plant: "Home", plantId: 538820, madeKwh: 191, homeKwh: 209, importKwh: 47, exportKwh: null, independencePct: 77, savedRand: 495, change: { made: 4 } }).html, false, 5],
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
