#!/usr/bin/env python3
"""End-to-end smoke test of the leaderboard backend over HTTP (local stack or hosted project).

Creates three synthetic users (test-<n>-<run>@example.com) through the admin API, lets them join,
report, read ranks, hit the plausibility and rate limits, leave and delete their account, and
deletes every user it created at the end, also on failure. Prints nothing secret.

join_leaderboard reads the GitHub login from auth.identities, which no HTTP API lets anyone write
(the admin API creates email identities only). Users 1 and 2 therefore get a synthetic GitHub
identity through psql in the local database container named by SB_DB_CONTAINER; user 3 gets none
and must be refused. Against the hosted project, test joining with a real GitHub sign-in instead.

    SB_URL=... SB_ANON=... SB_SERVICE=... SB_DB_CONTAINER=supabase_db_tokenmaccer \
        python3 -I supabase/tests/smoke_leaderboard.py

SB_SERVICE is read from the environment only and never printed.
"""

import datetime as dt
import json
import os
import secrets
import subprocess
import sys
import urllib.error
import urllib.request

URL = os.environ['SB_URL'].rstrip('/')
ANON = os.environ['SB_ANON']
SERVICE = os.environ['SB_SERVICE']
DB_CONTAINER = os.environ.get('SB_DB_CONTAINER', '')
RUN = secrets.token_hex(3)
CHECKS = []


def call(method, path, key, token=None, body=None):
    headers = {'apikey': key, 'Authorization': f'Bearer {token or key}', 'Content-Type': 'application/json'}
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(URL + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None), dict(r.headers)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = raw.decode(errors='replace')[:200]
        return e.code, parsed, dict(e.headers)


