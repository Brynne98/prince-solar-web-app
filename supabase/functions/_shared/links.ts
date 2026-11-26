// The billing tables' half of linking a login (link) and claiming a shared plant
// (claim-share), SOLAR-641. Before the switch-over the old tables decide and the new rows are
// copied (a failure is only noted). Once billing is live the new tables decide: a refusal
// stops the link or claim before any plant is linked, and the browser hears why.

type RpcError = { message: string; code?: string } | null;
export type Rpc = (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: any; error: RpcError }>;
type Note = (what: string, e: Error, ctx: Record<string, unknown>) => void;

/** A refusal the browser is told about: 409 with `answer` as the error. */
export class Refused extends Error {
  constructor(public answer: string) { super(answer); }
}

/** The answer for one of billing's refusals (errcode 22023), else null. */
export function refusal(e: RpcError): string | null {
  const m = e?.message ?? "";
  if (/\btaken\b/.test(m)) return "taken";
  if (/without a plan/.test(m)) return "no plan";
  if (/one login/.test(m)) return "one login";
  return null;
}

/** billing_links state for the user: { live, state, may_add_login, login_known, ... }. Throws when unreadable. */
export async function billingState(rpc: Rpc, user: string, username?: string) {
  const { data, error } = await rpc("billing_links", { p_cmd: "state", p_args: { user, username } });
  if (error) throw new Error(`billing state: ${error.message}`);
  return data as { live: boolean; state: string; may_add_login: boolean; login_known: boolean };
}

async function write(rpc: Rpc, live: boolean, note: Note, what: string, args: Record<string, unknown>) {
  const { error } = await rpc("billing_links", { p_cmd: what, p_args: args });
  if (!error) return;
  if (!live) return note(`${what}_failed`, new Error(`${what}: ${error.message}`), { user: args.user });
  const answer = refusal(error);
  if (answer) throw new Refused(answer);
  throw new Error(`${what}: ${error.message}`);
}

/** A the brand login's email as it is stored and sent: one case, so a reconnect typed in
 *  another case is the same login (the brand ignores the case). */
export const loginName = (s: unknown) => String(s ?? "").trim().toLowerCase();

/** Before the switch: the login and its whole plant list copied into the billing tables. */
export const saveLogin = (rpc: Rpc, live: boolean, note: Note, user: string, login: string, username: string,
  plants: { id: number; name: string }[]) =>
  write(rpc, live, note, "link_login", { user, login, username, plants: plants.map((p) => ({ id: p.id, name: p.name })) });

/** Live: the stored login, its refresh token and billing's link_login in one transaction
 *  (link_login_live). A refusal or failure leaves no login behind. Returns the login's id. */
export async function saveLoginLive(rpc: Rpc, user: string, username: string,
  token: { access: string; expires: number; refresh: string }, plants: { vendorId: string; name: string }[]): Promise<string> {
  const { data, error } = await rpc("link_login_live", {
    p_user: user, p_username: username, p_access: token.access, p_expires: token.expires, p_refresh: token.refresh,
    p_plants: plants.map((p) => ({ vendor_id: p.vendorId, name: p.name })),
  });
  if (!error) return String(data);
  const answer = refusal(error);
  if (answer) throw new Refused(answer);
  throw new Error(`link_login_live: ${error.message}`);
}

export type ClaimAnswer = "taken" | "yours" | "claimed" | "claimed_paused";

/** A plant shared to our login, in one transaction (share_claim_any) that reads the switch under the
 *  billing-run lock. Live: billing's claim_plant decides and the link row is written with it; a
 *  refusal comes back as Refused and nothing is written. Before the switch: the old claim and its
 *  copy into the billing tables together, on every answer but taken, so a retry repairs a missing
 *  copy; a failed copy is only noted. */
export async function claimAny(rpc: Rpc, note: Note, user: string, account: string,
  plant: { vendorId: string; name: string }): Promise<{ result: ClaimAnswer; plant: number }> {
  const { data, error } = await rpc("share_claim_any", { p_user: user, p_account: account, p_plant: plant.vendorId, p_plant_name: plant.name });
  if (error) {
    const answer = refusal(error);
    if (answer) throw new Refused(answer);
    throw new Error(`share_claim_any: ${error.message}`);
  }
  const r = data as { result: ClaimAnswer; plant: number };
  return { result: r.result, plant: Number(r.plant) };
}
