// The SunSynk adapter (SOLAR-681 R15): the Brand interface over api.ts (calls), realtime.ts
// (one minute of one inverter), extract.ts (fields), invhistory.ts and plantfeed.ts (past days).
import type { Brand } from "../types.ts";
import {
  apiCallCounts, expiresAt, getInverters, getPlantDetail, getPlants, isShareAccount, saveCallTally,
  SHARE_USERNAME, throttledCounts, tokenLogin,
} from "./api.ts";
import { aggregate, DEFAULT_BATT_POSITIVE_MEANS, extractMeta, extractStrings } from "./extract.ts";
import { anchored, fetchInverter, missingParts, outageSignal, readingRow, todayTemps, type Fetched } from "./realtime.ts";
import { fetchInverterDay, fetchInverterExtras, historyRows, plantSpine } from "./invhistory.ts";
import { bucketizeAgg, calibrateFeedScale, fetchMonthRows, fetchYearRows, plantFeedForDay } from "./plantfeed.ts";

const f = (x: unknown) => x as Fetched;

export const sunsynk: Brand = {
  code: "sunsynk",
  displayName: "SunSynk",

  async signIn(username, password) {
    const t = await tokenLogin(username, password);
    return { ...t, expires_at: expiresAt(t.expires_in) };
  },
  isShare: isShareAccount,
  shareLogin() {
    const password = Deno.env.get("SUNSYNK_SHARE_PASSWORD");
    return SHARE_USERNAME && password ? { username: SHARE_USERNAME, password } : null;
  },

  bootstrapLogin() {
    const username = Deno.env.get("SUNSYNK_USERNAME"), password = Deno.env.get("SUNSYNK_PASSWORD");
    return username && password ? { username, password } : null;
  },

  listPlants: getPlants,
  plantDetail: getPlantDetail,
  listInverters: getInverters,

  readNow: (inv, acc, ts, o) => fetchInverter(inv, acc, ts, o.sign, o.offGrid),
  anchored: (x) => anchored(f(x)),
  missingParts: (x) => missingParts(f(x)),
  outage: (row) => outageSignal(row),
  readingRow: (x, ts, tz) => readingRow(f(x), ts, tz),
  stringRows: (x) => extractStrings(x.inv, f(x).raw),
  metaRow: (x, ts, ord) => (x.carried ? null : extractMeta(x.inv, f(x).raw, ts, ord)),
  aggregate: (rows) => aggregate(rows as any),
  defaultBatterySign: DEFAULT_BATT_POSITIVE_MEANS,
  todayTemps,

  history: {
    inverterDay: fetchInverterDay,
    inverterExtras: fetchInverterExtras,
    historyRows,
    plantSpine,
    plantDay: (acc, id, day) => plantFeedForDay(acc, id, day),
    feedScale: calibrateFeedScale,
    bucketsOf: bucketizeAgg,
    monthRows: (acc, id, y, m, g) => fetchMonthRows(acc, id, y, m, g),
    yearRows: (acc, id, y, g) => fetchYearRows(acc, id, y, g),
    throttled: (acc) => throttledCounts.get(acc.id) ?? 0,
  },

  callCount: (acc) => apiCallCounts.get(acc.id) ?? 0,
  saveCalls: saveCallTally,
};
