// Sending one billing outbox email (SOLAR-641, notify). Each row goes in its own call under a
// key tied to the row alone, so a retry after a lost answer is answered from the first send,
// whatever other rows are due by then. Resend keeps a key for 24 hours.
export type Post = (url: string, body: unknown, key: string) => Promise<{ status: number; error?: string; retryAfter?: string | null }>;

export const outboxKey = (id: number) => `ob-${id}`;
// msg.outbox email rows (SOLAR-645 step 4): the same rule, their own key.
export const msgKey = (id: number) => `ms-${id}`;

/** A 409 counts as sent only when Resend's body says this key already sent the row and its
 *  words read again since differ (invalid_idempotent_request). The first call still in
 *  progress (concurrent_idempotent_requests), or any other 409, is retried: the retry under
 *  the same key is answered from the first send, so nothing goes twice and nothing is lost. */
export async function sendOutboxOne(post: Post, url: string, o: { id: number; payload: unknown }, key = outboxKey(o.id)) {
  const res = await post(url, o.payload, key);
  return res.status === 409 && /invalid_idempotent_request/.test(res.error ?? "") ? { status: 200 } : res;
}