def add_github_identity(uid, login, provider_id):
    """Insert a GitHub identity row as the auth server would at sign-in (local stack only)."""
    sql = (
        'insert into auth.identities '
        '(provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at) '
        f"values ('{provider_id}', '{uid}', jsonb_build_object('sub', '{provider_id}', 'user_name', '{login}', "
        f"'preferred_username', '{login}'), 'github', now(), now(), now())"
    )
    r = subprocess.run(
        ['docker', 'exec', DB_CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-qc', sql],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    return r.returncode == 0


def check(name, cond, info=''):
    CHECKS.append((name, bool(cond)))
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  [{info}]'))


def report(scale, usd):
    today = dt.datetime.now(dt.timezone.utc).date()

    def p(days, inp, start):
        return {
            'input': inp * scale,
            'output': inp * scale // 100,
            'usd': round(days * usd, 2),
            'start': start.isoformat(),
        }

    return {
        'periods': {
            '1D': p(1, 1000, today),
            '7D': p(7, 7000, today - dt.timedelta(days=6)),
            '30D': p(30, 30000, today - dt.timedelta(days=29)),
            'YTD': p(50, 50000, dt.date(today.year, 1, 1)),
            '1Y': p(100, 100000, today - dt.timedelta(days=364)),
            'ALL': p(200, 200000, today - dt.timedelta(days=500)),
        }
    }


def main():
    if not DB_CONTAINER:
        print('SB_DB_CONTAINER not set: GitHub identities cannot be created over HTTP, nothing run')
        return 2
    created = []
    try:
        users = []
        for n in range(1, 4):
            email = f'test-{n}-{RUN}@example.com'
            password = secrets.token_urlsafe(18)
            st, body, _ = call(
                'POST',
                '/auth/v1/admin/users',
                SERVICE,
                body={
                    'email': email,
                    'password': password,
                    'email_confirm': True,
                    'app_metadata': {'provider': 'github', 'providers': ['github']},
                    'user_metadata': {},
                },
            )
            check(f'admin creates synthetic user {n}', st == 200 and body and body.get('id'), st)
            created.append(body['id'])
            if n < 3:
                check(
                    f'user {n} gets a synthetic GitHub identity',
                    add_github_identity(body['id'], f'test-{n}-{RUN}', f'{RUN}{n}'),
                )
            st, tok, _ = call(
                'POST', '/auth/v1/token?grant_type=password', ANON, body={'email': email, 'password': password}
            )
            check(f'user {n} signs in', st == 200 and tok and tok.get('access_token'), st)
            users.append(tok['access_token'])
        a, b, c = users

        st, body, _ = call('POST', '/rest/v1/profiles?select=id', ANON, body={'display_name': 'x'})
        check('anon cannot write profiles', st in (401, 403), st)
        st, body, _ = call('GET', '/rest/v1/totals?select=*', ANON)
        check('anon cannot read totals', st in (401, 403), st)

        st, body, _ = call('POST', '/functions/v1/report', ANON, a, report(1, 5))
        check('report before joining is refused (403)', st == 403, (st, body))

        # User 1 writes user 2's login into the own user metadata, as any signed-in user may.
        st, body, _ = call(
            'PUT',
            '/auth/v1/user',
            ANON,
            a,
            {'data': {'user_name': f'test-2-{RUN}', 'preferred_username': f'test-2-{RUN}'}},
        )
        check(
            'user 1 can change the own user metadata (the forgery path)',
            st == 200 and (body or {}).get('user_metadata', {}).get('user_name') == f'test-2-{RUN}',
            (st, body),
        )

        for tok, name in ((a, 'Alpha'), (b, '')):
            st, body, _ = call('POST', '/rest/v1/rpc/join_leaderboard', ANON, tok, {'p_display_name': name})
            check(f'join as {name or "login"}', st == 200, (st, body))
        st, body, _ = call('GET', f'/rest/v1/profiles?select=github_login&id=eq.{created[0]}', SERVICE)
        check(
            'forged metadata is ignored: user 1 keeps the own GitHub login',
            st == 200 and body == [{'github_login': f'test-1-{RUN}'}],
            body,
        )
        st, body, _ = call('POST', '/rest/v1/rpc/join_leaderboard', ANON, c, {'p_display_name': 'Gamma'})
        check('an account without a GitHub identity cannot join (403)', st == 403, (st, body))

        st, body, _ = call(
            'POST',
            '/rest/v1/totals',
            ANON,
            a,
            {
                'user_id': created[1],
                'period': '1D',
                'tokens_input': 1,
                'tokens_output': 1,
                'usd': 1,
                'period_start': dt.date.today().isoformat(),
            },
        )
        check("writing someone else's totals directly fails", st in (401, 403), st)
        st, body, _ = call(
            'POST', '/rest/v1/rpc/apply_report', ANON, a, {'p_user': created[0], 'p_payload': report(1, 5)}
        )
        check('apply_report is closed to clients', st in (401, 403, 404), st)

        bad = report(1, 5)
        bad['periods']['1D']['input'] = 10**9
        st, body, _ = call('POST', '/functions/v1/report', ANON, a, bad)
        check('implausible report is refused (422)', st == 422, (st, body))
        st, body, _ = call('POST', '/functions/v1/report', ANON, ANON, report(1, 5))
        check('report with the anon key instead of a user token is refused (401)', st == 401, st)

        st, body, _ = call('POST', '/functions/v1/report', ANON, a, report(1, 5))
        check('plausible report is stored', st == 200 and body.get('stored') == 6, (st, body))
        check('report answers with 12 places', len(body.get('ranks', [])) == 12 if st == 200 else False, body)
        st, body, _ = call('POST', '/functions/v1/report', ANON, b, report(3, 1))
        check('second participant reports', st == 200, (st, body))
        st, body, hdr = call('POST', '/functions/v1/report', ANON, a, report(1, 5))
        check(
            'second report within 25 min is refused (429)',
            st == 429 and 'retry-after' in {k.lower() for k in hdr},
            (st, body),
        )

        st, body, _ = call(
            'POST', '/rest/v1/rpc/leaderboard', ANON, c, {'p_period': '7D', 'p_unit': 'tokens', 'p_limit': 10}
        )
        names = [r['display_name'] for r in body] if st == 200 else body
        check('leaderboard by tokens: B before A', names == [f'test-2-{RUN}', 'Alpha'], names)
        st, body, _ = call(
            'POST', '/rest/v1/rpc/leaderboard', ANON, c, {'p_period': '7D', 'p_unit': 'usd', 'p_limit': 10}
        )
        names = [r['display_name'] for r in body] if st == 200 else body
        check('leaderboard by usd: A before B', names == ['Alpha', f'test-2-{RUN}'], names)
        st, body, _ = call('POST', '/rest/v1/rpc/my_rank', ANON, a, {'p_period': '30D', 'p_unit': 'tokens'})
        check('my_rank: #2 of 2', st == 200 and body and body[0]['rank'] == 2 and body[0]['participants'] == 2, body)
        st, body, _ = call('POST', '/rest/v1/rpc/my_rank', ANON, c, {'p_period': '30D', 'p_unit': 'usd'})
        check(
            'non-participant: no rank, 2 participants',
            st == 200 and body[0]['rank'] is None and body[0]['participants'] == 2,
            body,
        )

        st, body, _ = call('POST', '/rest/v1/rpc/leave_leaderboard', ANON, a, {})
        check('leave', st == 200, (st, body))
        st, body, _ = call('GET', f'/rest/v1/totals?select=period&user_id=eq.{created[0]}', SERVICE)
        check('leave removed every total', st == 200 and body == [], body)

        st, body, _ = call('POST', '/functions/v1/delete-account', ANON, b, {})
        check('delete-account', st == 200 and body == {'deleted': True}, (st, body))
        st, body, _ = call('GET', f'/rest/v1/profiles?select=id&id=eq.{created[1]}', SERVICE)
        check('delete-account removed the profile', st == 200 and body == [], body)
    finally:
        for uid in created:
            st, _, _ = call('DELETE', f'/auth/v1/admin/users/{uid}', SERVICE)
            print(f'cleanup user {uid[:8]}: {st}')
        st, body, _ = call('GET', '/rest/v1/profiles?select=id', SERVICE)
        print('profiles left:', len(body) if isinstance(body, list) else body)
    failed = [n for n, ok in CHECKS if not ok]
    print(f'{len(CHECKS) - len(failed)}/{len(CHECKS)} checks passed')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
