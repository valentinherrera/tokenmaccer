-- TokenMaccer leaderboard: opt-in participants and their per-period totals.
--
-- Data model
--   profiles  one row per participant (join creates it, leave deletes it); visible to others only
--             while opted_in_at is set (null = paused).
--   totals    one row per participant and period (1D, 7D, 30D, YTD, 1Y, ALL), replaced on every report.
--
-- Who may do what
--   anon           nothing.
--   authenticated  read profiles and totals of participants (RLS), change their own display name,
--                  join, leave, read the leaderboard and their own rank (RPCs below).
--   service_role   apply_report(), called only by the `report` Edge Function after it verified the
--                  caller's JWT. Totals are never written directly by a client, so the plausibility
--                  checks in apply_report() cannot be skipped.
--
-- Nothing is reported but sums per period: no projects, models, prompts or file names.

create table public.profiles (
    id             uuid primary key references auth.users (id) on delete cascade,
    github_login   text,
    display_name   text not null check (char_length(btrim(display_name)) between 1 and 32),
    opted_in_at    timestamptz default now(),  -- null = paused: kept, but hidden from everyone else
    last_report_at timestamptz
);

comment on table public.profiles is 'Leaderboard participants. Visible to others only while opted_in_at is set; leave deletes the row.';

create table public.totals (
    user_id       uuid not null references public.profiles (id) on delete cascade,
    period        text not null check (period in ('1D', '7D', '30D', 'YTD', '1Y', 'ALL')),
    tokens_input  bigint not null check (tokens_input >= 0),
    tokens_output bigint not null check (tokens_output >= 0),
    usd           numeric(14, 2) not null check (usd >= 0),
    period_start  date not null,
    updated_at    timestamptz not null default now(),
    primary key (user_id, period)
);

comment on table public.totals is 'Per-period sums of a participant, written only through apply_report().';

create index totals_period_input_idx on public.totals (period, tokens_input desc);
create index totals_period_usd_idx on public.totals (period, usd desc);

-- Row level security ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.totals enable row level security;

revoke all on public.profiles from anon, authenticated;
revoke all on public.totals from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name) on public.profiles to authenticated;
grant select on public.totals to authenticated;

-- Readable: participants who opted in, and always the caller's own row.
create policy profiles_read_participants on public.profiles
    for select to authenticated
    using (opted_in_at is not null or id = (select auth.uid()));

-- Writable: only the caller's own row (and only the display_name column, see the grant above).
create policy profiles_update_own on public.profiles
    for update to authenticated
    using (id = (select auth.uid()))
    with check (id = (select auth.uid()));

create policy totals_read_participants on public.totals
    for select to authenticated
    using (
        exists (
            select 1 from public.profiles p
            where p.id = totals.user_id and (p.opted_in_at is not null or p.id = (select auth.uid()))
        )
    );

-- Helpers --------------------------------------------------------------------------------------

