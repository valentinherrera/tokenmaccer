// POST /functions/v1/delete-account
// Authorization: Bearer <user access token>
//
// Deletes the caller's auth account. Profile and totals go with it (foreign keys cascade).
// For leaving the leaderboard but keeping the sign-in, the app calls the RPC leave_leaderboard().
//
// 200 {"deleted": true}, 401 no or invalid token, 405 wrong method.

import { createClient } from "jsr:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function reply(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { error: "POST only" });
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return reply(401, { error: "missing token" });
  const { data: who, error } = await admin.auth.getUser(token);
  if (error || !who?.user) return reply(401, { error: "invalid token" });

  const { error: deleteError } = await admin.auth.admin.deleteUser(who.user.id);
  if (deleteError) {
    console.error("deleteUser failed", deleteError.message);
    return reply(500, { error: "could not delete the account" });
  }
  return reply(200, { deleted: true });
});
