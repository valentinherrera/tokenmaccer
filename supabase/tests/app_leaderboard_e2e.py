#!/usr/bin/env python3
"""End-to-end test of the app's leaderboard path against the LOCAL stack, through the real collector binary.

What runs for real: `tokenmaccer-collector leaderboard join` (PKCE code exchange, tokens into a keychain
item of a throwaway service name, join_leaderboard), the collector pass (report to /functions/v1/report,
places into widget.json), the 30-minute cadence, `leaderboard group …` (create, join by code, refresh into
leaderboard-groups.json, a 403 that must not end the participation, an unknown code, leave; the owner's
group passes to the next member when the owner leaves the leaderboard), `leaderboard leave` (delete-account,
tokens and state gone) and the opt-in gate (a counting HTTP server sees no request from a collector that has not joined;
positive control: a joined one does reach it).

What is simulated: GitHub. Users are synthetic (test-e2e-<n>-<run>@example.com); their GitHub identity
and, for user A, the PKCE flow state GoTrue writes after the GitHub callback are inserted with psql into
the local database container. Every user created here is deleted at the end, also on failure.

    SB_URL=http://127.0.0.1:54321 SB_ANON=<publishable or anon key> SB_SERVICE=<service role key> \\
    SB_DB_CONTAINER=supabase_db_tokenmaccer TM_HELPER=<path to tokenmaccer-collector> \\
        python3 -I supabase/tests/app_leaderboard_e2e.py

Refuses to run against anything but 127.0.0.1/localhost. SB_SERVICE is never printed.
"""

from __future__ import annotations

import base64
import hashlib
import http.server
import json
import os
import secrets
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from typing import Any, ClassVar, Dict, List, Tuple

URL = os.environ['SB_URL'].rstrip('/')
ANON = os.environ['SB_ANON']
SERVICE = os.environ['SB_SERVICE']
DB = os.environ['SB_DB_CONTAINER']
HELPER = os.environ['TM_HELPER']
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUN = secrets.token_hex(3)
KEYCHAIN_SERVICE = f'tokenmaccer-e2e-{RUN}'
CHECKS: List[Tuple[str, bool]] = []

if not (URL.startswith('http://127.0.0.1:') or URL.startswith('http://localhost:')):
    sys.exit('local stack only')


def check(name: str, cond: object, info: object = '') -> None:
    CHECKS.append((name, bool(cond)))
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  [{info}]'))


