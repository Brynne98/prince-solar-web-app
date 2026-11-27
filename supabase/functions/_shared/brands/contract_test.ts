// SOLAR-681 R15: every brand adapter passes the same contract. Run for each registered brand
// against the in-process fake (logins ending @mock never leave the function, SOLAR-637).
import { assert, assertEquals } from "jsr:@std/assert@1";
import { allBrands, type Account, brandOf } from "./index.ts";
import { LOW_VOLT_V } from "./sunsynk/realtime.ts";
import { dayClock } from "../localtime.ts";

const LOGIN = "export@mock";   // two plants, a page of one plant (mock-sunsynk.mjs)

async function signedIn(code: string): Promise<Account> {
  const t = await brandOf(code).signIn(LOGIN, "any");
  return { id: `contract-${code}`, user_id: "u", username: LOGIN, brand: code, access_token: t.access_token, access_expires_at: t.expires_at };
}

for (const b of allBrands()) {
  Deno.test(`${b.code}: sign-in gives a token that lasts`, async () => {
    const t = await b.signIn(LOGIN, "any");
    assert(t.access_token && t.expires_at > Date.now());
  });
  Deno.test(`${b.code}: the plant list is whole, every id the brand's own text`, async () => {
    const list = await b.listPlants(await signedIn(b.code));
    assertEquals(list.length, 2);   // two pages of one: both come back
    for (const p of list) assert(typeof p.vendorId === "string" && p.vendorId.length > 0 && p.name);
  });
  Deno.test(`${b.code}: inverters carry the brand's plant id; a brand other than the first prefixes its serials`, async () => {
    const acc = await signedIn(b.code);
    const invs = await b.listInverters(acc);
    assert(invs.length > 0);
    const plants = new Set((await b.listPlants(acc)).map((p) => p.vendorId));
    for (const i of invs) {
      assert(i.vendorPlantId && plants.has(i.vendorPlantId), `${i.sn} has no plant of the list`);
      assertEquals(i.sn.startsWith(`${b.code}:`), b.code !== "sunsynk");
    }
  });
  Deno.test(`${b.code}: one minute read gives a dated row for that inverter`, async () => {
    const acc = await signedIn(b.code);
    const [inv] = await b.listInverters(acc);
    const f = await b.readNow({ ...inv, plantId: 1000000000001 }, acc, Math.floor(Date.now() / 60000) * 60, { sign: null, offGrid: false });
    assert(b.anchored(f), "the logger's time arrived");
    const row = b.readingRow(f, Math.floor(Date.now() / 60000) * 60, "Africa/Johannesburg");
    assertEquals(row.sn, inv.sn);
    assertEquals(row.plant_id, 1000000000001);
    assert(row.device_time != null);
    for (const s of b.stringRows(f)) assertEquals(s.sn, inv.sn);
  });
  // SOLAR-686 H18: the history half of the interface, as the History engine uses it
  Deno.test(`${b.code}: an inverter's past day gives a minute spine and inverter rows on the day's clock`, async () => {
    const acc = await signedIn(b.code);
    const [inv] = await b.listInverters(acc);
    const day = new Date(Date.now() - 3 * 86400e3).toISOString().slice(0, 10);
    const clock = dayClock("Africa/Johannesburg", day);
    const d = await b.history.inverterDay(acc, inv.sn, day, false);
    const spine = b.history.plantSpine([d], clock);
    assert(spine.size > 0, "minutes came back");
    for (const ts of spine.keys()) assert(ts >= clock.start && ts < clock.end && ts % 60 === 0, `${ts} is a minute of the day`);
    for (const r of b.history.historyRows(d, clock)) assert(Number(r.ts) >= clock.start && Number(r.ts) < clock.end);
  });
  Deno.test(`${b.code}: a past day's extras and the plant's kWh totals`, async () => {
    const acc = await signedIn(b.code);
    const [inv] = await b.listInverters(acc);
    const [p] = await b.listPlants(acc);
    const day = new Date(Date.now() - 3 * 86400e3).toISOString().slice(0, 10);
    const x = await b.history.inverterExtras(acc, inv.sn, day, false);
    assert(Array.isArray(x.failed));
    const now = new Date();
    const rows = await b.history.monthRows(acc, p.vendorId, now.getUTCFullYear(), now.getUTCMonth() + 1, 1);
    assert(Array.isArray(rows));
    assertEquals(typeof b.history.throttled(acc), "number");
  });
  Deno.test(`${b.code}: plant detail is for the plant asked`, async () => {
    const acc = await signedIn(b.code);
    const [p] = await b.listPlants(acc);
    assertEquals((await b.plantDetail(acc, p.vendorId)).vendorId, p.vendorId);
  });
}

Deno.test("R23: the carry rule's grid threshold is public.grid_live's (over 100 V)", () => {
  assertEquals(LOW_VOLT_V, 100);
});
