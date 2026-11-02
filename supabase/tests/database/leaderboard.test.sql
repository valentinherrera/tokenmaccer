-- Leaderboard: RLS, plausibility, ranking, leave, rate limit. Run with `supabase test db`.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(63);

-- Fixtures: synthetic users only -----------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'test-a@example.com', '{"provider":"github","providers":["github"]}', '{"user_name":"test-a"}', now(), now()),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'test-b@example.com', '{"provider":"github","providers":["github"]}', '{"user_name":"test-b"}', now(), now()),
  ('00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'test-c@example.com', '{"provider":"github","providers":["github"]}', '{"user_name":"test-c"}', now(), now()),
  ('00000000-0000-0000-0000-00000000000e', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'test-e@example.com', '{"provider":"email","providers":["email"]}', '{}', now(), now()),
  -- d claims GitHub in its metadata but has no GitHub identity.
  ('00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'test-d@example.com', '{"provider":"github","providers":["github"]}', '{"user_name":"test-d"}', now(), now());

-- GitHub identities as the auth server writes them at sign-in (not writable by the user).
insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
values
  ('9000000001', '00000000-0000-0000-0000-00000000000a',
   '{"sub":"9000000001","user_name":"test-a","preferred_username":"test-a"}', 'github', now(), now(), now()),
  ('9000000002', '00000000-0000-0000-0000-00000000000b',
   '{"sub":"9000000002","user_name":"test-b","preferred_username":"test-b"}', 'github', now(), now(), now()),
  ('9000000003', '00000000-0000-0000-0000-00000000000c',
   '{"sub":"9000000003","user_name":"test-c","preferred_username":"test-c"}', 'github', now(), now(), now());

-- A consistent report: 1D <= 7D <= 30D <= 1Y <= ALL, YTD between 1D and ALL.
create function pg_temp.report(p_scale numeric, p_usd numeric) returns jsonb language sql as $$
  select jsonb_build_object('periods', jsonb_build_object(
    '1D',  jsonb_build_object('input', 1000 * p_scale,    'output', 10 * p_scale,   'usd', 1 * p_usd,   'start', current_date),
    '7D',  jsonb_build_object('input', 7000 * p_scale,    'output', 70 * p_scale,   'usd', 7 * p_usd,   'start', current_date - 6),
    '30D', jsonb_build_object('input', 30000 * p_scale,   'output', 300 * p_scale,  'usd', 30 * p_usd,  'start', current_date - 29),
    'YTD', jsonb_build_object('input', 50000 * p_scale,   'output', 500 * p_scale,  'usd', 50 * p_usd,  'start', date_trunc('year', current_date)::date),
    '1Y',  jsonb_build_object('input', 100000 * p_scale,  'output', 1000 * p_scale, 'usd', 100 * p_usd, 'start', current_date - 364),
    'ALL', jsonb_build_object('input', 200000 * p_scale,  'output', 2000 * p_scale, 'usd', 200 * p_usd, 'start', current_date - 500)))
$$;
grant execute on function pg_temp.report(numeric, numeric) to authenticated, anon;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  select set_config('role', 'authenticated', true);
$$;
grant execute on function pg_temp.as_user(uuid) to authenticated, anon;

-- Join ---------------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select is((select github_login from join_leaderboard('Alpha')), 'test-a', 'join takes the GitHub login from the auth record');
-- A forges a foreign login into the own user metadata (what PUT /auth/v1/user with `data` allows).
reset role;
update auth.users set raw_user_meta_data = '{"user_name":"test-b","preferred_username":"test-b"}'
 where id = '00000000-0000-0000-0000-00000000000a';
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select is((select github_login from join_leaderboard('Alpha')), 'test-a',
  'a login forged into user metadata is ignored; the GitHub identity wins');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is((select display_name from join_leaderboard('  ')), 'test-b', 'blank display name falls back to the login');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e');
select throws_ok($$select join_leaderboard('Mail')$$, '42501', 'GitHub sign-in required', 'an email account cannot join');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select throws_ok($$select join_leaderboard('Claim')$$, '42501', 'GitHub sign-in required',
  'GitHub in the metadata without a GitHub identity cannot join');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select throws_ok($$select join_leaderboard(repeat('x', 33))$$, '22023', null, 'display names longer than 32 characters are refused');

-- Writes by clients ---------------------------------------------------------------------------------
select throws_ok(
  $$insert into totals (user_id, period, tokens_input, tokens_output, usd, period_start)
    values ('00000000-0000-0000-0000-00000000000a', '1D', 1, 1, 1, current_date)$$,
  '42501', null, 'a client cannot write its own totals directly');
select throws_ok(
  $$insert into totals (user_id, period, tokens_input, tokens_output, usd, period_start)
    values ('00000000-0000-0000-0000-00000000000b', '1D', 1, 1, 1, current_date)$$,
  '42501', null, 'a client cannot write totals of someone else');
select throws_ok(
  $$insert into profiles (id, display_name) values ('00000000-0000-0000-0000-00000000000c', 'Fake')$$,
  '42501', null, 'a client cannot create a profile for someone else');
select is_empty(
  $$update profiles set display_name = 'Hijacked' where id = '00000000-0000-0000-0000-00000000000b' returning id$$,
  'updating the display name of someone else changes no row');
select isnt_empty(
  $$update profiles set display_name = 'Alpha 2' where id = '00000000-0000-0000-0000-00000000000a' returning id$$,
  'updating the own display name works');
select throws_ok(
  $$update profiles set opted_in_at = now() - interval '9 years' where id = '00000000-0000-0000-0000-00000000000a'$$,
  '42501', null, 'columns other than display_name are not writable');
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000a', pg_temp.report(1, 1))$$,
  '42501', null, 'apply_report is not callable by clients');
select throws_ok(
  $$delete from profiles where id = '00000000-0000-0000-0000-00000000000b'$$,
  '42501', null, 'a client cannot delete profiles directly');
reset role;
select is((select display_name from profiles where id = '00000000-0000-0000-0000-00000000000b'), 'test-b',
  'the other participant''s display name is unchanged');

-- anon ---------------------------------------------------------------------------------------------
set local role anon;
select throws_ok($$select * from profiles$$, '42501', null, 'anon cannot read profiles');
select throws_ok($$select * from totals$$, '42501', null, 'anon cannot read totals');
select throws_ok($$select * from leaderboard('7D', 'tokens', 10)$$, '42501', null, 'anon cannot read the leaderboard');
reset role;

-- Plausibility (as the Edge Function does it, with the service role) -------------------------------
set local role service_role;
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000a',
      jsonb_set(pg_temp.report(1, 1), '{periods,1D,input}', '-5'))$$,
  '22023', null, 'negative values are refused');
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000a',
      jsonb_set(pg_temp.report(1, 1), '{periods,1D,input}', '8000'))$$,
  '22023', 'inconsistent periods: 1D exceeds 7D', '1D above 7D is refused');
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000a',
      jsonb_set(pg_temp.report(1, 1), '{periods,YTD,usd}', '1000'))$$,
  '22023', 'inconsistent periods: YTD exceeds ALL', 'YTD above ALL is refused');
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000a', pg_temp.report(100000000, 1))$$,
  '22023', 'period 1D: above the daily ceiling', '1e11 input tokens in one day are refused');
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000a', pg_temp.report(1, 60000))$$,
  '22023', 'period 1D: above the daily ceiling', 'USD 60000 in one day is refused');
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000a', pg_temp.report(1, 1) #- '{periods,ALL}')$$,
  '22023', 'period ALL missing', 'a report without every period is refused');
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000a',
      jsonb_set(pg_temp.report(1, 1), '{periods,2D}', '{}'))$$,
  '22023', 'unknown period 2D', 'unknown periods are refused');
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000a',
      jsonb_set(pg_temp.report(1, 1), '{periods,7D,input}', '7000.5'))$$,
  '22023', null, 'fractional token counts are refused');
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000a',
      jsonb_set(pg_temp.report(1, 1), '{periods,1D,input}', '"1000"'))$$,
  '22023', null, 'numbers sent as strings are refused');
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000c', pg_temp.report(1, 1))$$,
  '42501', 'not a participant', 'someone who did not join cannot report');
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000a',
      jsonb_set(pg_temp.report(1, 1), '{periods,7D,start}', to_jsonb(current_date - 7)))$$,
  '22023', 'inconsistent period starts', 'a 7D window that does not end on the 1D day is refused');
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000a',
      jsonb_set(pg_temp.report(1, 1), '{periods,YTD,start}', to_jsonb(current_date - 400)))$$,
  '22023', 'inconsistent period starts', 'a YTD that does not start on 1 January is refused');
