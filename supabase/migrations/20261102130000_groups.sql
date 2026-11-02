-- TokenMaccer groups: compare with friends through an invitation link.
--
-- A group is a filter on the leaderboard's participants: every member takes part in the global
-- leaderboard (decision 02.11.2026: always global + groups). Nothing about a participant becomes visible
-- that leaderboard() does not already show to every participant; what is new is *who is in which group*,
-- and that is visible only to the members of that group.
--
-- Data model
--   groups         one row per group: name, owner, invitation code.
--   group_members  one row per member; `id` is a handle the owner uses to remove a member, so no auth
--                  user id is ever shown to anyone.
--   private.group_join_attempts  join attempts per GitHub user id (else auth uid) and hour, for the rate
--                  limit on join_group(). No foreign key: leaving does not reset it.
--
-- Who may do what (all writes go through the security definer functions below)
--   anon           nothing.
--   authenticated  read the groups they belong to and their members (functions only); create, join, leave; the owner
--                  renames, renews the code, removes members and deletes the group.
--
-- Leaving the leaderboard (or deleting the account) removes every membership. Groups the leaver owned go to
-- the member who joined first; a group without another member is deleted.
--
-- Errors: join_group() answers an unknown code with null; P0002 no such member (HTTP 404), PT403 not the owner / not a member, PT409 a limit is
-- reached (message says which), PT429 too many join attempts (detail = seconds to wait), 22023 bad input,
-- 42501 not a participant of the leaderboard.

create table public.groups (
    id         uuid primary key default gen_random_uuid(),
    name       text not null check (char_length(btrim(name)) between 1 and 40 and name = btrim(name)),
    owner_id   uuid not null references public.profiles (id),
    code       text not null unique check (code ~ '^[23456789abcdefghjkmnpqrstuvwxyz]{10}$'),
    created_at timestamptz not null default now()
);

comment on table public.groups is 'Leaderboard groups. Visible only to their members; joined by invitation code.';

create table public.group_members (
    id        uuid primary key default gen_random_uuid(),
    group_id  uuid not null references public.groups (id) on delete cascade,
    user_id   uuid not null references public.profiles (id) on delete cascade,
    joined_at timestamptz not null default clock_timestamp(),  -- order of joining, also within one transaction
    unique (group_id, user_id)
);

comment on table public.group_members is 'Members of a group. id is the handle for removing a member; user ids are never returned.';

create index group_members_user_idx on public.group_members (user_id);
create index groups_owner_idx on public.groups (owner_id);

create table private.group_join_attempts (
    subject  text not null check (subject ~ '^(github|uid):.+$'),
    hour     timestamptz not null,
    attempts integer not null default 0,
    primary key (subject, hour)
);

comment on table private.group_join_attempts is
  'Join attempts per GitHub user id (else auth uid) and hour, for the join_group() rate limit; rows older than a day are deleted by join_group().';

alter table private.group_join_attempts enable row level security;
revoke all on private.group_join_attempts from public, anon, authenticated;

-- Row level security ---------------------------------------------------------------------------

alter table public.groups enable row level security;
alter table public.group_members enable row level security;

-- No table privileges at all: every read and write goes through the functions below, so neither the
-- invitation codes of other groups nor any auth user id can be selected directly. RLS stays on (without
-- policies it denies everything) in case a privilege is ever granted by mistake.
revoke all on public.groups from public, anon, authenticated;
revoke all on public.group_members from public, anon, authenticated;

-- Whether the caller is a member of the group (used inside the security definer functions).
create or replace function private.is_group_member(p_group uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.group_members m
         where m.group_id = p_group and m.user_id = (select auth.uid()))
$$;

revoke all on function private.is_group_member(uuid) from public, anon, authenticated;

-- Helpers --------------------------------------------------------------------------------------

-- The caller, who must take part in the leaderboard.
create or replace function private.group_caller()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_uid uuid := auth.uid();
begin
    if v_uid is null then
        raise exception 'not authenticated' using errcode = '28000';
    end if;
    if not exists (select 1 from public.profiles where id = v_uid) then
        raise exception 'join the leaderboard first' using errcode = '42501';
    end if;
    return v_uid;
end;
$$;

-- A fresh invitation code: 10 characters without 0/o/1/i/l (31^10 ≈ 8e14 codes).
create or replace function private.new_group_code()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
    c_alphabet constant text := '23456789abcdefghjkmnpqrstuvwxyz';
    v_bytes bytea;
    v_code  text;