-- Rows that count for the ranking: recently reported, and for 1D from today or yesterday (UTC),
-- so a participant who stopped reporting does not keep yesterday's number on today's board.
create or replace function public.lb_fresh(p_period text, p_start date, p_updated timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
    select p_updated >= now() - interval '3 days'
       and (p_period <> '1D' or p_start >= (now() at time zone 'utc')::date - 1)
$$;

-- Join, rename, leave --------------------------------------------------------------------------

-- Opt in (or change the display name). The GitHub login is taken from the auth record, never from
-- the client. Only accounts that signed in with GitHub may join.
create or replace function public.join_leaderboard(p_display_name text)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_uid   uuid := auth.uid();
    v_user  auth.users;
    v_login text;
    v_name  text := btrim(coalesce(p_display_name, ''));
    v_row   public.profiles;
begin
    if v_uid is null then
        raise exception 'not authenticated' using errcode = '28000';
    end if;
    select * into v_user from auth.users where id = v_uid;
    if v_user.id is null then
        raise exception 'unknown user' using errcode = '28000';
    end if;
    if not coalesce(v_user.raw_app_meta_data -> 'providers' ? 'github', false)
       and coalesce(v_user.raw_app_meta_data ->> 'provider', '') <> 'github' then
        raise exception 'GitHub sign-in required' using errcode = '42501';
    end if;
    v_login := nullif(coalesce(v_user.raw_user_meta_data ->> 'user_name',
                               v_user.raw_user_meta_data ->> 'preferred_username'), '');
    if v_name = '' then
        v_name := coalesce(v_login, 'anonymous');
    end if;
    if char_length(v_name) > 32 then
        raise exception 'display name longer than 32 characters' using errcode = '22023';
    end if;

    insert into public.profiles (id, github_login, display_name)
    values (v_uid, v_login, v_name)
    on conflict (id) do update
        set display_name = excluded.display_name,
            github_login = excluded.github_login,
            opted_in_at  = coalesce(public.profiles.opted_in_at, now())  -- rejoining resumes a pause
    returning * into v_row;
    return v_row;
end;
$$;

-- Opt out: deletes the profile and, through the foreign key, every total. The auth account itself
-- is removed by the `delete-account` Edge Function when the app asks for it.
create or replace function public.leave_leaderboard()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_uid uuid := auth.uid();
begin
    if v_uid is null then
        raise exception 'not authenticated' using errcode = '28000';
    end if;
    delete from public.totals where user_id = v_uid;
    delete from public.profiles where id = v_uid;
    return true;
end;
$$;

-- Report (service_role only) -------------------------------------------------------------------

-- Validates and stores one report: all six periods at once.
--   payload: {"periods": {"1D": {"input": n, "output": n, "usd": x, "start": "YYYY-MM-DD"}, ...}}
-- Errors use SQLSTATE 22023 (implausible input), 42501 (not a participant), P0001 with
-- message 'rate limited' (too soon after the last report).
create or replace function public.apply_report(p_user uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    -- Generous ceilings per day: about ten times the heaviest real day measured (2.0e9 input
    -- tokens on 15.10.2026, one machine), so real heavy users are never rejected.
    c_input_per_day  constant numeric := 20000000000;  -- 2e10
    c_output_per_day constant numeric := 1000000000;   -- 1e9
    c_usd_per_day    constant numeric := 50000;
    c_min_interval   constant interval := interval '25 minutes';
    c_tol_tokens     constant numeric := 2;     -- rounding of fractional hour shares
    c_tol_usd        constant numeric := 0.02;  -- rounding to cents
    c_earliest       constant date := date '2023-01-01';

    v_today   date := (now() at time zone 'utc')::date;
    v_periods text[] := array['1D', '7D', '30D', 'YTD', '1Y', 'ALL'];
    v_p       text;
    v_e       jsonb;
    v_in      numeric;
    v_out     numeric;
    v_usd     numeric;
    v_start   date;
    v_days    numeric;
    v_vals    jsonb := '{}'::jsonb;
    v_key     text;
    v_pair    text[];
    v_ok      boolean;
begin
    if p_user is null then
        raise exception 'no user' using errcode = '22023';
    end if;
    if not exists (select 1 from public.profiles where id = p_user) then
        raise exception 'not a participant' using errcode = '42501';
    end if;
    if jsonb_typeof(p_payload -> 'periods') is distinct from 'object' then
        raise exception 'periods missing' using errcode = '22023';
    end if;
    for v_key in select jsonb_object_keys(p_payload -> 'periods') loop
        if not v_key = any (v_periods) then
            raise exception 'unknown period %', v_key using errcode = '22023';
        end if;
    end loop;

    foreach v_p in array v_periods loop
        v_e := p_payload -> 'periods' -> v_p;
        if v_e is null or jsonb_typeof(v_e) <> 'object' then
            raise exception 'period % missing', v_p using errcode = '22023';
        end if;
        if jsonb_typeof(v_e -> 'input') <> 'number' or jsonb_typeof(v_e -> 'output') <> 'number'
           or jsonb_typeof(v_e -> 'usd') <> 'number' or jsonb_typeof(v_e -> 'start') <> 'string' then
            raise exception 'period %: input, output, usd must be numbers and start a date', v_p
                using errcode = '22023';
        end if;
        v_in := (v_e ->> 'input')::numeric;
        v_out := (v_e ->> 'output')::numeric;
        v_usd := (v_e ->> 'usd')::numeric;
        if v_in < 0 or v_out < 0 or v_usd < 0 then
            raise exception 'period %: negative value', v_p using errcode = '22023';
        end if;
        if v_in <> trunc(v_in) or v_out <> trunc(v_out) then
            raise exception 'period %: token counts must be whole numbers', v_p using errcode = '22023';
        end if;
        begin
            v_start := (v_e ->> 'start')::date;
        exception when others then
            raise exception 'period %: start is not a date', v_p using errcode = '22023';
        end;
        if v_start < c_earliest or v_start > v_today + 1 then
            raise exception 'period %: start % out of range', v_p, v_start using errcode = '22023';
        end if;

        -- Days the period can span at most (one day of slack for time zones).
        v_days := case v_p
            when '1D'  then 1
            when '7D'  then 7
            when '30D' then 30
            when 'YTD' then (v_today - date_trunc('year', v_today)::date) + 2
            when '1Y'  then 366
            else greatest((v_today - v_start) + 2, 1)
        end;
        if v_in > c_input_per_day * v_days or v_out > c_output_per_day * v_days
           or v_usd > c_usd_per_day * v_days then
            raise exception 'period %: above the daily ceiling', v_p using errcode = '22023';
        end if;

        v_vals := v_vals || jsonb_build_object(v_p, jsonb_build_object(
            'input', v_in, 'output', v_out, 'usd', round(v_usd, 2), 'start', v_start));
    end loop;

    -- A shorter window ending today can never exceed a longer one that contains it.
    -- YTD is only compared with 1D and ALL: in January it is shorter than 7D/30D, and on
    -- 31 December of a leap year it is one day longer than 1Y.
    foreach v_key in array array['1D<7D', '7D<30D', '30D<1Y', '1Y<ALL', '1D<YTD', 'YTD<ALL'] loop
        v_pair := string_to_array(v_key, '<');
        v_ok := (v_vals -> v_pair[1] ->> 'input')::numeric  <= (v_vals -> v_pair[2] ->> 'input')::numeric + c_tol_tokens
            and (v_vals -> v_pair[1] ->> 'output')::numeric <= (v_vals -> v_pair[2] ->> 'output')::numeric + c_tol_tokens
            and (v_vals -> v_pair[1] ->> 'usd')::numeric    <= (v_vals -> v_pair[2] ->> 'usd')::numeric + c_tol_usd;
        if not v_ok then
            raise exception 'inconsistent periods: % exceeds %', v_pair[1], v_pair[2] using errcode = '22023';
        end if;
    end loop;

    -- Rate limit, atomically: claims the slot only if the last report is old enough.
    update public.profiles
       set last_report_at = now()
     where id = p_user
       and (last_report_at is null or last_report_at <= now() - c_min_interval);
    if not found then
        raise exception 'rate limited' using
            detail = (select ceil(extract(epoch from (last_report_at + c_min_interval - now())))::text
                        from public.profiles where id = p_user);
    end if;

    insert into public.totals (user_id, period, tokens_input, tokens_output, usd, period_start, updated_at)
    select p_user, k, (v ->> 'input')::bigint, (v ->> 'output')::bigint, (v ->> 'usd')::numeric,
           (v ->> 'start')::date, now()
      from jsonb_each(v_vals) as e (k, v)
    on conflict (user_id, period) do update
        set tokens_input  = excluded.tokens_input,
            tokens_output = excluded.tokens_output,
            usd           = excluded.usd,
            period_start  = excluded.period_start,
            updated_at    = excluded.updated_at;

    return jsonb_build_object('stored', 6, 'next_report_after', now() + c_min_interval);
end;
$$;

-- Ranking --------------------------------------------------------------------------------------

-- unit 'tokens' ranks by input tokens (the widget's headline number), 'usd' by the API-price
-- equivalent. Ties share a rank. Runs as the caller, so RLS decides what is visible.
create or replace function public.leaderboard(p_period text, p_unit text, p_limit integer default 50)
returns table (
    rank          bigint,
    display_name  text,
    github_login  text,
    tokens_input  bigint,
    tokens_output bigint,
    usd           numeric,
    is_me         boolean
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
begin
    if p_period is null or p_period not in ('1D', '7D', '30D', 'YTD', '1Y', 'ALL') then
        raise exception 'unknown period %', p_period using errcode = '22023';
    end if;
    if p_unit is null or p_unit not in ('tokens', 'usd') then
        raise exception 'unit must be tokens or usd' using errcode = '22023';
    end if;
    return query
    select r.rnk, r.display_name, r.github_login, r.tokens_input, r.tokens_output, r.usd, r.is_me
      from (
        select rank() over (order by case when p_unit = 'usd' then t.usd else t.tokens_input end desc) as rnk,
               p.display_name, p.github_login, t.tokens_input, t.tokens_output, t.usd,
               (p.id = auth.uid()) as is_me
          from public.totals t
          join public.profiles p on p.id = t.user_id
         where t.period = p_period
           and p.opted_in_at is not null
           and public.lb_fresh(t.period, t.period_start, t.updated_at)
      ) r
     order by r.rnk, r.display_name
     limit greatest(1, least(coalesce(p_limit, 50), 100));
end;
$$;

-- The caller's place: "#rank of participants". rank is null when the caller has no fresh row.
create or replace function public.my_rank(p_period text, p_unit text)
returns table (rank bigint, participants bigint, value numeric)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
begin
    if p_period is null or p_period not in ('1D', '7D', '30D', 'YTD', '1Y', 'ALL') then
        raise exception 'unknown period %', p_period using errcode = '22023';
    end if;
    if p_unit is null or p_unit not in ('tokens', 'usd') then
        raise exception 'unit must be tokens or usd' using errcode = '22023';
    end if;
    return query
    with board as (
        select t.user_id,
               case when p_unit = 'usd' then t.usd else t.tokens_input::numeric end as v
          from public.totals t
          join public.profiles p on p.id = t.user_id
         where t.period = p_period
           and p.opted_in_at is not null
           and public.lb_fresh(t.period, t.period_start, t.updated_at)
    ), ranked as (
        select user_id, v, rank() over (order by v desc) as rnk from board
    )
    select (select rnk from ranked where user_id = auth.uid()),
           (select count(*) from board),
           (select v from ranked where user_id = auth.uid());
end;
$$;

-- All twelve places of the caller in one call (6 periods x 2 units), for the app's helper.
create or replace function public.my_ranks()
returns table (period text, unit text, rank bigint, participants bigint, value numeric)
language sql
stable
security invoker
set search_path = ''
as $$
    select p.period, u.unit, r.rank, r.participants, r.value
      from unnest(array['1D', '7D', '30D', 'YTD', '1Y', 'ALL']) with ordinality as p (period, po)
     cross join unnest(array['tokens', 'usd']) with ordinality as u (unit, uo)
     cross join lateral public.my_rank(p.period, u.unit) as r
     order by p.po, u.uo
$$;

-- Function privileges: nothing for anon, apply_report for service_role only.
revoke all on function public.lb_fresh(text, date, timestamptz) from public, anon;
revoke all on function public.join_leaderboard(text) from public, anon;
revoke all on function public.leave_leaderboard() from public, anon;
revoke all on function public.apply_report(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.leaderboard(text, text, integer) from public, anon;
revoke all on function public.my_rank(text, text) from public, anon;
revoke all on function public.my_ranks() from public, anon;

grant execute on function public.lb_fresh(text, date, timestamptz) to authenticated;
grant execute on function public.join_leaderboard(text) to authenticated;
grant execute on function public.leave_leaderboard() to authenticated;
grant execute on function public.leaderboard(text, text, integer) to authenticated;
grant execute on function public.my_rank(text, text) to authenticated;
grant execute on function public.my_ranks() to authenticated;
grant execute on function public.apply_report(uuid, jsonb) to service_role;
