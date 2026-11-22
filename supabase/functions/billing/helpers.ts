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

/** What /verify tells the app. "again" means the webhook settled the try first: say how it ended. */
export function verifyStatus(r: { action: string; status?: string } | null): string {
  if (!r) return "pending";
  if (r.action !== "again") return r.action;
  return r.status === "success" ? "applied" : r.status === "not_applied" ? "refund" : r.status ?? "pending";
}

/** Paystack's id for a refund in a refund.* webhook: its id, else its refund_reference. */
export function refundProviderId(d: Record<string, unknown>): string | null {
  const v = d.id ?? d.refund_reference;
  return v != null && v !== "" ? String(v) : null;
}
