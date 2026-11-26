// Logins and plants (SOLAR-681): linking a login, its plant list, the poll jobs, the share
// login and claims. Vendor calls go through the login's brand adapter (brands/index.ts).
import { noteError } from "./errors.ts";
import { db, dbHandle, rpc } from "./db.ts";
import {
  type Account, brandOf, DEFAULT_BRAND, type InverterInfo, LoginRejected, type VendorPlant, type VendorPlantDetail,
  type VendorPlantId, vendorPlantId,
} from "./brands/index.ts";

/** A plant as a login lists it: our id and the brand's. */
export type PlantInfo = { id: number; vendorId: VendorPlantId; name: string };

/**
 * Our plant id for a brand's plant id. Until our own ids (R10-R12) the two are the same
 * number for every plant; this is the one place that says so.
 */
export const plantIdFor = (_brand: string, v: VendorPlantId): number => Number(v);
export const vendorIdOf = (_brand: string, id: number): VendorPlantId => vendorPlantId(id);
const ours = (brand: string, list: VendorPlant[]): PlantInfo[] =>
  list.map((p) => ({ id: plantIdFor(brand, p.vendorId), vendorId: p.vendorId, name: p.name }));

/** The login's plants from its brand, with our ids. */
export async function listPlants(acc: Account): Promise<PlantInfo[]> {
  return ours(acc.brand, await brandOf(acc.brand).listPlants(acc));
}

/** The login's inverters from its brand, each with our plant id. */
export async function liveInverters(acc: Account): Promise<InverterInfo[]> {
  return (await brandOf(acc.brand).listInverters(acc)).map((i) => ({
    ...i, plantId: i.vendorPlantId != null ? plantIdFor(acc.brand, i.vendorPlantId) : undefined,
  }));
}

/**
 * The account's inverters as the poller last stored them (private.inverters +
 * private.meta, migration 0031). Same shape as getInverters() so the two are
 * interchangeable; empty until the first live fetch has been committed.
 */
export async function getInvertersCached(acc: Account): Promise<InverterInfo[]> {
  const rows = await rpc<any[]>("inverters_cached", { p_account: acc.id });
  return (rows ?? []).map((r) => ({
    sn: r.sn,
    alias: r.alias ?? r.sn,
    plantId: r.plant_id == null ? undefined : Number(r.plant_id),
    plantName: r.plant_name ?? undefined,
    model: r.model ?? undefined,
    status: r.status ?? undefined,
    gsn: r.gsn ?? undefined,
    soft: r.soft_ver ?? undefined,
    hmi: r.hmi_ver ?? undefined,
    commType: r.comm_type ?? undefined,
    lastReading: r.last_reading ?? null,
    carriedRun: Number(r.carried_run) || 0,
    uploadS: r.upload_s == null ? null : Number(r.upload_s),
  }));
}

// ---------------------------------------------------------------------------
// Linking
// ---------------------------------------------------------------------------

/**
 * Link a brand login to a dashboard user. Exchanges the password for tokens,
 * stores the refresh token in Vault, records the plants the account can see.
 * Returns the account id and its plants. The password is dropped on return.
 */
/**
 * A login's plants link locked (paused): shown in Plants, not polled, until their owner
 * ticks which run (0197, SOLAR-537). A login with one plant starts it when the plan has a
 * place open, and a plant ticked before starts again. The database decides which (trigger),
 * under a per-user lock, so two links at once can't both take the last place. Returns the
 * plants and which are paused. `reason` is from before the pick; nothing reads it.
 */
export async function linkAccount(userId: string, username: string, password: string,
  store?: (token: { access: string; expires: number; refresh: string }, plants: PlantInfo[]) => Promise<string>,
  brand = DEFAULT_BRAND) {
  const t = await brandOf(brand).signIn(username, password);
  const expires = t.expires_at;
  const acc: Account = {
    id: "", user_id: userId, username, brand,
    access_token: t.access_token, access_expires_at: expires,
  };
  const plants = await listPlants(acc);
  const invs = await liveInverters(acc);

  // store: the billing tables decide (the link function): the login, its token
  // and billing's half in one transaction, so a refusal throws before any plant is linked
  // and leaves no login behind.
  if (store) {
    acc.id = await store({ access: t.access_token, expires, refresh: t.refresh_token }, plants);
  } else {
    acc.id = await rpc<string>("account_upsert", {
      p_user: userId, p_username: username, p_access: t.access_token, p_expires: acc.access_expires_at,
    });
    await rpc("account_refresh_set", { p_account: acc.id, p_refresh: t.refresh_token });
  }
  const active = new Set((await syncPlants(acc, { plants, invs })).map((p) => p.id));
  const paused = plants.filter((p) => !active.has(p.id)).map((p) => p.id);
  return { accountId: acc.id, plants, paused, reason: paused.length ? "upgrade_needed" : null };
}