select throws_ok(
  $$select apply_report('00000000-0000-0000-0000-00000000000a',
      jsonb_set(pg_temp.report(1, 1), '{periods,ALL,start}', to_jsonb(current_date + 1)))$$,
  '22023', 'inconsistent period starts', 'an ALL period starting after today is refused');

-- Valid reports: B has more tokens, A spends more USD.
select lives_ok($$select apply_report('00000000-0000-0000-0000-00000000000a', pg_temp.report(1, 5))$$,
  'a plausible report is stored (rejected attempts did not use up the rate limit)');
select lives_ok($$select apply_report('00000000-0000-0000-0000-00000000000b', pg_temp.report(3, 1))$$,
  'a second participant reports');
select throws_ok($$select apply_report('00000000-0000-0000-0000-00000000000a', pg_temp.report(1, 5))$$,
  'P0001', 'rate limited', 'a second report within 25 minutes is refused');
reset role;
select is((select count(*)::int from totals where user_id = '00000000-0000-0000-0000-00000000000a'), 6,
  'all six periods are stored in one report');

-- Ranking ------------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select results_eq($$select display_name, rank from leaderboard('7D', 'tokens', 10)$$,
  $$values ('test-b'::text, 1::bigint), ('Alpha 2'::text, 2::bigint)$$, 'tokens rank by input tokens');
