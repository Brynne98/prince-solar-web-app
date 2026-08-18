// Field mapping, ported 1:1 from server.js.
//
// In the monolith this is the single place raw SunSynk payloads become typed rows —
// both the live Overview and the 1/min logger call it, so they can't drift apart.
// Same rule here: poll and recover both use this, nothing re-implements it.
//
// Source: num/pick/sumVip/powerField (server.js ~192-216) and extractReading (~956).

export const num = (v: unknown): number =>
  v === null || v === undefined || v === "" ? 0 : Number(v) || 0;

/**
 * Like num(), but preserves "not reported" as null instead of collapsing it to 0.
 *
 * Used for grid voltage, where the difference matters: 0 V means the mains has failed,
 * whereas a missing field means this firmware doesn't tell us. num() cannot express
 * that difference, and storing 0 for an absent field would show GRID OFF forever.
 */
export const numOrNull = (v: unknown): number | null =>
  v === null || v === undefined || v === "" || Number.isNaN(Number(v)) ? null : Number(v);

/** first defined/non-null value among keys */
export function pick(obj: any, ...keys: string[]): any {
  if (!obj) return undefined;
  for (const k of keys) {
    if (obj[k] !== undefined && obj[k] !== null) return obj[k];
  }
  return undefined;
}

/** sum the .power field across a vip[] (per-phase) array */
export function sumVip(data: any): number {
  const vip = data && (data.vip || data.pvIV);
  if (!Array.isArray(vip)) return 0;
  return vip.reduce((acc: number, p: any) => acc + num(pick(p, "power", "ppv", "pac")), 0);
}

/**
 * Power (W) from the primary field(s), falling back to summing per-phase vip[] ONLY
 * when the field is absent. A legitimate 0 W must stay 0 — a falsy `||` fallback
 * would silently substitute sumVip for it.
 */
export function powerField(obj: any, ...keys: string[]): number {
  const v = pick(obj, ...keys);
  return v == null || v === "" ? sumVip(obj) : num(v);
}

// Battery sign convention. The firmware's sign differs between installs; the monolith
// normalises to "+ = charging" at ingestion so every downstream consumer agrees.
const BATTERY_POSITIVE_MEANS = Deno.env.get("BATTERY_POSITIVE_MEANS") ?? "discharging";

export interface RawBundle {
  grid: any;
  battery: any;
  input: any;
  load: any;
  output: any;
}

export interface InverterInfo {
  sn: string;
  alias?: string;
  plantId?: number | null;
  plantName?: string | null;
  model?: string;
  status?: number | string;
  gsn?: string;
  soft?: string;
  hmi?: string;
  commType?: string;
}

/** The 5 realtime endpoints every acquisition path reads (per inverter SN). */
export const realtimePaths = (sn: string) => ({
  grid: `/api/v1/inverter/grid/${sn}/realtime?sn=${sn}`,
  battery: `/api/v1/inverter/battery/${sn}/realtime?sn=${sn}&lan=en`,
  input: `/api/v1/inverter/${sn}/realtime/input`,
  load: `/api/v1/inverter/load/${sn}/realtime?sn=${sn}`,
  output: `/api/v1/inverter/${sn}/realtime/output`,
});