/**
 * Record every plant the account can see against its dashboard user, and seed
 * plant_config for any plant that has no row yet. Timezone and lat/lon are
 * the brand's own values for the site; panel capacity is not seeded at all, because
 * the brand's figure is the one from the first install (0054). Currency is not sent, so the seed stores
 * rand: the app serves South Africa only for now. Never overwrites a
 * config row (the user's edits are theirs) and never removes a plant_users row
 * (unlinking stays a user action). Called at link time and by the poller's
 * hourly refresh, so a plant added at the brand later shows up on its own.
 *
 * Plant detail is one call per plant and only ever seeds a missing config row, so
 * it is fetched only for plants that have none (one select, zero brand calls
 * for a plant already seeded).
 */
const MAX_BOOTSTRAP_KICKS = 5;
export async function syncPlants(acc: Account, linked?: { plants: PlantInfo[]; invs: InverterInfo[] }): Promise<PlantInfo[]> {
  const all = linked?.plants ?? await listPlants(acc);
  const invs = linked?.invs;
  // The hourly refresh links a plant the brand shows later. The database links it locked
  // (0197 trigger); the user sees it in Plants and ticks it or upgrades. The whole list goes:
  // a plant of this login missing from it twice is marked gone (plant_users_upsert).
  await rpc("plant_users_upsert", {
    p_user: acc.user_id, p_account: acc.id,
    p_rows: all.slice().sort((a, b) => a.id - b.id).map((p) => ({ plant_id: p.id, plant_name: p.name })),
  });
  // The same list into the billing tables (0246): new plants added, one missing twice is gone.
  // Not linked there yet (before the switch-over): nothing happens.
  try {
    await rpc("billing_jobs", { p_cmd: "login_seen", p_args: { login: acc.id, plants: all.map((p) => ({ id: p.id, name: p.name })) } });
  } catch (e) {
    noteError("login_seen_failed", e, { user: acc.user_id, hourly: true });
  }
  // Only plants this user reads go on: any other gets its config row, nothing more. Which
  // plants are read comes from the billing tables once they are live (0247 chosen_plant_ids).
  const chosen = new Set(((await rpc<number[] | null>("chosen_plant_ids", { p_user: acc.user_id })) ?? []).map(Number));
  const paused = new Set(all.map((p) => p.id).filter((id) => !chosen.has(id)));
  return await seedPlants(acc, all, paused, invs);
}

/**
 * The part of syncPlants after plant_users: store a paused plant's serials, and seed,
 * import and kick the active plants that have no plant_config row yet. A claimed shared
 * plant (SOLAR-310) comes through here too. Returns the active plants.
 *
 * A paused plant with no row gets one too, with the brand's zone and lat/lon but no
 * history bookmarks (0192): the state a stopped plant is in. Starting it
 * (plant_start_fill) then sets the bookmarks in the plant's own zone (SOLAR-481).
 */