select results_eq($$select display_name, rank from leaderboard('7D', 'usd', 10)$$,
  $$values ('Alpha 2'::text, 1::bigint), ('test-b'::text, 2::bigint)$$, 'usd ranks separately');
select results_eq($$select rank, participants from my_rank('30D', 'tokens')$$,
  $$values (2::bigint, 2::bigint)$$, 'my_rank gives #2 of 2 for tokens');
select results_eq($$select rank, participants, value from my_rank('ALL', 'usd')$$,
  $$values (1::bigint, 2::bigint, 1000.00::numeric)$$, 'my_rank gives #1 of 2 for usd with the value');
select is((select count(*)::int from my_ranks()), 12, 'my_ranks returns 6 periods x 2 units');
select results_eq($$select rank, participants from my_ranks() where period = '30D' and unit = 'tokens'$$,
  $$values (2::bigint, 2::bigint)$$, 'my_ranks agrees with my_rank');
select throws_ok($$select * from my_rank('2D', 'tokens')$$, '22023', null, 'unknown periods are refused by my_rank');
select throws_ok($$select * from leaderboard('7D', 'euro', 10)$$, '22023', null, 'unknown units are refused');

-- A non-participant sees no rank and the participant count.
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select results_eq($$select rank, participants from my_rank('1D', 'tokens')$$,
  $$values (null::bigint, 2::bigint)$$, 'someone outside the board gets no rank but the count');

-- A 1D total from three days ago no longer counts on today's board.
reset role;
update totals set period_start = current_date - 3
 where user_id = '00000000-0000-0000-0000-00000000000b' and period = '1D';
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select results_eq($$select rank, participants from my_rank('1D', 'tokens')$$,
  $$values (null::bigint, 1::bigint)$$, 'a stale 1D total drops out of the 1D board');