/** Pull the typed per-inverter fields out of one inverter's 5 raw realtime payloads. */
export function extractReading(inv: InverterInfo, raw: RawBundle): Record<string, unknown> {
  const g = raw.grid, b = raw.battery, p = raw.input, l = raw.load, o = raw.output;
  const battPowerRaw = num(pick(b, "power")); // signed per firmware
  const battSigned = BATTERY_POSITIVE_MEANS === "charging" ? battPowerRaw : -battPowerRaw;
  const outVip0 = (o && Array.isArray(o.vip) && o.vip[0]) || {};
  // Grid voltage lives in the same per-phase shape as the output side. It is the only
  // field that separates "mains failed" from "mains fine, we just aren't drawing" —
  // see migration 0015.
  const gridVip0 = (g && Array.isArray(g.vip) && g.vip[0]) || {};
  return {
    sn: inv.sn,
    status: typeof inv.status === "number" ? inv.status : num(inv.status),
    pv_w: powerField(p, "pac", "solarPower"),
    pv_today_kwh: num(pick(p, "etoday")),
    pv_total_kwh: num(pick(p, "etotal")),
    batt_power_w: battPowerRaw,
    batt_w: battSigned,
    batt_soc: num(pick(b, "soc", "bmsSoc")),
    batt_voltage_v: num(pick(b, "voltage", "bmsVolt")),
    batt_current_a: num(pick(b, "current", "bmsCurrent")),
    batt_temp_c: num(pick(b, "temp", "bmsTemp")), // raw, incl. junk like -100 (filter on read)
    batt_chg_today_kwh: num(pick(b, "etodayChg")),
    batt_dischg_today_kwh: num(pick(b, "etodayDischg")),
    batt_chg_total_kwh: num(pick(b, "etotalChg")),
    batt_dischg_total_kwh: num(pick(b, "etotalDischg")),
    grid_w: powerField(g, "pac"), // + import / - export
    grid_import_today_kwh: num(pick(g, "etodayFrom")),
    grid_export_today_kwh: num(pick(g, "etodayTo")),
    grid_import_total_kwh: num(pick(g, "etotalFrom")),
    grid_export_total_kwh: num(pick(g, "etotalTo")),
    grid_freq_hz: num(pick(g, "fac", "freq")),
    grid_pf: num(pick(g, "pf")),
    // nullable on purpose: absent field must not read as 0 V / grid down
    grid_volt_v: numOrNull(pick(gridVip0, "volt", "voltage")),
    // "Realy" is SunSynk's typo, kept verbatim; the alternates cover a future fix
    grid_relay_status: (() => {
      const v = pick(g, "acRealyStatus", "acRelayStatus", "relayStatus");
      return v === undefined || v === null || v === "" ? null : String(v);
    })(),
    load_w: powerField(l, "pac", "totalPower"), // power only — 'totalUsed' is a kWh counter
    load_today_kwh: num(pick(l, "dailyUsed")),
    load_total_kwh: num(pick(l, "totalUsed")),
    load_freq_hz: num(pick(l, "loadFac", "fac")),
    output_w: powerField(o, "pac"),
    output_volt_v: num(pick(outVip0, "volt", "voltage")),
    output_freq_hz: num(pick(o, "fac", "freq")),
  };
}

/** Per-string PV rows for one inverter (server.js collectAndLog ~1004). */
export function extractStrings(inv: InverterInfo, raw: RawBundle) {
  return (((raw.input && raw.input.pvIV) || []) as any[]).map((s, k) => ({
    sn: inv.sn,
    no: num(pick(s, "pvNo")) || k + 1,
    volt_v: num(pick(s, "vpv", "volt")),
    current_a: num(pick(s, "ipv", "current")),
    power_w: num(pick(s, "ppv", "power")),
    today_kwh: num(pick(s, "todayPv")),
  }));
}

/**
 * Inverter metadata row (server.js collectAndLog ~1016). `ord` is the position in
 * SunSynk's inverter list — the Overview tab renders cards in that order, so it has
 * to survive into storage.
 */
export function extractMeta(inv: InverterInfo, raw: RawBundle, ts: number, ord?: number) {
  return {
    sn: inv.sn,
    updated_ts: ts,
    ord: ord ?? null,
    alias: inv.alias ?? null,
    model: inv.model ?? null,
    soft_ver: inv.soft ?? null,
    hmi_ver: inv.hmi ?? null,
    gsn: inv.gsn ?? null,
    comm_type: inv.commType ?? null,
    capacity_ah: num(pick(raw.battery, "capacity", "correctCap")),
    number_of_batteries: pick(raw.battery, "numberOfBatteries") ?? null,
    plant_id: inv.plantId ?? null,
    plant_name: inv.plantName ?? null,
  };
}

/**
 * Plant-aggregate spine row: summed across inverters, SOC averaged over VALID
 * readings only. A dropped BMS link reports soc 0 — including those would halve the
 * logged SOC, since 0 means "no reading", not a real 0%.
 */
export function aggregate(readings: Record<string, any>[]) {
  const sum = (f: string) => readings.reduce((a, r) => a + (Number(r[f]) || 0), 0);
  const socV = readings.filter((r) => Number(r.batt_soc) > 0);
  return {
    pv_w: Math.round(sum("pv_w")),
    load_w: Math.round(sum("load_w")),
    batt_w: Math.round(sum("batt_w")),
    grid_w: Math.round(sum("grid_w")),
    soc: socV.length
      ? Math.round(socV.reduce((a, r) => a + Number(r.batt_soc), 0) / socV.length)
      : null,
  };
}