export async function seedPlants(acc: Account, all: PlantInfo[], paused: Set<number>, invs?: InverterInfo[]): Promise<PlantInfo[]> {
  const plants = all.filter((p) => !paused.has(p.id));
  // A paused plant's inverter serials are stored too, so the paywall can price it.
  // Nothing polls them: plantsToPoll leaves paused plants out.
  if (paused.size && invs) {
    const seed = invs.filter((i) => i.plantId != null && paused.has(Number(i.plantId)));
    if (seed.length) {
      try { await rpc("inverters_seed", { p_rows: seed.map((i) => ({ sn: i.sn, plant_id: i.plantId, account_id: acc.id })) }); }
      catch (e) {
        console.warn(`inverter seed for paused ${[...paused].join(",")}:`, e instanceof Error ? e.message : e);
        noteError("inverter_seed_failed", e, { user: acc.user_id, hourly: true });
      }
    }
  }
  const have = new Set(await dbHandle().configuredPlants(all.map((p) => p.id)));
  const missing = all.filter((p) => !have.has(p.id));
  const details = await Promise.allSettled(missing.map((p) => brandOf(acc.brand).plantDetail(acc, p.vendorId)));
  const rows = details
    .filter((r): r is PromiseFulfilledResult<VendorPlantDetail> => r.status === "fulfilled")
    .map((r) => ({
      plant_id: plantIdFor(acc.brand, r.value.vendorId), timezone: r.value.timezone,
      lat: r.value.lat, lon: r.value.lon, paused: paused.has(plantIdFor(acc.brand, r.value.vendorId)),
    }));
  if (rows.length) await rpc("plant_config_seed", { p_rows: rows });
  const activeRows = rows.filter((r) => !r.paused);
  // A plant that is not read (0205: no plan, the free week over): recover never walks
  // it back, so drop the 60-day bookmarks now rather than show "Fetching history".
  if (activeRows.length) {
    const live = await livePlants();
    const cut = activeRows.map((r) => r.plant_id).filter((id) => !live.has(id));
    if (cut.length) {
      try { await dbHandle().clearBookmarks(cut); }
      catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.warn(`free bookmarks ${cut.join(",")}: ${msg}`);
        noteError("free_bookmarks_failed", new Error(`free bookmarks ${cut.join(",")}: ${msg}`), { hourly: true });
      }
    }
  }
  // Plants seeded just now (0044): store their inverter serials so `recover` can
  // ask the brand for per-inverter history before the first poll has run, then fire
  // sync-plant-energy and recover for each. Best effort — a failure here leaves
  // the plant on the nightly schedule, which is where it was before 0044.
  if (activeRows.length) {
    const seededIds = activeRows.map((r) => r.plant_id);
    const wanted = new Set(seededIds);
    try {
      const seed = (invs ?? await liveInverters(acc)).filter((i) => i.plantId != null && wanted.has(Number(i.plantId)));
      if (seed.length) {
        await rpc("inverters_seed", { p_rows: seed.map((i) => ({ sn: i.sn, plant_id: i.plantId, account_id: acc.id })) });
      }
    } catch (e) {
      // recover refuses to walk a plant with no serials, and the first poll stores them.
      console.warn(`inverter seed for ${seededIds.join(",")}:`, e instanceof Error ? e.message : e);
      noteError("inverter_seed_failed", e, { user: acc.user_id, hourly: true });
    }
    // Two edge invocations per plant. An installer login can see hundreds of
    // plants at once; those go to the nightly schedule instead of a burst.
    if (seededIds.length <= MAX_BOOTSTRAP_KICKS) {
      for (const pid of seededIds) {
        try { await rpc("plant_bootstrap_kick", { p_plant: pid }); }
        catch (e) {
          console.warn(`bootstrap kick ${pid}:`, e instanceof Error ? e.message : e);
          noteError("bootstrap_kick_failed", e, { plant: pid, hourly: true });
        }
      }
    } else {
      console.log(`${seededIds.length} plants seeded at once; leaving them to the schedule`);
    }
  }
  return plants;
}

/**
 * One-time bootstrap so a deployment that used to run on env credentials keeps
 * logging without anyone visiting the Connect screen. Needs the brand's bootstrap login
 * (brands/) and BOOTSTRAP_USER_EMAIL. No-op if that login is already linked.
 */
export async function ensureBootstrapAccount(): Promise<boolean> {
  const creds = brandOf(DEFAULT_BRAND).bootstrapLogin();
  const email = Deno.env.get("BOOTSTRAP_USER_EMAIL");
  if (!creds || !email) return false;
  const { username, password } = creds;

  const existing = await rpc<any[]>("account_by_username", { p_username: username });
  if (Array.isArray(existing) && existing.length) return false;

  const { data, error } = await db.auth.admin.listUsers({ perPage: 1000 });
  if (error) throw new Error(`listUsers: ${error.message}`);
  const user = data.users.find((u) => u.email?.toLowerCase() === email.toLowerCase());
  if (!user) throw new Error(`bootstrap: no auth user with email ${email}`);

  await linkAccount(user.id, username, password);
  console.log(`bootstrap: linked ${username} to ${email}`);
  return true;
}

