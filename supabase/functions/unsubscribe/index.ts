// One-click unsubscribe for the List-Unsubscribe header (RFC 8058, SOLAR-158).
//
// The email's header carries https://…/functions/v1/unsubscribe?t=<token>&k=<kind>
// with List-Unsubscribe-Post: List-Unsubscribe=One-Click. Gmail and Apple Mail POST
// to it; no sign-in, the per-user token is the proof (email_unsub_token, 0091).
// A GET changes nothing, because mail scanners open links on their own; it sends
// the reader to the Notifications section instead. verify_jwt is off for this function.
import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);
const SETTINGS = "https://app.princesolarhub.com/?tab=account&section=notifications";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "GET") return Response.redirect(SETTINGS, 303);
  if (req.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "GET, POST" } });

  const url = new URL(req.url);
  const token = url.searchParams.get("t") ?? "";
  const kind = url.searchParams.get("k") ?? "";
  if (!UUID.test(token)) return new Response("Not found", { status: 404 });

  const { data, error } = await db.rpc("email_unsubscribe", { p_token: token, p_kind: kind });
  if (error) return new Response("Try again later", { status: 500 });
  if (!data) return new Response("Not found", { status: 404 });
  return new Response("Unsubscribed", { status: 200 });
});
