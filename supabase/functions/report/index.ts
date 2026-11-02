// POST /functions/v1/report
// Authorization: Bearer <user access token>
// Body: {"periods": {"1D": {"input": n, "output": n, "usd": x, "start": "YYYY-MM-DD"}, ... all six}}
//
// Verifies the caller's JWT, then stores the report through public.apply_report(), which enforces
// plausibility (no negatives, daily ceilings, 1D <= 7D <= 30D <= 1Y <= ALL, 1D <= YTD <= ALL) and
// the 25-minute rate limit. Responds with the caller's places for every period and unit.
//
// 200 {"stored": 6, "next_report_after": ts, "ranks": [...]}
// 400 malformed JSON, 401 no or invalid token, 403 not a participant, 405 wrong method,
// 413 body too large, 422 implausible report, 429 rate limited (Retry-After header).

import { createClient } from "jsr:@supabase/supabase-js@2";

const MAX_BODY = 16 * 1024;

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

function reply(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { error: "POST only" });

  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "").trim();
  if (!token) return reply(401, { error: "missing token" });
  const { data: who, error: authError } = await admin.auth.getUser(token);
  if (authError || !who?.user) return reply(401, { error: "invalid token" });

  const raw = await req.text();
  if (raw.length > MAX_BODY) return reply(413, { error: "body too large" });
  let payload: unknown;
  try {
    payload = JSON.parse(raw);
  } catch {
    return reply(400, { error: "body is not JSON" });
  }

  const { data, error } = await admin.rpc("apply_report", { p_user: who.user.id, p_payload: payload });
  if (error) {
    if (error.code === "22023") return reply(422, { error: error.message });
    if (error.code === "42501") return reply(403, { error: error.message });
    if (error.message === "rate limited") {
      const wait = Math.max(1, parseInt(error.details ?? "60", 10) || 60);
      return reply(429, { error: "rate limited", retry_after: wait }, { "Retry-After": String(wait) });
    }
    console.error("apply_report failed", error.code, error.message);
    return reply(500, { error: "could not store the report" });
  }

  // Places are read as the caller, so row level security applies exactly as in the app.
  const asUser = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: ranks, error: rankError } = await asUser.rpc("my_ranks");
  if (rankError) console.error("my_ranks failed", rankError.code, rankError.message);

  return reply(200, { ...data, ranks: ranks ?? [] });
});