begin
    loop
        v_bytes := extensions.gen_random_bytes(10);
        v_code := '';
        for i in 0..9 loop
            v_code := v_code || substr(c_alphabet, (get_byte(v_bytes, i) % 31) + 1, 1);
        end loop;
        exit when not exists (select 1 from public.groups where code = v_code);
    end loop;
    return v_code;
end;
$$;

create or replace function private.clean_group_name(p_name text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
    v text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
    if char_length(v) not between 1 and 40 then
        raise exception 'group name needs 1 to 40 characters' using errcode = '22023';
    end if;
    return v;
end;
$$;

-- The owner check for the owner-only functions.
create or replace function private.owned_group(p_group uuid)
returns public.groups
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_uid uuid := private.group_caller();
    v_row public.groups;
begin
    select * into v_row from public.groups where id = p_group;
    if v_row.id is null or not private.is_group_member(p_group) then
        raise exception 'not a member of this group' using errcode = 'PT403';
    end if;
    if v_row.owner_id <> v_uid then
        raise exception 'only the owner can do that' using errcode = 'PT403';
    end if;
    return v_row;
end;
$$;

-- Ownership moves to the member who joined first; without one the group is deleted.
create or replace function private.hand_over_groups(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_group uuid;
    v_next  uuid;
begin
    for v_group in select id from public.groups where owner_id = p_user loop
        select m.user_id into v_next
          from public.group_members m
         where m.group_id = v_group and m.user_id <> p_user
         order by m.joined_at, m.id
         limit 1;
        if v_next is null then
            delete from public.groups where id = v_group;
        else
            update public.groups set owner_id = v_next where id = v_group;
        end if;
    end loop;
end;
$$;

-- Leaving the leaderboard: before the profile goes, hand its groups over (memberships cascade).
create or replace function private.profiles_before_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.hand_over_groups(old.id);
    return old;
end;
$$;

create trigger profiles_hand_over_groups
    before delete on public.profiles
    for each row execute function private.profiles_before_delete();

-- One group as the app sees it.
create type public.group_info as (
    id       uuid,
    name     text,
    code     text,
    is_owner boolean,
    members  integer
);

create or replace function private.group_info(p_group uuid)
returns public.group_info
language sql
stable
security definer
set search_path = ''
as $$
    select g.id, g.name, g.code, g.owner_id = (select auth.uid()),
           (select count(*)::integer from public.group_members m where m.group_id = g.id)
      from public.groups g
     where g.id = p_group
$$;

-- Create, join, leave --------------------------------------------------------------------------

create or replace function public.create_group(p_name text)
returns public.group_info
language plpgsql
security definer
set search_path = ''
as $$
declare
    c_max_owned constant integer := 10;
    c_max_member constant integer := 20;
    v_uid  uuid := private.group_caller();
    v_name text := private.clean_group_name(p_name);
    v_id   uuid;
begin
    perform 1 from public.profiles where id = v_uid for update;  -- one create/join at a time per user
    if (select count(*) from public.groups where owner_id = v_uid) >= c_max_owned then
        raise exception 'you can own at most % groups', c_max_owned using errcode = 'PT409';
    end if;
    if (select count(*) from public.group_members where user_id = v_uid) >= c_max_member then
        raise exception 'you can be in at most % groups', c_max_member using errcode = 'PT409';
    end if;
    insert into public.groups (name, owner_id, code)
    values (v_name, v_uid, private.new_group_code())
    returning id into v_id;
    insert into public.group_members (group_id, user_id) values (v_id, v_uid);
    return private.group_info(v_id);
end;
$$;

-- Join by invitation code. Already a member: returns the group unchanged. Unknown code: returns null (all
-- fields null), not an error, because an error would roll back the attempt count. Every call counts towards
-- the rate limit (30 per hour), so codes cannot be tried out; a wrong code says nothing about other groups.
create or replace function public.join_group(p_code text)
returns public.group_info
language plpgsql
security definer
set search_path = ''
as $$
declare
    c_max_attempts constant integer := 30;
    c_max_members  constant integer := 100;
    c_max_member   constant integer := 20;
    v_uid     uuid := private.group_caller();
    v_code    text := lower(btrim(coalesce(p_code, '')));
    v_subject text;
    v_hour    timestamptz := date_trunc('hour', now());
    v_tries   integer;
    v_group   public.groups;
begin
    select coalesce(
               (select 'github:' || i.provider_id
                  from auth.identities i
                 where i.user_id = v_uid and i.provider = 'github'
                 order by i.last_sign_in_at desc nulls last, i.created_at desc
                 limit 1),
               'uid:' || v_uid::text)
      into v_subject;
    delete from private.group_join_attempts where hour < now() - interval '1 day';
    insert into private.group_join_attempts as a (subject, hour, attempts)
    values (v_subject, v_hour, 1)
    on conflict (subject, hour) do update set attempts = a.attempts + 1
    returning attempts into v_tries;
    if v_tries > c_max_attempts then
        raise exception 'too many join attempts' using
            errcode = 'PT429',
            detail = ceil(extract(epoch from (v_hour + interval '1 hour' - now())))::text;
    end if;

    select * into v_group from public.groups where code = v_code;
    if v_group.id is null then
        return null;
    end if;
    if private.is_group_member(v_group.id) then
        return private.group_info(v_group.id);
    end if;

    perform 1 from public.groups where id = v_group.id for update;  -- serialises the member count
    if (select count(*) from public.group_members where group_id = v_group.id) >= c_max_members then
        raise exception 'this group is full (% members)', c_max_members using errcode = 'PT409';
    end if;
    if (select count(*) from public.group_members where user_id = v_uid) >= c_max_member then
        raise exception 'you can be in at most % groups', c_max_member using errcode = 'PT409';
    end if;
    insert into public.group_members (group_id, user_id) values (v_group.id, v_uid);
    return private.group_info(v_group.id);
end;
$$;

-- Leave a group. The owner hands it to the member who joined first (or the group goes if alone).
create or replace function public.leave_group(p_group uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_uid   uuid := private.group_caller();
    v_owner uuid;
    v_next  uuid;
begin
    select owner_id into v_owner from public.groups where id = p_group for update;
    if v_owner is null or not private.is_group_member(p_group) then
        raise exception 'not a member of this group' using errcode = 'PT403';
    end if;
    if v_owner = v_uid then
        select m.user_id into v_next
          from public.group_members m
         where m.group_id = p_group and m.user_id <> v_uid
         order by m.joined_at, m.id
         limit 1;
        if v_next is null then
            delete from public.groups where id = p_group;
            return true;
        end if;
        update public.groups set owner_id = v_next where id = p_group;
    end if;
    delete from public.group_members where group_id = p_group and user_id = v_uid;
    return true;
end;
$$;

-- Owner only -----------------------------------------------------------------------------------

create or replace function public.rename_group(p_group uuid, p_name text)
returns public.group_info
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_name text := private.clean_group_name(p_name);
begin
    perform private.owned_group(p_group);
    update public.groups set name = v_name where id = p_group;
    return private.group_info(p_group);
end;
$$;

-- A new invitation code; the old link stops working at once.
create or replace function public.renew_group_code(p_group uuid)
returns public.group_info
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.owned_group(p_group);
    update public.groups set code = private.new_group_code() where id = p_group;
    return private.group_info(p_group);
end;
$$;

-- Removes a member by the handle group_member_list() returns. The owner cannot remove themselves (leave_group).
-- The removed member can come back with the link until the owner renews it.
create or replace function public.remove_group_member(p_group uuid, p_member uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_group public.groups := private.owned_group(p_group);
    v_user  uuid;
begin
    select user_id into v_user from public.group_members where id = p_member and group_id = p_group;
    if v_user is null then
        raise exception 'no such member' using errcode = 'P0002';
    end if;
    if v_user = v_group.owner_id then
        raise exception 'the owner cannot be removed, leave the group instead' using errcode = '22023';
    end if;
    delete from public.group_members where id = p_member;
    return true;
end;
$$;

create or replace function public.delete_group(p_group uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform private.owned_group(p_group);
    delete from public.groups where id = p_group;
    return true;
end;
$$;

-- Reading --------------------------------------------------------------------------------------

-- The caller's groups, oldest membership first.
create or replace function public.my_groups()
returns setof public.group_info
language sql
stable
security definer
set search_path = ''
as $$
    select (private.group_info(g.id)).*
      from public.groups g
      join public.group_members m on m.group_id = g.id and m.user_id = (select auth.uid())
     order by m.joined_at, g.id
$$;

-- Members of the caller's groups: handle, name, username, owner flag. Paused participants are listed too
-- (the owner may want to remove them), but appear on no board. Display name and GitHub username are what
-- leaderboard() already shows of every participant; a paused member's name is new only to their own groups.
create or replace function public.group_member_list()
returns table (
    group_id     uuid,
    member_id    uuid,
    display_name text,
    github_login text,
    is_owner     boolean,
    is_me        boolean,
    joined_at    timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select m.group_id, m.id, p.display_name, p.github_login, g.owner_id = m.user_id,
           m.user_id = (select auth.uid()), m.joined_at
      from public.group_members m
      join public.groups g on g.id = m.group_id
      join public.profiles p on p.id = m.user_id
     where private.is_group_member(m.group_id)
     order by m.group_id, m.joined_at, m.id
$$;

-- The twelve boards of every group the caller is in, ranked among that group's members exactly like
-- leaderboard_top() ranks everyone: fresh totals of opted-in participants, ties share a rank, first
-- p_limit places plus the caller's own row. Security definer (the tables have no privileges); it reads only
-- groups the caller belongs to, and only what leaderboard() shows of every participant.
create or replace function public.group_boards(p_limit integer default 50)
returns table (
    group_id      uuid,
    period        text,
    unit          text,
    rank          bigint,
    participants  bigint,
    display_name  text,
    github_login  text,
    value         numeric,
    is_me         boolean
)
language sql
stable
security definer
set search_path = ''
as $$
    with mine as (
        select m.group_id from public.group_members m where m.user_id = (select auth.uid())
    ), board as (
        select gm.group_id, t.period, u.unit, u.uo,
               case when u.unit = 'usd' then t.usd else t.tokens_input::numeric end as v,
               p.display_name, p.github_login, (p.id = (select auth.uid())) as me
          from mine
          join public.group_members gm on gm.group_id = mine.group_id
          join public.profiles p on p.id = gm.user_id
          join public.totals t on t.user_id = p.id
         cross join unnest(array['tokens', 'usd']) with ordinality as u (unit, uo)
         where p.opted_in_at is not null
           and public.lb_fresh(t.period, t.period_start, t.updated_at)
    ), ranked as (
        select b.*,
               rank() over (partition by b.group_id, b.period, b.unit order by b.v desc) as rnk,
               row_number() over (partition by b.group_id, b.period, b.unit order by b.v desc, b.display_name) as pos,
               count(*) over (partition by b.group_id, b.period, b.unit) as cnt
          from board b
    )
    select r.group_id, r.period, r.unit, r.rnk, r.cnt, r.display_name, r.github_login, r.v, r.me
      from ranked r
      join unnest(array['1D', '7D', '30D', 'YTD', '1Y', 'ALL']) with ordinality as o (period, po)
        on o.period = r.period
     where r.pos <= greatest(1, least(coalesce(p_limit, 50), 100)) or r.me
     order by r.group_id, o.po, r.uo, r.pos
$$;

-- Function privileges: nothing for anon; the private helpers are not callable through the API (the
-- private schema is not exposed either). They run inside the security definer functions as their owner.
revoke all on function private.group_caller() from public, anon, authenticated;
revoke all on function private.new_group_code() from public, anon, authenticated;
revoke all on function private.clean_group_name(text) from public, anon, authenticated;
revoke all on function private.owned_group(uuid) from public, anon, authenticated;
revoke all on function private.hand_over_groups(uuid) from public, anon, authenticated;
revoke all on function private.profiles_before_delete() from public, anon, authenticated;
revoke all on function private.group_info(uuid) from public, anon, authenticated;

revoke all on function public.create_group(text) from public, anon;
revoke all on function public.join_group(text) from public, anon;
revoke all on function public.leave_group(uuid) from public, anon;
revoke all on function public.rename_group(uuid, text) from public, anon;
revoke all on function public.renew_group_code(uuid) from public, anon;
revoke all on function public.remove_group_member(uuid, uuid) from public, anon;
revoke all on function public.delete_group(uuid) from public, anon;
revoke all on function public.my_groups() from public, anon;
revoke all on function public.group_member_list() from public, anon;
revoke all on function public.group_boards(integer) from public, anon;

grant execute on function public.create_group(text) to authenticated;
grant execute on function public.join_group(text) to authenticated;
grant execute on function public.leave_group(uuid) to authenticated;
grant execute on function public.rename_group(uuid, text) to authenticated;
grant execute on function public.renew_group_code(uuid) to authenticated;
grant execute on function public.remove_group_member(uuid, uuid) to authenticated;
grant execute on function public.delete_group(uuid) to authenticated;
grant execute on function public.my_groups() to authenticated;
grant execute on function public.group_member_list() to authenticated;
grant execute on function public.group_boards(integer) to authenticated;
