#!/usr/bin/env python3
"""Runs the Python collector and the Swift collector on the same transcripts and compares the results.

Usage: compare_collectors.py --claude-dir DIR --swift BIN [--now ISO] [--python /usr/bin/python3] [--keep]

Both collectors get the same input (DIR/projects), the same pinned time (TOKENMACCER_NOW) and their own
empty data directory. Compared per period (1D/7D/30D/YTD/1Y/ALL): input, output, cache tokens (from the
store's daily rows over the period), USD, change, ratio and every point of both lines; integers exactly,
floats within 1e-9. The store (days, hours, offsets, dedup ids) must be identical too. A second pass with
no new transcripts must add nothing on either side. Exit code 0 = identical, 1 = differences.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Dict, List, Tuple

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COLLECTOR = os.path.join(ROOT, 'collector', 'collector.py')
FIELDS = ['input', 'output', 'cache_read', 'write_5m', 'write_1h', 'turns', 'subagent_input']
TOLERANCE = 1e-9


def run(cmd: List[str], data_dir: str, claude_dir: str, now: str) -> str:
    env = {k: v for k, v in os.environ.items() if not k.startswith('TOKENMACCER_') and k != 'CLAUDE_CONFIG_DIR'}
    env.update(TOKENMACCER_DATA_DIR=data_dir, TOKENMACCER_CLAUDE_DIR=claude_dir, TOKENMACCER_NOW=now)
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, check=False)
    if p.returncode != 0:
        sys.exit(f'{cmd[0]} failed ({p.returncode}): {p.stderr.strip()}')
    return p.stdout.strip()


def load(path: str) -> Any:
    with open(path) as f:
        return json.load(f)


def same(a: Any, b: Any) -> bool:
    if isinstance(a, float) or isinstance(b, float):
        return isinstance(a, (int, float)) and isinstance(b, (int, float)) and abs(a - b) <= TOLERANCE
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    return bool(a == b)


def cache_tokens(store: Dict[str, Any], start: str, end: str) -> Tuple[int, int, int]:
    """cache_read, write_5m, write_1h of all days in [start, end] from the store's daily rows."""
    totals = [0, 0, 0]
    for day, models in store['days'].items():
        if start <= day <= end:
            for row in models.values():
                for i, field in enumerate(('cache_read', 'write_5m', 'write_1h')):
                    totals[i] += row[FIELDS.index(field)]
    return totals[0], totals[1], totals[2]


def compare(py_dir: str, sw_dir: str, label: str) -> List[str]:
    problems: List[str] = []
    wp, ws = load(os.path.join(py_dir, 'widget.json')), load(os.path.join(sw_dir, 'widget.json'))
    sp, ss = load(os.path.join(py_dir, 'store.json')), load(os.path.join(sw_dir, 'store.json'))
    for key in ('updated', 'order'):
        if wp.get(key) != ws.get(key):
            problems.append(f'{key}: python {wp.get(key)!r} swift {ws.get(key)!r}')
    names = list(wp['periods']) + [n for n in ws['periods'] if n not in wp['periods']]
    print(f'\n[{label}]')
    header = ('period', 'input', 'output', 'cache_read', 'usd', 'chg_in', 'chg_usd')
    print('{:<6} {:>15} {:>12} {:>15} {:>12} {:>8} {:>8}  result'.format(*header))
    for name in names:
        p, s = wp['periods'].get(name), ws['periods'].get(name)
        if p is None or s is None:
            problems.append(f'{name}: missing on the {"python" if p is None else "swift"} side')
            continue
        diff = [k for k in sorted(set(p) | set(s)) if not same(p.get(k), s.get(k))]
        cp, cs = cache_tokens(sp, p['from'], p['to']), cache_tokens(ss, s['from'], s['to'])
        if cp != cs:
            diff.append(f'cache tokens {cp} vs {cs}')
        for k in diff:
            problems.append(f'{name}.{k}: python {p.get(k)!r:.80} swift {s.get(k)!r:.80}')
        print(
            f'{name:<6} {p["input"]:>15,} {p["output"]:>12,} {cp[0]:>15,} {p["usd"]:>12,.2f} '
            f'{str(p["change_input"]):>8} {str(p["change_usd"]):>8}  {"same" if not diff else "DIFF " + ",".join(diff)}'
        )
    for part in ('days', 'hours', 'files', 'seen'):
        if not same(sp.get(part), ss.get(part)):
            only_p = len(set(sp.get(part, {})) - set(ss.get(part, {})))
            only_s = len(set(ss.get(part, {})) - set(sp.get(part, {})))
            problems.append(f'store.{part} differs (keys only python: {only_p}, only swift: {only_s})')
    for name in ('widget.json', 'store.json'):
        with open(os.path.join(py_dir, name), 'rb') as a, open(os.path.join(sw_dir, name), 'rb') as b:
            identical = a.read() == b.read()
        print(f'{name}: {"byte-identical" if identical else "same values, different bytes"}')
    return problems


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--claude-dir', required=True, help='folder that contains projects/')
    ap.add_argument('--swift', required=True, help='tokenmaccer-collector binary')
    ap.add_argument('--now', default=dt.datetime.now().strftime('%Y-%m-%dT%H:%M:00'), help='pinned local time')
    ap.add_argument('--python', default='/usr/bin/python3')
    ap.add_argument('--keep', action='store_true', help='keep the temporary data folders')
    a = ap.parse_args()

    work = tempfile.mkdtemp(prefix='tokenmaccer-compare-')
    py_dir, sw_dir = os.path.join(work, 'python'), os.path.join(work, 'swift')
    python_cmd = [a.python, '-I', COLLECTOR]
    print(f'input {a.claude_dir}/projects · now {a.now} · work {work}')
    problems: List[str] = []
    try:
        out_p = run(python_cmd, py_dir, a.claude_dir, a.now)
        out_s = run([a.swift], sw_dir, a.claude_dir, a.now)
        print(f'python: {out_p}\nswift:  {out_s}')
        if out_p.split(' ')[0] != out_s.split(' ')[0]:
            problems.append(f'new turns: python {out_p.split(" ")[0]} swift {out_s.split(" ")[0]}')
        problems += compare(py_dir, sw_dir, 'first pass')

        # second pass: nothing new, the store must stay untouched on both sides
        stamps = [os.stat(os.path.join(d, 'store.json')).st_mtime_ns for d in (py_dir, sw_dir)]
        out_p = run(python_cmd, py_dir, a.claude_dir, a.now)
        out_s = run([a.swift], sw_dir, a.claude_dir, a.now)
        for side, out in (('python', out_p), ('swift', out_s)):
            if not out.startswith('0 new turns'):
                problems.append(f'second pass {side}: {out}')
        if stamps != [os.stat(os.path.join(d, 'store.json')).st_mtime_ns for d in (py_dir, sw_dir)]:
            problems.append('second pass rewrote a store without new turns')
        problems += compare(py_dir, sw_dir, 'second pass (no new turns)')
    finally:
        if not a.keep:
            shutil.rmtree(work, ignore_errors=True)

    if problems:
        print(f'\nFAIL: {len(problems)} difference(s)')
        for p in problems[:40]:
            print('  ' + p)
        sys.exit(1)
    print('\nPASS: Python and Swift collectors agree on every period, line point and store entry')


if __name__ == '__main__':
    main()