def call(method: str, path: str, key: str, token: str | None = None, body: Any = None) -> Tuple[int, Any]:
    headers = {'apikey': key, 'Authorization': f'Bearer {token or key}', 'Content-Type': 'application/json'}
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(URL + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, (json.loads(raw) if raw else None)
        except ValueError:
            return e.code, raw.decode(errors='replace')[:200]


def psql(sql: str) -> str:
    r = subprocess.run(
        ['docker', 'exec', DB, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atqc', sql],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if r.returncode != 0:
        raise RuntimeError('psql: ' + r.stderr.strip()[:300])
    return r.stdout.strip()


def helper(
    args: List[str], data_dir: str, stdin: str | None = None, url: str = URL, service: str = KEYCHAIN_SERVICE
) -> Tuple[int, str, str]:
    env = {
        'PATH': '/usr/bin:/bin',
        'HOME': os.environ['HOME'],
        'TOKENMACCER_LEADERBOARD_URL': url,
        'TOKENMACCER_LEADERBOARD_KEY': ANON,
        'TOKENMACCER_KEYCHAIN_SERVICE': service,
        'TOKENMACCER_DATA_DIR': data_dir,
    }
    r = subprocess.run([HELPER] + args, input=stdin, capture_output=True, text=True, timeout=120, env=env, check=False)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def collect(data_dir: str, claude_dir: str, url: str = URL) -> Tuple[int, str, str]:
    return helper(
        ['--claude-dir', claude_dir, '--widget-out', os.path.join(data_dir, 'widget.json')], data_dir, url=url
    )


def state(data_dir: str) -> Any:
    try:
        with open(os.path.join(data_dir, 'leaderboard.json')) as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def last_json(out: str) -> Any:
    try:
        return json.loads(out.splitlines()[-1]) if out else {}
    except ValueError:
        return {}


def groups_file(data_dir: str) -> Any:
    try:
        with open(os.path.join(data_dir, 'leaderboard-groups.json')) as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def board_names(group: Any, period: str, unit: str) -> List[str]:
    for b in group.get('boards', []):
        if b.get('period') == period and b.get('unit') == unit:
            return [e.get('displayName') for e in b.get('entries', [])]
    return []


def widget(data_dir: str) -> Any:
    with open(os.path.join(data_dir, 'widget.json')) as f:
        return json.load(f)


def new_user(n: int, github: bool = True) -> Tuple[str, str, str, str | None]:
    email = f'test-e2e-{n}-{RUN}@example.com'
    password = secrets.token_urlsafe(18)
    st, body = call(
        'POST', '/auth/v1/admin/users', SERVICE, body={'email': email, 'password': password, 'email_confirm': True}
    )
    if st != 200:
        raise RuntimeError(f'create user {n}: {st} {body}')
    uid = body['id']
    login = f'synth-gh-{n}-{RUN}'
    if not github:
        return uid, email, password, None
    psql(
        'insert into auth.identities '
        '(provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at) '
        f"values ('{RUN}{n}', '{uid}', jsonb_build_object('sub', '{RUN}{n}', 'user_name', '{login}', "
        f"'preferred_username', '{login}'), 'github', now(), now(), now())"
    )
    return uid, email, password, login


def add_flow_state(uid: str, code: str, challenge: str) -> None:
    """The PKCE flow state GoTrue stores after the GitHub callback (what the code exchange looks up)."""
    psql(
        'insert into auth.flow_state (id, user_id, auth_code, code_challenge_method, code_challenge, provider_type, '
        'provider_access_token, provider_refresh_token, authentication_method, created_at, updated_at, '
        'auth_code_issued_at, email_optional) values '
        f"(gen_random_uuid(), '{uid}', '{code}', 's256', '{challenge}', 'github', '', '', 'oauth', "
        'now(), now(), now(), false)'
    )


def pkce_flow(uid: str) -> str:
    """A fresh GitHub sign-in for `uid` as the helper gets it on stdin: flow state in GoTrue, code + verifier."""
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b'=').decode()
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
    code = secrets.token_hex(16)
    add_flow_state(uid, code, challenge)
    return json.dumps({'code': code, 'verifier': verifier})


def sign_in(uid: str) -> Any:
    """Tokens for `uid` through the PKCE code exchange (email sign-in is off, see supabase/config.toml)."""
    flow = json.loads(pkce_flow(uid))
    st, tok = call(
        'POST',
        '/auth/v1/token?grant_type=pkce',
        ANON,
        body={'auth_code': flow['code'], 'code_verifier': flow['verifier']},
    )
    if st != 200:
        raise RuntimeError(f'sign-in {uid}: {st} {tok}')
    return tok


def server_rows(uid: str) -> str:
    return psql(
        f"select (select count(*) from auth.users where id = '{uid}') || ',' || "
        f"(select count(*) from public.profiles where id = '{uid}') || ',' || "
        f"(select count(*) from public.totals where user_id = '{uid}')"
    )


def report_body(scale: int) -> Dict[str, Any]:
    import datetime as dt

    today = dt.date.today()

    def p(inp: int, start: dt.date) -> Dict[str, Any]:
        return {
            'input': inp * scale,
            'output': inp * scale // 100,
            'usd': round(inp * scale / 1e6, 2),
            'start': start.isoformat(),
        }

    return {
        'periods': {
            '1D': p(1, today),
            '7D': p(7, today - dt.timedelta(days=6)),
            '30D': p(30, today - dt.timedelta(days=29)),
            'YTD': p(300, dt.date(today.year, 1, 1)),
            '1Y': p(365, today - dt.timedelta(days=364)),
            'ALL': p(400, today - dt.timedelta(days=400)),
        }
    }


class Counter(http.server.BaseHTTPRequestHandler):
    hits: ClassVar[List[str]] = []

    def handle_one(self) -> None:
        Counter.hits.append(self.path)
        self.send_response(503)
        self.end_headers()

    do_GET = do_POST = handle_one

    def log_message(self, *a: Any) -> None:
        pass


def main() -> None:
    users: List[str] = []
    tmp = tempfile.mkdtemp(prefix='tm-e2e-')
    claude = os.path.join(tmp, 'claude')
    a_dir, gate_dir, control_dir = (os.path.join(tmp, d) for d in ('a', 'gate', 'control'))
    subprocess.run(
        [sys.executable, '-I', os.path.join(ROOT, 'scripts/make_demo.py'), claude],
        check=True,
        capture_output=True,
        timeout=120,
    )
    try:
        a_uid, _, _, a_login = new_user(1)
        users.append(a_uid)
        others: List[str] = []
        tokens: List[str] = []
        for n, scale in ((2, 10**9), (3, 1)):
            uid, _, _, _ = new_user(n)
            users.append(uid)
            st, tok = 200, sign_in(uid)
            tokens.append(tok['access_token'])
            st2, _ = call(
                'POST', '/rest/v1/rpc/join_leaderboard', ANON, tok['access_token'], {'p_display_name': f'Synth {n}'}
            )
            st3, rep = call('POST', '/functions/v1/report', ANON, tok['access_token'], report_body(scale))
            check(
                f'user {n} joined and reported directly', st == 200 and st2 == 200 and st3 == 200, (st, st2, st3, rep)
            )
            others.append(uid)

        # user A: the app's way. GoTrue's flow state after the GitHub callback, then the helper exchanges the code
        verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b'=').decode()
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
        code = secrets.token_hex(16)
        add_flow_state(a_uid, code, challenge)
        rc, out, err = helper(
            ['leaderboard', 'join', '--display-name', '  Synth A  '],
            a_dir,
            stdin=json.dumps({'code': code, 'verifier': 'wrong' + verifier[5:]}),
        )
        check('wrong PKCE verifier is refused', rc == 1 and '"ok":false' in out, (rc, out, err))
        check('refused join leaves no opt-in', state(a_dir) is None, state(a_dir))
        add_flow_state(a_uid, code + 'x', challenge)
        rc, out, err = helper(
            ['leaderboard', 'join', '--display-name', '  Synth A  '],
            a_dir,
            stdin=json.dumps({'code': code + 'x', 'verifier': verifier}),
        )
        answer = json.loads(out.splitlines()[-1]) if out else {}
        check('helper join: code exchanged, joined', rc == 0 and answer.get('ok') is True, (rc, out, err))
        check('GitHub login comes from the identity', answer.get('github_login') == a_login, answer)
        check('display name trimmed', answer.get('display_name') == 'Synth A', answer)
        s = state(a_dir) or {}
        check(
            'leaderboard.json joined, no tokens in it',
            s.get('joined') is True and 'access' not in json.dumps(s).lower() and 'token' not in json.dumps(s).lower(),
            s,
        )

        # rename: the collector's sign-in, no new GitHub window; the server keeps the login and the opt-in
        rc, out, err = helper(['leaderboard', 'rename', '--display-name', ' Synth A2 '], a_dir)
        answer = json.loads(out.splitlines()[-1]) if out else {}
        check('helper rename: ok, trimmed', rc == 0 and answer.get('display_name') == 'Synth A2', (rc, out, err))
        check(
            'rename: server and leaderboard.json have the new name',
            psql(f"select display_name from public.profiles where id = '{a_uid}'") == 'Synth A2'
            and (state(a_dir) or {}).get('displayName') == 'Synth A2',
        )
        rc, out, err = helper(['leaderboard', 'rename', '--display-name', 'x' * 33], a_dir)
        check('rename: 33 characters refused', rc == 1 and '"ok":false' in out, (rc, out))

        # first pass reports at once and writes A's places (B is far ahead, C far behind)
        rc, out, err = collect(a_dir, claude)
        check('first pass reports', rc == 0 and 'leaderboard: reported' in out, (rc, out, err))
        ranks = widget(a_dir).get('ranks', {})
        check('widget.json: ALL tokens #2 of 3', ranks.get('ALL', {}).get('tokens') == {'rank': 2, 'of': 3}, ranks)
        check('widget.json: 30D usd #2 of 3', ranks.get('30D', {}).get('usd') == {'rank': 2, 'of': 3}, ranks)
        lines = out.splitlines()
        check('last output line stays the collector summary', lines and 'new turns' in lines[-1], out)
        first = psql(f"select last_report_at from public.profiles where id = '{a_uid}'")
        check("server stored A's report", first != '', first)
        n_totals = psql(f"select count(*) from public.totals where user_id = '{a_uid}'")
        check('six totals stored', n_totals == '6', n_totals)

        # cadence: the next passes within 30 minutes send nothing
        for _ in range(2):
            rc, out, err = collect(a_dir, claude)
        again = psql(f"select last_report_at from public.profiles where id = '{a_uid}'")
        check(
            'no second report within 30 minutes',
            rc == 0 and 'leaderboard' not in out and again == first,
            (out, first, again),
        )
        check(
            'places kept in widget.json between reports',
            widget(a_dir).get('ranks', {}).get('ALL', {}).get('tokens') == {'rank': 2, 'of': 3},
        )

        # groups: A creates one through the helper, B (user 2) joins with the code in another case, A's refresh
        # writes both onto the group's boards
        rc, out, err = helper(['leaderboard', 'group', 'create', '--name', '  Synth   Friends '], a_dir)
        group = last_json(out).get('group') or {}
        check(
            'helper group create: ok, name cleaned, owner',
            rc == 0 and group.get('name') == 'Synth Friends' and group.get('is_owner') is True,
            (rc, out, err),
        )
        st, joined = call(
            'POST', '/rest/v1/rpc/join_group', ANON, tokens[0], {'p_code': f' {group.get("code", "").upper()} '}
        )
        check(
            'B joins with the code (upper case, spaces)',
            st == 200 and joined.get('id') == group.get('id'),
            (st, joined),
        )
        rc, out, err = helper(['leaderboard', 'group', 'refresh'], a_dir)
        gf = groups_file(a_dir) or {}
        mine = [g for g in gf.get('groups', []) if g.get('group', {}).get('id') == group.get('id')]
        check('helper group refresh: leaderboard-groups.json has the group', rc == 0 and len(mine) == 1, (rc, out, gf))
        g0 = mine[0] if mine else {}
        check(
            'group members: A (owner) and B',
            sorted(m.get('displayName') for m in g0.get('members', [])) == ['Synth 2', 'Synth A2']
            and [m.get('isOwner') for m in g0.get('members', [])] == [True, False],
            g0.get('members'),
        )
        check(
            'group board ALL tokens: B first, A second, nobody else',
            board_names(g0, 'ALL', 'tokens') == ['Synth 2', 'Synth A2'],
            board_names(g0, 'ALL', 'tokens'),
        )
        check('group file holds no tokens', 'access' not in json.dumps(gf).lower(), '')

        # B's group: A joins it through the helper; renaming it is the owner's right only. The 403 is a group
        # error and must not end A's participation (LeaderboardClient.check would read it as "left").
        st, bg = call('POST', '/rest/v1/rpc/create_group', ANON, tokens[0], {'p_name': 'Synth B group'})
        rc, out, err = helper(['leaderboard', 'group', 'join', '--code', bg.get('code', '')], a_dir)
        check(
            'helper group join by code',
            rc == 0 and (last_json(out).get('group') or {}).get('id') == bg.get('id'),
            (rc, out),
        )
        before = state(a_dir) or {}
        rc, out, err = helper(
            ['leaderboard', 'group', 'rename', '--group', bg.get('id', ''), '--name', 'hijack'], a_dir
        )
        check(
            'rename by a non-owner refused as a group error',
            rc == 1 and last_json(out).get('error_kind') == 'not_allowed',
            (rc, out),
        )
        after = state(a_dir) or {}
        check(
            '403 from a group call: still joined, no error in leaderboard.json',
            after.get('joined') is True and after.get('lastError') == before.get('lastError'),
            after,
        )
        check(
            'group name unchanged on the server',
            psql(f"select name from public.groups where id = '{bg.get('id')}'") == 'Synth B group',
        )
        rc, out, err = helper(['leaderboard', 'group', 'join', '--code', 'zzzzzzzzzz'], a_dir)
        check('unknown code: invalid link', rc == 1 and last_json(out).get('error_kind') == 'invalid_code', (rc, out))
        rc, out, err = helper(['leaderboard', 'group', 'leave', '--group', bg.get('id', '')], a_dir)
        ids = [g.get('group', {}).get('id') for g in (groups_file(a_dir) or {}).get('groups', [])]
        check(
            'helper group leave: gone from the file at once',
            rc == 0 and bg.get('id') not in ids and group.get('id') in ids,
            (rc, out, ids),
        )

        # opt-in gate against a counting server: not joined -> no request; joined -> request (positive control)
        srv = http.server.HTTPServer(('127.0.0.1', 0), Counter)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        fake = f'http://127.0.0.1:{srv.server_address[1]}'
        rc, out, err = collect(gate_dir, claude, url=fake)
        check(
            'gate: not joined -> 0 requests',
            rc == 0 and Counter.hits == [] and 'ranks' not in widget(gate_dir),
            (Counter.hits, out),
        )
        os.makedirs(control_dir, exist_ok=True)
        ctrl = dict(s)
        ctrl.pop('lastAttemptAt', None)
        with open(os.path.join(control_dir, 'leaderboard.json'), 'w') as f:
            json.dump(ctrl, f)
        rc, out, err = collect(control_dir, claude, url=fake)
        check(
            'gate positive control: joined -> request reaches the server', len(Counter.hits) >= 1, (Counter.hits, out)
        )
        srv.shutdown()

        # leave: account, profile and totals gone on the server; tokens and state gone locally
        rc, out, err = helper(['leaderboard', 'leave'], a_dir)
        check('helper leave', rc == 0 and '"ok":true' in out, (rc, out, err))
        gone = psql(
            f"select (select count(*) from auth.users where id = '{a_uid}') || ',' || "
            f"(select count(*) from public.profiles where id = '{a_uid}') || ',' || "
            f"(select count(*) from public.totals where user_id = '{a_uid}')"
        )
        check('server: user, profile, totals deleted', gone == '0,0,0', gone)
        check('leaderboard.json removed', state(a_dir) is None)
        check('leaderboard-groups.json removed', groups_file(a_dir) is None)
        st, bgroups = call('POST', '/rest/v1/rpc/my_groups', ANON, tokens[0], {})
        handed = [g for g in (bgroups or []) if g.get('id') == group.get('id')]
        check(
            "A left the leaderboard: A's group passed to B, A is no longer a member",
            st == 200 and len(handed) == 1 and handed[0].get('is_owner') is True and handed[0].get('members') == 1,
            (st, bgroups),
        )
        rc, out, err = collect(a_dir, claude)
        # the pass removes the widget's copy of the boards (what Leave promises) and logs that, nothing else
        check(
            'after leave: no report, no ranks, widget copy gone',
            'leaderboard:' not in out
            and 'ranks' not in widget(a_dir)
            and not os.path.exists(os.path.join(a_dir, 'leaderboard-widget.json')),
            out,
        )
        # tokens gone: a forged opt-in finds no sign-in (no keychain read from outside the collector)
        with open(os.path.join(a_dir, 'leaderboard.json'), 'w') as f:
            json.dump({'joined': True, 'ranks': [], 'leavePending': False}, f)
        rc, out, err = collect(a_dir, claude)
        check('keychain item deleted (helper: not signed in)', 'no sign-in for the leaderboard server' in out, out)
        os.remove(os.path.join(a_dir, 'leaderboard.json'))

        # D: the sign-in on this Mac is lost (simulated: another keychain service name). Leave must not
        # pretend; it asks for a fresh sign-in, refuses another GitHub account, and then deletes the account.
        d_dir = os.path.join(tmp, 'd')
        d_uid, _, _, d_login = new_user(4)
        users.append(d_uid)
        e_uid, _, _, _ = new_user(5)
        users.append(e_uid)
        # one-button join: no display name, the server takes the GitHub username
        rc, out, err = helper(['leaderboard', 'join'], d_dir, stdin=pkce_flow(d_uid))
        check('D joined through the helper', rc == 0 and '"ok":true' in out, (rc, out, err))
        answer = json.loads(out.splitlines()[-1]) if out else {}
        check('join without a name: display name is the GitHub username', answer.get('display_name') == d_login, answer)
        lost = KEYCHAIN_SERVICE + '-lost'
        rc, out, err = helper(['leaderboard', 'leave'], d_dir, service=lost)
        sd = state(d_dir) or {}
        check('lost sign-in: leave is not ok', rc == 1 and '"ok":false' in out, (rc, out))
        check(
            'lost sign-in: state says leave pending, sign-in required',
            sd.get('leavePending') is True and sd.get('signInRequired') is True and sd.get('joined') is False,
            sd,
        )
        check('lost sign-in: account still on the server (not silently dropped)', server_rows(d_uid) == '1,1,0')
        rc, out, err = helper(['leaderboard', 'leave', '--sign-in'], d_dir, stdin=pkce_flow(e_uid), service=lost)
        check('sign-in as another account is refused', rc == 1 and 'not the one that joined' in out, (rc, out))
        check('other account: D untouched', server_rows(d_uid) == '1,1,0')
        check('other account without an entry: its server account is deleted again', server_rows(e_uid) == '0,0,0')
        rc, out, err = helper(['leaderboard', 'leave', '--sign-in'], d_dir, stdin=pkce_flow(others[0]), service=lost)
        check('sign-in as another participant is refused', rc == 1 and 'not the one that joined' in out, (rc, out))
        check('other participant: its account and entry stay', server_rows(others[0]).startswith('1,1,'))
        rc, out, err = helper(['leaderboard', 'leave', '--sign-in'], d_dir, stdin=pkce_flow(d_uid), service=lost)
        check('fresh sign-in + leave: ok', rc == 0 and '"ok":true' in out, (rc, out, err))
        check('fresh sign-in + leave: user, profile, totals deleted', server_rows(d_uid) == '0,0,0', server_rows(d_uid))
        check('fresh sign-in + leave: state removed', state(d_dir) is None)
        helper(['leaderboard', 'leave'], d_dir)  # drop D's original keychain item (its account is gone already)

        # F: joining fails after the code exchange (no GitHub identity -> join_leaderboard refuses):
        # the account the sign-in created is deleted again
        f_dir = os.path.join(tmp, 'f')
        f_uid, _, _, _ = new_user(6, github=False)
        users.append(f_uid)
        rc, out, err = helper(['leaderboard', 'join', '--display-name', 'Synth F'], f_dir, stdin=pkce_flow(f_uid))
        check('join without GitHub identity fails', rc == 1 and '"ok":false' in out, (rc, out))
        check('failed join: the new account is deleted', server_rows(f_uid) == '0,0,0', server_rows(f_uid))
        check('failed join: no state left', state(f_dir) is None, state(f_dir))
        ips = psql(
            "select count(*) || ',' || count(*) filter (where coalesce(ip_address, '') <> '') "
            "from auth.audit_log_entries where created_at > now() - interval '10 minutes'"
        )
        print('info auth.audit_log_entries last 10 min (all, with ip_address): ' + ips)
    finally:
        helper(['leaderboard', 'leave'], a_dir)  # removes a left-over keychain item of this run, if any
        for uid in users:
            call('DELETE', f'/auth/v1/admin/users/{uid}', SERVICE)
        left = psql(f"select count(*) from auth.users where email like 'test-e2e-%-{RUN}@example.com'")
        check('cleanup: synthetic users deleted', left == '0', left)
        subprocess.run(['rm', '-rf', tmp], check=False)
    failed = [n for n, ok in CHECKS if not ok]
    print(f'{len(CHECKS) - len(failed)}/{len(CHECKS)} checks passed')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