/** Every plant that should be worked on, with the account that can read it. */
export type PlantJob = {
  plantId: number; plantName: string | null; timezone: string;
  /** the brand's id for the plant: only for calls to the brand (R12) */
  vendorPlantId: VendorPlantId;
  /** plant_config.batt_positive_means; null until detected or set (0041) */
  battPositiveMeans: string | null;
  /** plant_config.backfill_next / backfill_until (0044): YYYY-MM-DD, null = none pending */
  backfillNext: string | null;
  backfillUntil: string | null;
  backfillTries: number;
  /** plant_config.temp_next (0045): next local day of the inverter-temperature walk; null = not started */
  tempNext: string | null;
  tempTries: number;
  /** plant_config.has_grid (0042): false = off-grid, null = not known yet */
  hasGrid: boolean | null;
  /** billing.plants.version (0246): writes for the plant carry it; null before the billing switch-over */
  version: number | null;
  account: Account;
};

/** Every plant that is read, each through one login: poll_jobs as one shard (0205). */
export const plantsToPoll = (): Promise<PlantJob[]> => pollJobs(0, 1);

/**
 * One poll shard's jobs (0100). The database picks the plants and each plant's login,
 * and the shard filter runs there, so a shard reads only its own accounts. Since the
 * billing switch-over (0246): the plants billing.plant_state reads now, each through one
 * working route (an ok login that lists it, else a share claim). Before it, 0205's rule.
 * account set = only plants read through that account, whatever the shard.
 */
export async function pollJobs(shard: number, shards: number, account?: string): Promise<PlantJob[]> {
  const rows = await rpc<any[]>("poll_jobs_v2", { p_shard: shard, p_shards: shards, p_account: account ?? null });
  const accs = new Map<string, Account>();
  return (rows ?? []).map((r) => {
    const acc = accs.get(r.account_id) ?? {
      id: r.account_id, user_id: r.user_id, brand: r.brand ?? DEFAULT_BRAND,
      username: r.sunsynk_username, // reuse-check: allow (column renamed with the login table, R3)
      access_token: r.access_token, access_expires_at: r.access_expires_at,
    };
    accs.set(acc.id, acc); // one object per account: its token is refreshed in place
    return {
      plantId: Number(r.plant_id),
      vendorPlantId: r.vendor_plant_id != null ? vendorPlantId(r.vendor_plant_id) : vendorIdOf(acc.brand, Number(r.plant_id)),
      plantName: r.plant_name ?? null,
      timezone: String(r.timezone),
      battPositiveMeans: r.batt_positive_means ?? null,
      backfillNext: r.backfill_next ?? null,
      backfillUntil: r.backfill_until ?? null,
      backfillTries: Number(r.backfill_tries),
      tempNext: r.temp_next ?? null,
      tempTries: Number(r.temp_tries),
      hasGrid: r.has_grid ?? null,
      version: r.plant_version == null ? null : Number(r.plant_version),
      account: acc,
    };
  });
}

/**
 * Round-robin for the batch functions (recover, sync-plant-energy). Each has a
 * time budget shared across every plant; without this, plants late in the list
 * could starve run after run (READINESS P3). The id of the last plant a run
 * finished is kept in app_config under `key`; the next run starts after it.
 */
/** The plants that are read (0205): an account that runs the plant has a plan or is in its free week. */
export async function livePlants(): Promise<Set<number>> {
  const ids = await rpc<number[]>("live_plants", {});
  return new Set((ids ?? []).map(Number));
}

export async function rotateJobs<T extends { plantId: number }>(jobs: T[], key: string): Promise<T[]> {
  if (jobs.length < 2) return jobs;
  const { data } = await db.from("app_config").select("value").eq("key", key).maybeSingle();
  const last = data ? Number(data.value) : null;
  if (last == null) return jobs;
  const i = jobs.findIndex((j) => j.plantId === last);
  if (i < 0) return jobs; // that plant is gone; start from the top
  return [...jobs.slice(i + 1), ...jobs.slice(0, i + 1)];
}
export async function markCursor(key: string, plantId: number): Promise<void> {
  const { error } = await db.from("app_config")
    .upsert({ key, value: plantId, note: "last plant finished by this batch function; the next run starts after it" }, { onConflict: "key" });
  if (error) {
    console.warn(`cursor ${key}:`, error.message);
    noteError("cursor_failed", new Error(`cursor ${key}: ${error.message}`), { hourly: true });
  }
}

// ---------------------------------------------------------------------------
// Shared plants (SOLAR-310, 0172)
// ---------------------------------------------------------------------------

