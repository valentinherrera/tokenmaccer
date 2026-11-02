-- leaderboard_top(): all twelve boards in one call, top places plus the caller's own row. `supabase test db`.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(14);

-- Fixtures: synthetic users only, written directly (the report path is tested in leaderboard.test.sql).
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select ('00000000-0000-0000-0000-0000000001' || n)::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
       'authenticated', 'top-' || n || '@example.com', '{"provider":"github","providers":["github"]}',
       json_build_object('user_name', 'top-' || n)::jsonb, now(), now()
  from unnest(array['01', '02', '03', '04', '05']) as n;

-- 01..04 take part, 05 does not; 04 is paused (hidden from everyone else).
insert into profiles (id, github_login, display_name, opted_in_at)
values ('00000000-0000-0000-0000-000000000101', 'top-01', 'One', now()),
       ('00000000-0000-0000-0000-000000000102', 'top-02', 'Two', now()),
       ('00000000-0000-0000-0000-000000000103', 'top-03', 'Three', now()),
       ('00000000-0000-0000-0000-000000000104', 'top-04', 'Four', null);

-- Tokens: One > Two > Three. USD the other way round. 7D only for One and Three; Three's 1D is stale.
insert into totals (user_id, period, tokens_input, tokens_output, usd, period_start, updated_at)
select ('00000000-0000-0000-0000-000000000' || u)::uuid, p, tok, 1, usd,
       case when p = '1D' and u = '103' then current_date - 3 else current_date end, now()
  from (values ('101', 3000, 1.00), ('102', 2000, 2.00), ('103', 1000, 3.00), ('104', 9000, 9.00)) as x (u, tok, usd)
 cross join unnest(array['1D', '7D', '30D', 'YTD', '1Y', 'ALL']) as p
 where not (p = '7D' and u = '102');

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  select set_config('role', 'authenticated', true);
$$;
grant execute on function pg_temp.as_user(uuid) to authenticated, anon;

-- anon ---------------------------------------------------------------------------------------------
set local role anon;
select throws_ok($$select * from leaderboard_top(50)$$, '42501', null, 'anon cannot read the boards');
reset role;

-- A participant inside the top ---------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000101');
select results_eq(
  $$select distinct period, unit from leaderboard_top(50) order by 1, 2$$,
  $$select p, u from unnest(array['1D', '1Y', '30D', '7D', 'ALL', 'YTD']) p cross join unnest(array['tokens', 'usd']) u
    order by 1, 2$$,
  'every period and unit has a board');
select results_eq(
  $$select display_name, rank, participants, value, is_me from leaderboard_top(50) where period = '30D' and unit = 'tokens'$$,
  $$values ('One'::text, 1::bigint, 3::bigint, 3000::numeric, true),
           ('Two'::text, 2::bigint, 3::bigint, 2000::numeric, false),
           ('Three'::text, 3::bigint, 3::bigint, 1000::numeric, false)$$,
  'tokens board: ranked by input tokens, with the board size and the caller marked');
select results_eq(
  $$select display_name, rank, value from leaderboard_top(50) where period = '30D' and unit = 'usd'$$,
  $$values ('Three'::text, 1::bigint, 3.00::numeric), ('Two'::text, 2::bigint, 2.00::numeric),
           ('One'::text, 3::bigint, 1.00::numeric)$$,
  'usd board ranks by the API-price value');
select results_eq(
  $$select display_name from leaderboard_top(50) where period = '7D' and unit = 'tokens'$$,
  $$values ('One'::text), ('Three'::text)$$,
  'a participant without a total for the period is not on that board');
select results_eq(
  $$select display_name, participants from leaderboard_top(50) where period = '1D' and unit = 'tokens'$$,
  $$values ('One'::text, 2::bigint), ('Two'::text, 2::bigint)$$,
  'a stale 1D total is not on today''s board');
select is_empty($$select 1 from leaderboard_top(50) where display_name = 'Four'$$,
  'a paused participant is invisible to others');
select is((select github_login from leaderboard_top(50) where period = 'ALL' and unit = 'tokens' and rank = 1), 'top-01',
  'rows carry the GitHub username (the app derives the avatar from it)');

-- Limit and the own row outside it -------------------------------------------------------------------
select results_eq(
  $$select display_name, rank, is_me from leaderboard_top(1) where period = 'ALL' and unit = 'tokens'$$,
  $$values ('One'::text, 1::bigint, true)$$,
  'inside the limit the own row is not repeated');
select pg_temp.as_user('00000000-0000-0000-0000-000000000103');
select results_eq(
  $$select display_name, rank, participants, is_me from leaderboard_top(1) where period = 'ALL' and unit = 'tokens'$$,
  $$values ('One'::text, 1::bigint, 3::bigint, false), ('Three'::text, 3::bigint, 3::bigint, true)$$,
  'outside the limit the own row is appended with its real rank');
select is((select count(*)::int from leaderboard_top(1000) where period = 'ALL' and unit = 'tokens'), 3,
  'the limit is capped (here: the whole board of three)');
select is((select count(*)::int from leaderboard_top(0) where period = 'ALL' and unit = 'usd'), 1,
  'a limit below 1 still returns the first place (the own row is first here)');

-- Paused or not a participant: sees the board, no own row ------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000104');
select is((select count(*)::int from leaderboard_top(50) where is_me), 0,
  'a paused participant has no row on the boards');
select pg_temp.as_user('00000000-0000-0000-0000-000000000105');
select is((select count(*)::int from leaderboard_top(50) where period = 'ALL' and unit = 'tokens'), 3,
  'someone who did not join sees the board without an own row');

select * from finish();
rollback;
