-- Groups: create, join by code, leave, owner rights, visibility, boards, limits. `supabase test db`.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(59);

-- Fixtures: synthetic users only. 201 Ann (owner), 202 Ben, 203 Cat (outsider), 204 Dan (paused),
-- 205 Eve (no profile: not a participant).
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select ('00000000-0000-0000-0000-000000000' || n)::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
       'authenticated', 'grp-' || n || '@example.com', '{"provider":"github","providers":["github"]}',
       json_build_object('user_name', 'grp-' || n)::jsonb, now(), now()
  from unnest(array['201', '202', '203', '204', '205']) as n;

insert into profiles (id, github_login, display_name, opted_in_at)
values ('00000000-0000-0000-0000-000000000201', 'grp-201', 'Ann', now()),
       ('00000000-0000-0000-0000-000000000202', 'grp-202', 'Ben', now()),
       ('00000000-0000-0000-0000-000000000203', 'grp-203', 'Cat', now()),
       ('00000000-0000-0000-0000-000000000204', 'grp-204', 'Dan', null);

-- Tokens: Cat > Ben > Ann > Dan(paused). Cat is not in the group, so the group board is Ben, Ann.
insert into totals (user_id, period, tokens_input, tokens_output, usd, period_start, updated_at)
select ('00000000-0000-0000-0000-000000000' || u)::uuid, p, tok, 1, usd, current_date, now()
  from (values ('201', 1000, 3.00), ('202', 2000, 2.00), ('203', 9000, 9.00), ('204', 5000, 5.00)) as x (u, tok, usd)
 cross join unnest(array['1D', '7D', '30D', 'YTD', '1Y', 'ALL']) as p;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  select set_config('role', 'authenticated', true);
$$;
grant execute on function pg_temp.as_user(uuid) to authenticated, anon;

create table pg_temp.g (k text primary key, id uuid, code text);
grant all on pg_temp.g to authenticated;

-- anon and non-participants ------------------------------------------------------------------------
set local role anon;
select throws_ok($$select create_group('x')$$, '42501', null, 'anon cannot create a group');
select throws_ok($$select join_group('abcdefghjk')$$, '42501', null, 'anon cannot join');
select throws_ok($$select * from my_groups()$$, '42501', null, 'anon cannot list groups');
select throws_ok($$select * from group_boards(50)$$, '42501', null, 'anon cannot read group boards');
reset role;

select pg_temp.as_user('00000000-0000-0000-0000-000000000205');
select throws_ok($$select create_group('x')$$, '42501', 'join the leaderboard first',
  'only leaderboard participants can create a group');
select throws_ok($$select join_group('abcdefghjk')$$, '42501', 'join the leaderboard first',
  'only leaderboard participants can join a group');

-- Create ----------------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000201');
insert into pg_temp.g select 'a', (r).id, (r).code from (select create_group('  Mac   Friends ') as r) x;
select is((select name from my_groups() where id = (select id from pg_temp.g where k = 'a')), 'Mac Friends',
  'the name is trimmed and inner spaces collapsed');
select matches((select code from pg_temp.g where k = 'a'), '^[23456789abcdefghjkmnpqrstuvwxyz]{10}$',
  'the code has ten characters without 0/o/1/i/l');
select results_eq($$select is_owner, members from my_groups()$$, $$values (true, 1)$$,
  'the creator is owner and the only member');
select throws_ok($$select create_group('   ')$$, '22023', null, 'an empty name is refused');
select throws_ok($$select create_group(repeat('x', 41))$$, '22023', null, 'a name over 40 characters is refused');

-- No direct table access ------------------------------------------------------------------------------
select throws_ok($$select * from groups$$, '42501', null, 'groups cannot be selected directly (codes stay hidden)');
select throws_ok($$select * from group_members$$, '42501', null, 'group_members cannot be selected directly');
select throws_ok($$insert into group_members (group_id, user_id) values ((select id from pg_temp.g where k = 'a'),
  '00000000-0000-0000-0000-000000000203')$$, '42501', null, 'members cannot be inserted directly');
select throws_ok($$select private.is_group_member((select id from pg_temp.g where k = 'a'))$$, '42501', null,
  'private helpers are not callable');

-- Join --------------------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000202');
select is((select id from join_group('zzzzzzzzzz')), null, 'an unknown code answers null and reveals nothing');
select is((select members from join_group(upper(' ' || (select code from pg_temp.g where k = 'a') || ' '))), 2,
  'joining with the code (any case, spaces around) adds the member');
