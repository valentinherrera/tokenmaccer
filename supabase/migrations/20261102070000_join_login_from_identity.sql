-- join_leaderboard: take the GitHub login from auth.identities, not from user metadata.
--
-- auth.users.raw_user_meta_data is writable by the signed-in user (PUT /auth/v1/user with `data`),
-- so a GitHub account could set someone else's login there before joining and appear under a
-- foreign GitHub name. auth.identities.identity_data is written only by the auth server from the
-- provider's answer at sign-in; the client cannot change it. The GitHub requirement is checked
-- against the same row: only an account with a GitHub identity may join.

create or replace function public.join_leaderboard(p_display_name text)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_uid      uuid := auth.uid();
    v_identity jsonb;
    v_login    text;
    v_name     text := btrim(coalesce(p_display_name, ''));
    v_row      public.profiles;
begin
    if v_uid is null then
        raise exception 'not authenticated' using errcode = '28000';
    end if;
    select i.identity_data into v_identity
      from auth.identities i
     where i.user_id = v_uid and i.provider = 'github'
     order by i.last_sign_in_at desc nulls last, i.created_at desc
     limit 1;
    if not found then
        raise exception 'GitHub sign-in required' using errcode = '42501';
    end if;
    v_login := nullif(btrim(coalesce(v_identity ->> 'user_name', v_identity ->> 'preferred_username')), '');
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

comment on function public.join_leaderboard(text) is
  'Opt in or rename. The GitHub login comes from auth.identities (provider github), never from user metadata or the client.';

-- create or replace keeps the existing grants; repeated here so the function is closed even if an
-- earlier state differed.
revoke all on function public.join_leaderboard(text) from public, anon;
grant execute on function public.join_leaderboard(text) to authenticated;

-- Profiles that joined under the old function: overwrite the login with the one from the identity.
update public.profiles p
   set github_login = (
       select nullif(btrim(coalesce(i.identity_data ->> 'user_name', i.identity_data ->> 'preferred_username')), '')
         from auth.identities i
        where i.user_id = p.id and i.provider = 'github'
        order by i.last_sign_in_at desc nulls last, i.created_at desc
        limit 1);