/** The auth user that owns the share login row: one for the share address, made once. */
async function shareUserId(address: string): Promise<string> {
  // Not confirmed: nobody signs in as it, and the welcome and no-plant emails never start.
  const made = await db.auth.admin.createUser({ email: address, email_confirm: false });
  if (made.data?.user) return made.data.user.id;
  for (let page = 1; page <= 50; page++) {
    const { data, error } = await db.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw new Error(`listUsers: ${error.message}`);
    const u = data.users.find((x) => x.email?.toLowerCase() === address.toLowerCase());
    if (u) return u.id;
    if (data.users.length < 1000) break;
  }
  throw new Error(`share login: no auth user for the share address (${made.error?.message ?? "create failed"})`);
}

/**
 * The share login, signed in. Signs in with the secret when there is no row yet or the
 * stored one died. Null when the secrets are not set.
 */
export async function shareAccount(brand = DEFAULT_BRAND): Promise<Account | null> {
  const creds = brandOf(brand).shareLogin();
  if (!creds) return null;
  const row = (await rpc<any[]>("share_account_get", {}))?.[0];
  if (row?.status === "active") {
    return { id: row.id, user_id: row.user_id, username: creds.username, brand, access_token: row.access_token, access_expires_at: row.access_expires_at };
  }
  const t = await brandOf(brand).signIn(creds.username, creds.password);
  const userId: string = row?.user_id ?? await shareUserId(creds.username);
  const id = await rpc<string>("share_account_set", {
    p_user: userId, p_username: creds.username, p_access: t.access_token, p_expires: t.expires_at,
  });
  await rpc("account_refresh_set", { p_account: id, p_refresh: t.refresh_token });
  return { id, user_id: userId, username: creds.username, brand, access_token: t.access_token, access_expires_at: t.expires_at };
}

/** Hourly in poll: claimed plants that left the share list stop, and come back when shared again. */
export async function shareSync(acc: Account): Promise<unknown> {
  // the whole list or a throw (R9): a cut list would read the cut plants as unshared
  const plants = await listPlants(acc);
  return await rpc("share_sync", { p_account: acc.id, p_plants: plants.map((p) => p.id) });
}

export type ClaimResult =
  | { result: "not_shared" }
  | { result: "taken" | "yours" | "claimed" | "claimed_paused"; plantId: number; plantName: string };

/**
 * Claim a plant shared to the share login: `ref` is its plant id or one of its inverter
 * serials. Checked live against what the brand shows the share login.
 */
export async function claimShared(userId: string, ref: string,
  claim?: (account: string, plant: PlantInfo) => Promise<"taken" | "yours" | "claimed" | "claimed_paused">): Promise<ClaimResult> {
  const acc = await shareAccount();
  if (!acc) throw new Error("share login not set up");
  const plants = await listPlants(acc);
  // The login just answered: say so, or a plant claimed between polls shows "Not updating"
  // for its first minutes, timed from the share login's last poll (SOLAR-448).
  await rpc("account_access_set", { p_account: acc.id, p_access: acc.access_token, p_expires: acc.access_expires_at });
  let invs: InverterInfo[] | undefined;
  let plant = /^\d+$/.test(ref) ? plants.find((p) => p.id === Number(ref)) : undefined;
  if (!plant) {
    invs = await liveInverters(acc);
    const inv = invs.find((i) => i.sn.toLowerCase() === ref.toLowerCase());
    plant = inv?.plantId != null ? plants.find((p) => p.id === Number(inv.plantId)) : undefined;
  }
  if (!plant) return { result: "not_shared" };
  // claim: claim-share's one transaction (share_claim_any), the old claim before the switch and
  // billing's after it. It throws to refuse.
  const result = claim ? await claim(acc.id, plant) : await rpc<"taken" | "yours" | "claimed" | "claimed_paused">("share_claim", {
    p_user: userId, p_account: acc.id, p_plant: plant.id, p_plant_name: plant.name,
  });
  if (result === "claimed" || result === "claimed_paused") {
    invs ??= await liveInverters(acc);
    const mineOnly = invs.filter((i) => Number(i.plantId) === plant.id);
    await seedPlants(acc, [plant], new Set(result === "claimed_paused" ? [plant.id] : []), mineOnly);
  }
  return { result, plantId: plant.id, plantName: plant.name };
}
