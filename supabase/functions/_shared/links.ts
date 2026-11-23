// The billing tables' half of linking a login (link-sunsynk) and claiming a shared plant
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

/** The login and its whole plant list into the billing tables. Live: the locked link_login decides. */
export const saveLogin = (rpc: Rpc, live: boolean, note: Note, user: string, login: string, username: string,
  plants: { id: number; name: string }[]) =>
  write(rpc, live, note, "link_login", { user, login, username, plants: plants.map((p) => ({ id: p.id, name: p.name })) });

/** The claim into the billing tables. Live: claim_plant decides (first claim wins), also on a
 *  plant already ours, so a retry repairs a claim that is missing. */
export const savePlantClaim = (rpc: Rpc, live: boolean, note: Note, user: string, plant: { id: number; name: string }) =>
  write(rpc, live, note, "claim_plant", { user, plant: plant.id, name: plant.name });
