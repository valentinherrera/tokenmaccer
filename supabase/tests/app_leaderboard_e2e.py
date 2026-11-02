#!/usr/bin/env python3
"""End-to-end test of the app's leaderboard path against the LOCAL stack, through the real collector binary.

What runs for real: `tokenmaccer-collector leaderboard join` (PKCE code exchange, tokens into a keychain
item of a throwaway service name, join_leaderboard), the collector pass (report to /functions/v1/report,
places into widget.json), the 30-minute cadence, `leaderboard leave` (delete-account, tokens and state
gone) and the opt-in gate (a counting HTTP server sees no request from a collector that has not joined;
positive control: a joined one does reach it).

What is simulated: GitHub. Users are synthetic (test-e2e-<n>-<run>@example.com); their GitHub identity
and, for user A, the PKCE flow state GoTrue writes after the GitHub callback are inserted with psql into
the local database container. Every user created here is deleted at the end, also on failure.

    SB_URL=http://127.0.0.1:54321 SB_ANON=<publishable or anon key> SB_SERVICE=<service role key> \\
    SB_DB_CONTAINER=supabase_db_tokenmaccer TM_HELPER=<path to tokenmaccer-collector> \\
        python3 -I supabase/tests/app_leaderboard_e2e.py

Refuses to run against anything but 127.0.0.1/localhost. SB_SERVICE is never printed.
"""

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

URL = os.environ['SB_URL'].rstrip('/')
ANON = os.environ['SB_ANON']
SERVICE = os.environ['SB_SERVICE']
DB = os.environ['SB_DB_CONTAINER']
HELPER = os.environ['TM_HELPER']
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUN = secrets.token_hex(3)
KEYCHAIN_SERVICE = f'tokenmaccer-e2e-{RUN}'
CHECKS = []

if not (URL.startswith('http://127.0.0.1:') or URL.startswith('http://localhost:')):
    sys.exit('local stack only')


def check(name, cond, info=''):
    CHECKS.append((name, bool(cond)))
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  [{info}]'))


def call(method, path, key, token=None, body=None):
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


def psql(sql):
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


def helper(args, data_dir, stdin=None, url=URL):
    env = {
        'PATH': '/usr/bin:/bin',
        'HOME': os.environ['HOME'],
        'TOKENMACCER_LEADERBOARD_URL': url,
        'TOKENMACCER_LEADERBOARD_KEY': ANON,
        'TOKENMACCER_KEYCHAIN_SERVICE': KEYCHAIN_SERVICE,
        'TOKENMACCER_DATA_DIR': data_dir,
    }
    r = subprocess.run([HELPER] + args, input=stdin, capture_output=True, text=True, timeout=120, env=env, check=False)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def collect(data_dir, claude_dir, url=URL):
    return helper(
        ['--claude-dir', claude_dir, '--widget-out', os.path.join(data_dir, 'widget.json')], data_dir, url=url
    )


def state(data_dir):
    try:
        with open(os.path.join(data_dir, 'leaderboard.json')) as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def widget(data_dir):
    with open(os.path.join(data_dir, 'widget.json')) as f:
        return json.load(f)


def new_user(n):
    email = f'test-e2e-{n}-{RUN}@example.com'
    password = secrets.token_urlsafe(18)
    st, body = call(
        'POST', '/auth/v1/admin/users', SERVICE, body={'email': email, 'password': password, 'email_confirm': True}
    )
    if st != 200:
        raise RuntimeError(f'create user {n}: {st} {body}')
    uid = body['id']
    login = f'synth-gh-{n}-{RUN}'
    psql(
        'insert into auth.identities '
        '(provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at) '
        f"values ('{RUN}{n}', '{uid}', jsonb_build_object('sub', '{RUN}{n}', 'user_name', '{login}', "
        f"'preferred_username', '{login}'), 'github', now(), now(), now())"
    )
    return uid, email, password, login


def add_flow_state(uid, code, challenge):
    """The PKCE flow state GoTrue stores after the GitHub callback (what the code exchange looks up)."""
    psql(
        'insert into auth.flow_state (id, user_id, auth_code, code_challenge_method, code_challenge, provider_type, '
        'provider_access_token, provider_refresh_token, authentication_method, created_at, updated_at, '
        'auth_code_issued_at, email_optional) values '
        f"(gen_random_uuid(), '{uid}', '{code}', 's256', '{challenge}', 'github', '', '', 'oauth', "
        'now(), now(), now(), false)'
    )


def report_body(scale):
    import datetime as dt

    today = dt.date.today()

    def p(inp, start):
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
    hits = []

    def handle_one(self):
        Counter.hits.append(self.path)
        self.send_response(503)
        self.end_headers()

    do_GET = do_POST = handle_one

    def log_message(self, *a):
        pass


def main():
    users = []
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
        others = []
        for n, scale in ((2, 10**9), (3, 1)):
            uid, email, password, _ = new_user(n)
            users.append(uid)
            st, tok = call(
                'POST', '/auth/v1/token?grant_type=password', ANON, body={'email': email, 'password': password}
            )
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
        rc, out, err = collect(a_dir, claude)
        check('after leave: no report, no ranks', 'leaderboard' not in out and 'ranks' not in widget(a_dir), out)
        # tokens gone: a forged opt-in finds no sign-in (no keychain read from outside the collector)
        with open(os.path.join(a_dir, 'leaderboard.json'), 'w') as f:
            json.dump({'joined': True, 'ranks': [], 'leavePending': False}, f)
        rc, out, err = collect(a_dir, claude)
        check('keychain item deleted (helper: not signed in)', 'Not signed in' in out, out)
        os.remove(os.path.join(a_dir, 'leaderboard.json'))
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
