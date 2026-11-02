-- All twelve boards (6 periods x 2 units) in one call, for the app's leaderboard window.
--
-- Returns, per board, the first p_limit places and, when the caller is a participant outside them, the
-- caller's own row as well (the app shows it below the list). `participants` is the size of the board, so
-- "#n of m" needs no second call. Same ranking as leaderboard() and my_rank(): fresh totals of opted-in
-- participants, tokens by input tokens, usd by the API-price value, ties share a rank.
--
-- Runs as the caller (security invoker), so RLS decides what is visible, exactly like leaderboard().
-- Nothing new is exposed: display name, GitHub username and the period totals are what leaderboard()
-- already returns to every participant. The app derives the avatar from the username; no avatar link is
-- read from the auth record.

create or replace function public.leaderboard_top(p_limit integer default 50)
returns table (
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
security invoker
set search_path = ''
as $$
    with board as (
        select t.period, u.unit, u.uo,
               case when u.unit = 'usd' then t.usd else t.tokens_input::numeric end as v,
               p.display_name, p.github_login, (p.id = (select auth.uid())) as me
          from public.totals t
          join public.profiles p on p.id = t.user_id
         cross join unnest(array['tokens', 'usd']) with ordinality as u (unit, uo)
         where p.opted_in_at is not null
           and public.lb_fresh(t.period, t.period_start, t.updated_at)
    ), ranked as (
        select b.*,
               rank() over (partition by b.period, b.unit order by b.v desc) as rnk,
               row_number() over (partition by b.period, b.unit order by b.v desc, b.display_name) as pos,
               count(*) over (partition by b.period, b.unit) as cnt
          from board b
    )
    select r.period, r.unit, r.rnk, r.cnt, r.display_name, r.github_login, r.v, r.me
      from ranked r
      join unnest(array['1D', '7D', '30D', 'YTD', '1Y', 'ALL']) with ordinality as o (period, po)
        on o.period = r.period
     where r.pos <= greatest(1, least(coalesce(p_limit, 50), 100)) or r.me
     order by o.po, r.uo, r.pos
$$;

revoke all on function public.leaderboard_top(integer) from public, anon;
grant execute on function public.leaderboard_top(integer) to authenticated;
