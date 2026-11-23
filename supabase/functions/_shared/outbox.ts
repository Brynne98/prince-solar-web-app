// Sending one billing outbox email (SOLAR-641, notify). Each row goes in its own call under a
// key tied to the row alone, so a retry after a lost answer is answered from the first send,
// whatever other rows are due by then. Resend keeps a key for 24 hours.
export type Post = (url: string, body: unknown, key: string) => Promise<{ status: number; error?: string }>;

export const outboxKey = (id: number) => `ob-${id}`;

/** 409: this key already sent the row (its words read again since differ): it went. */
export async function sendOutboxOne(post: Post, url: string, o: { id: number; payload: unknown }) {
  const res = await post(url, o.payload, outboxKey(o.id));
  return res.status === 409 ? { status: 200 } : res;
}