select is((select members from join_group((select code from pg_temp.g where k = 'a'))), 2,
  'joining again changes nothing');
select results_eq($$select name, is_owner from my_groups()$$, $$values ('Mac Friends'::text, false)$$,
  'the new member sees the group, not as owner');

-- Paused member joins too (listed, but on no board)
select pg_temp.as_user('00000000-0000-0000-0000-000000000204');
select is((select members from join_group((select code from pg_temp.g where k = 'a'))), 3, 'a paused participant can join');

-- Visibility ------------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000203');
select is_empty($$select * from my_groups()$$, 'an outsider sees no group');
select is_empty($$select * from group_member_list()$$, 'an outsider sees no members');
select is_empty($$select * from group_boards(50)$$, 'an outsider sees no group board');

select pg_temp.as_user('00000000-0000-0000-0000-000000000202');
select results_eq($$select display_name, is_owner, is_me from group_member_list()$$,
  $$values ('Ann'::text, true, false), ('Ben'::text, false, true), ('Dan'::text, false, false)$$,
  'members see each other in join order, with owner and self marked');
select hasnt_column('public', 'group_member_list', 'user_id', 'sanity: group_member_list is a function, not a table');
select is((select count(*)::int from information_schema.routines r
            join information_schema.parameters p on p.specific_name = r.specific_name
           where r.routine_schema = 'public' and r.routine_name = 'group_member_list' and p.parameter_name = 'user_id'), 0,
  'group_member_list returns no auth user id');

-- Boards ----------------------------------------------------------------------------------------------
select results_eq(
  $$select display_name, rank, participants, value, is_me from group_boards(50) where period = '30D' and unit = 'tokens'$$,
  $$values ('Ben'::text, 1::bigint, 2::bigint, 2000::numeric, true), ('Ann'::text, 2::bigint, 2::bigint, 1000::numeric, false)$$,
  'the group board ranks only the group''s opted-in members (outsider and paused member absent)');
select results_eq(
  $$select display_name, rank from group_boards(50) where period = '30D' and unit = 'usd'$$,
  $$values ('Ann'::text, 1::bigint), ('Ben'::text, 2::bigint)$$,
  'the usd board ranks by the API-price value');
select is((select count(distinct (period, unit))::int from group_boards(50)), 12, 'twelve boards per group');
select results_eq(
  $$select display_name, rank, is_me from group_boards(1) where period = 'ALL' and unit = 'usd'$$,
  $$values ('Ann'::text, 1::bigint, false), ('Ben'::text, 2::bigint, true)$$,
  'outside the limit the own row is appended');

-- Owner rights ----------------------------------------------------------------------------------------
select throws_ok($$select rename_group((select id from pg_temp.g where k = 'a'), 'Mine')$$, 'PT403', null,
  'a member cannot rename');
select throws_ok($$select renew_group_code((select id from pg_temp.g where k = 'a'))$$, 'PT403', null,
  'a member cannot renew the code');
select throws_ok($$select delete_group((select id from pg_temp.g where k = 'a'))$$, 'PT403', null,
  'a member cannot delete the group');
select throws_ok($$select remove_group_member((select id from pg_temp.g where k = 'a'),
  (select member_id from group_member_list() where display_name = 'Dan'))$$, 'PT403', null, 'a member cannot remove members');

select pg_temp.as_user('00000000-0000-0000-0000-000000000203');
select throws_ok($$select rename_group((select id from pg_temp.g where k = 'a'), 'Mine')$$, 'PT403', null,
  'an outsider cannot rename');

select pg_temp.as_user('00000000-0000-0000-0000-000000000201');
select is((select name from rename_group((select id from pg_temp.g where k = 'a'), 'Claude Crew')), 'Claude Crew',
  'the owner renames');
insert into pg_temp.g select 'a-old', id, code from pg_temp.g where k = 'a';
update pg_temp.g set code = (select code from renew_group_code(id)) where k = 'a';
select isnt((select code from pg_temp.g where k = 'a'), (select code from pg_temp.g where k = 'a-old'),
  'renewing gives a new code');

select pg_temp.as_user('00000000-0000-0000-0000-000000000203');
select is((select id from join_group((select code from pg_temp.g where k = 'a-old'))), null,
  'the old link stops working');
select is((select members from join_group((select code from pg_temp.g where k = 'a'))), 4, 'the new link works');

select pg_temp.as_user('00000000-0000-0000-0000-000000000201');
select throws_ok($$select remove_group_member((select id from pg_temp.g where k = 'a'),
  (select member_id from group_member_list() where display_name = 'Ann'))$$, '22023', null,
  'the owner cannot remove themselves');