-- Paused participants are invisible to others ------------------------------------------------------
reset role;
update profiles set opted_in_at = null where id = '00000000-0000-0000-0000-00000000000a';
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is_empty($$select 1 from profiles where id = '00000000-0000-0000-0000-00000000000a'$$,
  'a paused participant''s profile is invisible to others');
select is_empty($$select 1 from totals where user_id = '00000000-0000-0000-0000-00000000000a'$$,
  'a paused participant''s totals are invisible to others');
select results_eq($$select rank, participants from my_rank('7D', 'usd')$$,
  $$values (1::bigint, 1::bigint)$$, 'a paused participant is not counted');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from totals where user_id = '00000000-0000-0000-0000-00000000000a'), 6,
  'a paused participant still sees the own totals');

-- Leave ------------------------------------------------------------------------------------------
select ok((select leave_leaderboard()), 'leave succeeds');
reset role;
select is((select count(*)::int from profiles where id = '00000000-0000-0000-0000-00000000000a')
        + (select count(*)::int from totals where user_id = '00000000-0000-0000-0000-00000000000a'), 0,
  'leave deletes the profile and every total');
delete from auth.users where id = '00000000-0000-0000-0000-00000000000b';
select is((select count(*)::int from totals where user_id = '00000000-0000-0000-0000-00000000000b'), 0,
  'deleting the auth account removes profile and totals');

-- Rate limit survives leave, join and a new account ----------------------------------------------
-- A reported above (same transaction, so now() is unchanged) and has just left.
select is((select count(*)::int from private.report_limits where subject = 'github:9000000001'), 1,
  'the rate-limit slot of A is kept after leave');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select throws_ok($$select * from private.report_limits$$, '42501', null, 'clients cannot read the rate-limit table');
select is((select display_name from join_leaderboard('Alpha again')), 'Alpha again', 'A joins again after leaving');
reset role;
set local role service_role;
select throws_ok($$select apply_report('00000000-0000-0000-0000-00000000000a', pg_temp.report(1, 1))$$,
  'P0001', 'rate limited', 'leave then join does not reset the rate limit');
reset role;
-- The same GitHub user with a new auth account (account deleted, signed in again).
delete from auth.users where id = '00000000-0000-0000-0000-00000000000a';
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'test-a2@example.com', '{"provider":"github","providers":["github"]}', '{"user_name":"test-a"}', now(), now());
insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
values ('9000000001', '00000000-0000-0000-0000-0000000000a2',
        '{"sub":"9000000001","user_name":"test-a","preferred_username":"test-a"}', 'github', now(), now(), now());
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select lives_ok($$select join_leaderboard('Alpha new')$$, 'the same GitHub user joins with a new account');
reset role;
set local role service_role;
select throws_ok($$select apply_report('00000000-0000-0000-0000-0000000000a2', pg_temp.report(1, 1))$$,
  'P0001', 'rate limited', 'a new auth account of the same GitHub user does not reset the rate limit');
reset role;
-- Positive control: once the slot is 26 minutes old the report goes through; rows older than an hour go.
update private.report_limits set last_report_at = now() - interval '26 minutes' where subject = 'github:9000000001';
insert into private.report_limits (subject, last_report_at) values ('uid:old-left-participant', now() - interval '2 hours');
set local role service_role;
select lives_ok($$select apply_report('00000000-0000-0000-0000-0000000000a2', pg_temp.report(1, 1))$$,
  'after 25 minutes the same GitHub user may report again');
reset role;
select is((select last_report_at from private.report_limits where subject = 'github:9000000001'), now(),
  'the accepted report claims the slot');
select is((select count(*)::int from private.report_limits where subject = 'uid:old-left-participant'), 0,
  'slots older than one hour are deleted with the next report');
select is((select last_report_at from profiles where id = '00000000-0000-0000-0000-0000000000a2'), now(),
  'profiles.last_report_at still records the last accepted report');
select is((select count(*)::int from private.report_limits where subject like 'uid:%'), 0,
  'participants with a GitHub identity are limited by GitHub id, not by auth uid');

select * from finish();
rollback;
