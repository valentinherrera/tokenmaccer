-- Reports every 10 minutes while the reporter uses Claude Code (Valentin 03.11.2026): the collector now reports
-- at most every 10 minutes when its totals changed, otherwise every 30 as before. The server refuses a second
-- report within 8 minutes (was 25), a little below the client's 10 so clock drift never causes a 429.
-- apply_report is otherwise unchanged from 20261102090000_report_limit_and_starts.sql.

-- Validates and stores one report: all six periods at once.
--   payload: {"periods": {"1D": {"input": n, "output": n, "usd": x, "start": "YYYY-MM-DD"}, ...}}
-- Errors use SQLSTATE 22023 (implausible input), 42501 (not a participant), P0001 with
-- message 'rate limited' (too soon after the last report; detail = seconds to wait).
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
    c_min_interval   constant interval := interval '8 minutes';
    c_keep_limits    constant interval := interval '1 hour';
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
    v_day     date;
    v_days    numeric;
    v_vals    jsonb := '{}'::jsonb;
    v_key     text;
    v_pair    text[];
    v_ok      boolean;
    v_subject text;
    v_claimed boolean;
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

    -- The windows all end on the reporter's local day, the start of 1D: 7D starts 6 days, 30D 29 days
    -- and 1Y 364 days earlier, YTD on 1 January of that year, ALL not after it (the collector computes
    -- them so). Anything else is not a report of the TokenMaccer collector.
    v_day := (v_vals -> '1D' ->> 'start')::date;
    if (v_vals -> '7D' ->> 'start')::date <> v_day - 6
       or (v_vals -> '30D' ->> 'start')::date <> v_day - 29
       or (v_vals -> '1Y' ->> 'start')::date <> v_day - 364
       or (v_vals -> 'YTD' ->> 'start')::date <> date_trunc('year', v_day)::date
       or (v_vals -> 'ALL' ->> 'start')::date > v_day then
        raise exception 'inconsistent period starts' using errcode = '22023';
    end if;

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

    -- Rate limit, atomically: claims the slot only if the last accepted report is old enough. The slot
    -- belongs to the GitHub user, so leaving and joining again (or a new auth account) does not reset it.
    delete from private.report_limits where last_report_at < now() - c_keep_limits;
    select coalesce(
               (select 'github:' || i.provider_id
                  from auth.identities i
                 where i.user_id = p_user and i.provider = 'github'
                 order by i.last_sign_in_at desc nulls last, i.created_at desc
                 limit 1),
               'uid:' || p_user::text)
      into v_subject;
    insert into private.report_limits as l (subject, last_report_at)
    values (v_subject, now())
    on conflict (subject) do update
        set last_report_at = excluded.last_report_at
        where l.last_report_at <= now() - c_min_interval
    returning true into v_claimed;
    if v_claimed is null then
        raise exception 'rate limited' using
            detail = (select greatest(1, ceil(extract(epoch from (l.last_report_at + c_min_interval - now()))))::text
                        from private.report_limits l where l.subject = v_subject);
    end if;

    update public.profiles set last_report_at = now() where id = p_user;

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

comment on function public.apply_report(uuid, jsonb) is
  'Validates and stores one report (service_role only). Rate limit per GitHub user in private.report_limits.';

revoke all on function public.apply_report(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.apply_report(uuid, jsonb) to service_role;
