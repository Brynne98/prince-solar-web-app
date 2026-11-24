// Small pure pieces of the billing function, kept apart so helpers_test.ts can run them.

/** Run `fn` over `items`, `parallel` at a time, starting nothing after `budgetMs`.
 *  Returns the results of what ran and the items never started. */
export async function pool<T, R>(items: T[], parallel: number, budgetMs: number,
                                 fn: (item: T) => Promise<R>, now = () => Date.now()) {
  const start = now();
  const done: R[] = [];
  let next = 0;
  const worker = async () => {
    while (next < items.length && now() - start < budgetMs) done.push(await fn(items[next++]));
  };
  await Promise.all(Array.from({ length: Math.max(1, parallel) }, worker));
  return { done, left: items.slice(next) };
}

/** What /verify tells the app. "again" means the webhook settled the try first: say how it ended.
 *  No answer from Paystack: "error" (the app says it couldn't check, not that it is still checking). */
export function verifyStatus(r: { action: string; status?: string } | null): string {
  if (!r) return "error";
  if (r.action !== "again") return r.action;
  return r.status === "success" ? "applied"
    : r.status === "not_applied" || r.status === "reversed" ? "refund"
    : r.status === "failed" || r.status === "void" ? "failed" : "pending";
}

/** A refund.* webhook's ids: Paystack's refund id, and its refund_reference. With no id the
 *  database matches the refund on the payment's reference and keeps refund_reference. */
export function refundIds(d: Record<string, unknown>): { provider_id: string | null; provider_ref: string | null } {
  const str = (v: unknown) => v != null && v !== "" ? String(v) : null;
  return { provider_id: str(d.id), provider_ref: str(d.refund_reference) };
}

/** A failed billing command's answer. 22023 and P0002: a refusal the owner reads ("pay the
 *  failed payment first"), 409, not reported. Anything else (a lock clash, 40P01, or another
 *  database fault): 500, and reported, so a repeated one shows in error tracking. */
export function commandFailed(e: unknown, note: (kind: string, e: unknown) => void): { status: number; error: string } {
  const code = (e as { code?: string })?.code;
  const error = e instanceof Error ? e.message.replace(/^\w+: /, "") : String(e);
  if (code === "22023" || code === "P0002") return { status: 409, error };
  note("billing_command_failed", e);
  return { status: 500, error };
}