select throws_ok($$select remove_group_member((select id from pg_temp.g where k = 'a'), gen_random_uuid())$$, 'PT404', null,
  'removing an unknown member says so');
select ok(remove_group_member((select id from pg_temp.g where k = 'a'),
  (select member_id from group_member_list() where display_name = 'Cat')), 'the owner removes a member');
select pg_temp.as_user('00000000-0000-0000-0000-000000000203');
select is_empty($$select * from my_groups()$$, 'the removed member no longer sees the group');
select is_empty($$select * from group_boards(50)$$, '... nor its boards');

-- Leave -------------------------------------------------------------------------------------------------
select throws_ok($$select leave_group((select id from pg_temp.g where k = 'a'))$$, 'PT403', null,
  'a non-member cannot leave');
select pg_temp.as_user('00000000-0000-0000-0000-000000000201');
select ok(leave_group((select id from pg_temp.g where k = 'a')), 'the owner leaves');
select pg_temp.as_user('00000000-0000-0000-0000-000000000202');
select results_eq($$select is_owner, members from my_groups()$$, $$values (true, 2)$$,
  'ownership goes to the member who joined first');

-- Leaving the leaderboard hands groups over or deletes them --------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000201');
insert into pg_temp.g select 'solo', (r).id, (r).code from (select create_group('Solo') as r) x;
insert into pg_temp.g select 'b', (r).id, (r).code from (select create_group('Second') as r) x;
select pg_temp.as_user('00000000-0000-0000-0000-000000000203');
select is((select members from join_group((select code from pg_temp.g where k = 'b'))), 2, 'Cat joins the second group');
select pg_temp.as_user('00000000-0000-0000-0000-000000000201');
select ok(leave_leaderboard(), 'Ann leaves the leaderboard');
reset role;
select is((select count(*)::int from groups where id = (select id from pg_temp.g where k = 'solo')), 0,
  'a group without another member is deleted with its owner''s profile');
select is((select owner_id from groups where id = (select id from pg_temp.g where k = 'b')),
  '00000000-0000-0000-0000-000000000203'::uuid, 'a group with members goes to the next member');

-- Deleting the auth account does the same (profiles cascade from auth.users)
delete from auth.users where id = '00000000-0000-0000-0000-000000000203';
select is((select count(*)::int from groups where id = (select id from pg_temp.g where k = 'b')), 0,
  'deleting the last member''s account deletes the group');

-- Delete ------------------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000202');
select ok(delete_group((select id from pg_temp.g where k = 'a')), 'the owner deletes the group');
select is_empty($$select * from my_groups()$$, 'a deleted group is gone');

-- Limits ------------------------------------------------------------------------------------------------
select lives_ok($$select create_group('g' || n) from generate_series(1, 10) n$$, 'ten owned groups are allowed');
select throws_ok($$select create_group('g11')$$, 'PT409', null, 'the eleventh owned group is refused');

-- A full group: 100 members (written directly), the 101st is refused.
reset role;
insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
select ('00000000-0000-0000-0001-' || lpad(n::text, 12, '0'))::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'full-' || n || '@example.com', now(), now()
  from generate_series(1, 100) n;
insert into profiles (id, display_name)
select ('00000000-0000-0000-0001-' || lpad(n::text, 12, '0'))::uuid, 'Full ' || n from generate_series(1, 100) n;
insert into groups (id, name, owner_id, code)
values ('00000000-0000-0000-0002-000000000001', 'Full', '00000000-0000-0000-0001-000000000001', 'fffffffff2');
insert into group_members (group_id, user_id)
select '00000000-0000-0000-0002-000000000001', ('00000000-0000-0000-0001-' || lpad(n::text, 12, '0'))::uuid
  from generate_series(1, 100) n;
select pg_temp.as_user('00000000-0000-0000-0000-000000000204');
select throws_ok($$select join_group('fffffffff2')$$, 'PT409', null, 'a group of 100 is full');

-- Rate limit: every call counts, wrong codes included (positive control: the 30 before pass).
reset role;
delete from private.group_join_attempts;
select pg_temp.as_user('00000000-0000-0000-0000-000000000204');
select is((select count(*)::int from generate_series(1, 30) n, lateral join_group('wrongcode' || (n % 10)) j where j.id is null),
  30, 'thirty attempts per hour are answered');
select throws_ok($$select join_group('fffffffff2')$$, 'PT429', null, 'the thirty-first is rate limited, even with a valid code');

select * from finish();
rollback;
