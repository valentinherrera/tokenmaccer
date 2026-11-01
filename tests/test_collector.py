"""Collector tests with made-up transcripts. Run: python3 -m unittest discover -s tests"""

from __future__ import annotations

import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from typing import Any, Dict, List

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COLLECTOR = os.path.join(ROOT, 'collector', 'collector.py')
PRICES = json.load(open(os.path.join(ROOT, 'collector', 'prices.json')))


def ts(days_ago: int = 0, hour: int | None = None) -> str:
    """UTC timestamp for a local time `days_ago` days back (local hour defaults to 00:30 or now)."""
    now = dt.datetime.now().astimezone()
    t = now - dt.timedelta(days=days_ago)
    if hour is not None:
        t = t.replace(hour=hour, minute=30, second=0, microsecond=0)
    elif days_ago == 0:
        t = now - dt.timedelta(minutes=1)
    return t.astimezone(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')


def turn(
    mid: str,
    when: str,
    model: str = 'claude-sonnet-5-5',
    inp: int = 100,
    out: int = 50,
    cread: int = 1000,
    w5: int = 0,
    w1h: int = 0,
    req: str = 'r',
    split: bool = True,
) -> Dict[str, Any]:
    usage: Dict[str, Any] = {
        'input_tokens': inp,
        'output_tokens': out,
        'cache_read_input_tokens': cread,
        'cache_creation_input_tokens': w5 + w1h,
    }
    if split:
        usage['cache_creation'] = {'ephemeral_5m_input_tokens': w5, 'ephemeral_1h_input_tokens': w1h}
    return {
        'type': 'assistant',
        'timestamp': when,
        'requestId': req + mid,
        'message': {'id': mid, 'model': model, 'usage': usage},
    }


class CollectorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp(prefix='tokenmaccer-test-')
        self.claude = os.path.join(self.tmp, 'claude')
        self.data = os.path.join(self.tmp, 'data')
        self.proj = os.path.join(self.claude, 'projects', '-Users-demo-project')
        os.makedirs(self.proj)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def write(self, name: str, rows: List[Any], mode: str = 'w', raw_tail: str = '') -> str:
        path = os.path.join(self.proj, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, mode) as f:
            for r in rows:
                f.write((r if isinstance(r, str) else json.dumps(r)) + '\n')
            f.write(raw_tail)
        return path

    def run_collector(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ, TOKENMACCER_DATA_DIR=self.data, TOKENMACCER_CLAUDE_DIR=self.claude)
        env.pop('TOKENMACCER_EXTRA_SOURCES', None)
        p = subprocess.run(
            [sys.executable, '-I', COLLECTOR, *args], env=env, capture_output=True, text=True, check=False
        )
        self.assertEqual(p.returncode, 0, p.stderr)
        return p

    def store(self) -> Dict[str, Any]:
        with open(os.path.join(self.data, 'store.json')) as f:
            data: Dict[str, Any] = json.load(f)
        return data

    def widget(self) -> Dict[str, Any]:
        with open(os.path.join(self.data, 'widget.json')) as f:
            data: Dict[str, Any] = json.load(f)
        return data

    def total(self) -> int:
        return int(self.widget()['periods']['ALL']['input'])

    # --- positive control ---

    def test_positive_control_known_sum(self) -> None:
        self.write(
            'a.jsonl',
            [
                turn('m1', ts(0), inp=10, cread=200, w5=30, w1h=40),
                turn('m2', ts(3, 12), inp=1, cread=2, w5=3, w1h=4, out=7),
            ],
        )
        self.run_collector()
        self.assertEqual(self.total(), 10 + 200 + 30 + 40 + 1 + 2 + 3 + 4)
        self.assertEqual(self.widget()['periods']['ALL']['output'], 50 + 7)

    def test_usd_uses_price_table(self) -> None:
        self.write(
            'a.jsonl',
            [
                turn(
                    'm1',
                    ts(0),
                    model='claude-opus-5-5',
                    inp=1_000_000,
                    out=1_000_000,
                    cread=1_000_000,
                    w5=1_000_000,
                    w1h=1_000_000,
                )
            ],
        )
        self.run_collector()
        p = PRICES['claude-opus-5-5']
        expected = p['input'] + p['output'] + p['cache_read'] + p['write_5m'] + p['write_1h']
        self.assertAlmostEqual(self.widget()['periods']['1D']['usd'], expected, places=2)

    def test_unknown_model_uses_fallback(self) -> None:
        self.write('a.jsonl', [turn('m1', ts(0), model='claude-future-9', inp=1_000_000, out=0, cread=0)])
        self.run_collector()
        self.assertAlmostEqual(self.widget()['periods']['1D']['usd'], PRICES['_fallback']['input'], places=2)

    # --- parsing edge cases ---

    def test_duplicate_message_counted_once_across_files(self) -> None:
        t = turn('dup', ts(1, 10))
        self.write('a.jsonl', [t])
        self.write('b.jsonl', [t])
        self.run_collector()
        self.assertEqual(self.total(), 100 + 1000)

    def test_synthetic_and_non_assistant_lines_ignored(self) -> None:
        user = {'type': 'user', 'timestamp': ts(0), 'message': {'usage': {'input_tokens': 999}}}
        self.write(
            'a.jsonl',
            [turn('s1', ts(0), model='<synthetic>'), user, 'not json "usage"', turn('ok', ts(0), inp=5, cread=0)],
        )
        self.run_collector()
        self.assertEqual(self.total(), 5)

    def test_cache_write_without_split_counts_as_5m(self) -> None:
        self.write('a.jsonl', [turn('m1', ts(0), inp=0, cread=0, w5=100, split=False)])
        self.run_collector()
        day = self.store()['days']
        row = next(iter(next(iter(day.values())).values()))
        self.assertEqual(row[3], 100)  # write_5m
        self.assertEqual(row[4], 0)  # write_1h

    def test_subagent_input_tracked(self) -> None:
        self.write('sess1/subagents/agent-1.jsonl', [turn('sub1', ts(0), inp=10, cread=0)])
        self.run_collector()
        row = next(iter(next(iter(self.store()['days'].values())).values()))
        self.assertEqual(row[6], 10)

    # --- incremental behaviour ---

    def test_incremental_append_and_half_written_line(self) -> None:
        path = self.write(
            'a.jsonl', [turn('m1', ts(0), inp=1, cread=0)], raw_tail=json.dumps(turn('m2', ts(0), inp=2, cread=0))[:40]
        )
        self.run_collector()
        self.assertEqual(self.total(), 1, 'half-written line must wait')
        # finish the half-written line by rewriting the file with both full lines
        with open(path, 'w') as f:
            f.write(json.dumps(turn('m1', ts(0), inp=1, cread=0)) + '\n')
            f.write(json.dumps(turn('m2', ts(0), inp=2, cread=0)) + '\n')
        self.run_collector()
        self.assertEqual(self.total(), 3)
        self.write('a.jsonl', [turn('m3', ts(0), inp=4, cread=0)], mode='a')
        p = self.run_collector()
        self.assertEqual(self.total(), 7)
        self.assertTrue(p.stdout.startswith('1 new turns'), p.stdout)

    def test_second_run_without_changes_adds_nothing(self) -> None:
        self.write('a.jsonl', [turn('m1', ts(0))])
        self.run_collector()
        p = self.run_collector()
        self.assertTrue(p.stdout.startswith('0 new turns'), p.stdout)
        self.assertEqual(self.total(), 1100)

    def test_shrunk_file_reread_without_double_count(self) -> None:
        path = self.write('a.jsonl', [turn('m1', ts(0)), turn('m2', ts(0))])
        self.run_collector()
        with open(path, 'w') as f:
            f.write(json.dumps(turn('m1', ts(0))) + '\n')
        self.run_collector()
        self.assertEqual(self.total(), 2200)

    # --- durability ---

    def test_history_survives_transcript_deletion(self) -> None:
        path = self.write('old.jsonl', [turn('old', ts(40, 12), inp=500, cread=0)])
        self.run_collector()
        os.remove(path)
        self.write('new.jsonl', [turn('new', ts(0), inp=1, cread=0)])
        self.run_collector()
        self.assertEqual(self.total(), 501)
        self.run_collector('--rebuild')
        self.assertEqual(self.total(), 501, '--rebuild must keep days whose transcripts are gone')

    def test_corrupt_store_falls_back_to_backup(self) -> None:
        self.write('a.jsonl', [turn('m1', ts(0), inp=3, cread=0)])
        self.run_collector()
        self.run_collector()  # creates today's backup from the good store
        with open(os.path.join(self.data, 'store.json'), 'w') as f:
            f.write('{broken')
        p = self.run_collector()
        self.assertIn('continuing with', p.stdout)
        self.assertEqual(self.total(), 3)

    def test_missing_store_with_backups_refuses_to_start_empty(self) -> None:
        self.write('a.jsonl', [turn('m1', ts(0))])
        self.run_collector()
        self.run_collector()
        os.remove(os.path.join(self.data, 'store.json'))
        env = dict(os.environ, TOKENMACCER_DATA_DIR=self.data, TOKENMACCER_CLAUDE_DIR=self.claude)
        p = subprocess.run([sys.executable, '-I', COLLECTOR], env=env, capture_output=True, text=True, check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('backups exist', p.stderr)

    def test_concurrent_run_is_skipped(self) -> None:
        import fcntl

        os.makedirs(self.data)
        with open(os.path.join(self.data, '.lock'), 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            p = self.run_collector()
        self.assertIn('in progress', p.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.data, 'store.json')))

    def test_dated_model_id_uses_base_price(self) -> None:
        self.write('a.jsonl', [turn('m1', ts(0), model='claude-haiku-4-5-20251001', inp=1_000_000, out=0, cread=0)])
        self.run_collector()
        self.assertAlmostEqual(self.widget()['periods']['1D']['usd'], PRICES['claude-haiku-4-5']['input'], places=2)

    def test_bad_timestamp_and_missing_ids(self) -> None:
        bad = turn('b1', ts(0))
        bad['timestamp'] = 12345
        a = turn('x', ts(0), inp=1, cread=0)
        b = turn('y', ts(0), inp=2, cread=0)
        for t in (a, b):
            del t['message']['id']
            del t['requestId']
        self.write('a.jsonl', [bad, a, b, turn('ok', ts(0), inp=4, cread=0)])
        self.run_collector()
        self.assertEqual(self.total(), 7, 'bad line skipped, id-less messages not merged')

    def test_idle_hours_give_no_fake_baseline(self) -> None:
        sys.path.insert(0, os.path.join(ROOT, 'collector'))
        import collector

        row = [1000, 0, 0, 0, 0, 1, 0]
        store = {
            'hours': {'2026-03-10T15': {'claude-sonnet-5-5': row}},
            'days': {'2026-03-10': {'claude-sonnet-5-5': row}},
        }
        totals = collector.daily_totals(store)
        at_nine = dt.datetime(2026, 3, 11, 9, 30)
        self.assertEqual(collector.until_now(store, totals, '2026-03-10', at_nine)['inp'], 0)
        # a day without any hourly values falls back to the pro-rata daily total
        no_hours = {'hours': {}, 'days': store['days']}
        self.assertAlmostEqual(collector.until_now(no_hours, totals, '2026-03-10', at_nine)['inp'], 1000 * 9.5 / 24)

    # --- widget numbers ---

    def test_7d_change_against_previous_window(self) -> None:
        # previous window (days 7..13 ago): 100 per day on two days; current window: 400 on one day
        self.write(
            'a.jsonl',
            [
                turn('p1', ts(8, 12), inp=100, cread=0),
                turn('p2', ts(10, 12), inp=100, cread=0),
                turn('c1', ts(2, 12), inp=400, cread=0),
            ],
        )
        self.run_collector()
        w = self.widget()['periods']['7D']
        self.assertEqual(w['input'], 400)
        self.assertEqual(w['change_input'], 100.0)
        self.assertEqual(len(w['series']), 7)
        self.assertEqual(self.widget()['order'], ['1D', '7D', '30D', 'YTD', '1Y', 'ALL'])

    def test_empty_install_produces_valid_widget_json(self) -> None:
        self.run_collector()
        w = self.widget()
        self.assertEqual(w['periods']['ALL']['input'], 0)
        self.assertIsNone(w['periods']['7D']['change_input'])


if __name__ == '__main__':
    unittest.main()
