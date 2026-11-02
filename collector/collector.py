#!/usr/bin/env python3
"""TokenMaccer collector.

Reads Claude Code transcripts (~/.claude/projects/**/*.jsonl) incrementally, keeps daily totals
in store.json (they survive Claude Code's transcript cleanup) and writes widget.json for the widget.

Usage: collector.py              incremental run (what launchd calls every 5 minutes)
       collector.py --rebuild    re-read everything; days whose transcripts are gone are kept
                                 from the existing store (a daily backup is taken first)

Environment overrides (mainly for tests):
  TOKENMACCER_DATA_DIR       where store.json / widget.json live (default ~/.claude/tools/tokenmaccer)
  TOKENMACCER_CLAUDE_DIR     Claude Code config dir (default $CLAUDE_CONFIG_DIR or ~/.claude)
  TOKENMACCER_EXTRA_SOURCES  extra transcript folders, separated by ':'
  TOKENMACCER_NOW            pin the current local time (ISO 8601), for tests and the Swift parity check
"""

from __future__ import annotations

import datetime as dt
import fcntl
import glob
import json
import os
import re
import shutil
import sys
import tempfile
import time
from typing import Any, Dict, Iterator, List, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.expanduser(os.environ.get('TOKENMACCER_DATA_DIR', '~/.claude/tools/tokenmaccer'))
CLAUDE_DIR = os.path.expanduser(
    os.environ.get('TOKENMACCER_CLAUDE_DIR') or os.environ.get('CLAUDE_CONFIG_DIR') or '~/.claude'
)
SOURCES = [os.path.join(CLAUDE_DIR, 'projects')] + [
    os.path.expanduser(p) for p in os.environ.get('TOKENMACCER_EXTRA_SOURCES', '').split(':') if p
]
STORE = os.path.join(DATA_DIR, 'store.json')
WIDGET = os.path.join(DATA_DIR, 'widget.json')
BACKUPS = os.path.join(DATA_DIR, 'backups')
SEEN_DAYS = 60  # how long message ids are kept for de-duplication
HOUR_DAYS = 32  # hourly values: today's curve and a fair same-time comparison for 7D/30D
KEEP_BACKUPS = 14  # daily store backups to keep
# Fields per day and model
FIELDS = ['input', 'output', 'cache_read', 'write_5m', 'write_1h', 'turns', 'subagent_input']
PERIODS = ['1D', '7D', '30D', 'YTD', '1Y', 'ALL']

Store = Dict[str, Any]
Sums = Dict[str, float]


def now_local() -> dt.datetime:
    """Current local time (naive). TOKENMACCER_NOW pins it; an offset or Z is converted to local time."""
    pinned = os.environ.get('TOKENMACCER_NOW')
    if not pinned:
        return dt.datetime.now()
    t = dt.datetime.fromisoformat(pinned.replace('Z', '+00:00'))
    return t.astimezone().replace(tzinfo=None) if t.tzinfo else t


def load_prices() -> Dict[str, Dict[str, float]]:
    with open(os.path.join(HERE, 'prices.json')) as f:
        return {k: v for k, v in json.load(f).items() if not k.startswith('_') or k == '_fallback'}


PRICES = load_prices()


def price(model: str) -> Dict[str, float]:
    """Exact id, then without a date suffix (claude-haiku-4-5-20251001), then the longest known prefix."""
    if model in PRICES:
        return PRICES[model]
    base = re.sub(r'-\d{8}$', '', model)
    if base in PRICES:
        return PRICES[base]
    known = [k for k in PRICES if not k.startswith('_') and base.startswith(k + '-')]
    return PRICES[max(known, key=len)] if known else PRICES['_fallback']


def usd(model: str, v: List[int]) -> float:
    p = price(model)
    return (
        v[0] * p['input'] + v[1] * p['output'] + v[2] * p['cache_read'] + v[3] * p['write_5m'] + v[4] * p['write_1h']
    ) / 1e6


def total_input(v: List[int]) -> int:
    """Everything the model read: uncached input + cache reads + cache writes."""
    return v[0] + v[2] + v[3] + v[4]


def file_key(path: str, base: str) -> str:
    return os.path.relpath(path, base).replace('/', '__')


def empty() -> Store:
    return {'version': 1, 'files': {}, 'seen': {}, 'days': {}, 'hours': {}}


def load() -> Store:
    """Load the store. A corrupt store is set aside and the newest readable backup is used.
    If the store is missing but backups exist, stop instead of silently starting from zero."""
    if not os.path.exists(STORE):
        if glob.glob(os.path.join(BACKUPS, 'store-*.json')):
            sys.exit('store.json is missing but backups exist: restore one from backups/ instead of starting empty.')
        return empty()
    try:
        with open(STORE) as f:
            data: Store = json.load(f)
            return data
    except Exception as e:
        broken = STORE + time.strftime('.broken-%Y%m%d-%H%M%S')
        os.replace(STORE, broken)
        for b in sorted(glob.glob(os.path.join(BACKUPS, 'store-*.json')), reverse=True):
            try:
                with open(b) as f:
                    data = json.load(f)
                print(f'store.json unreadable ({e}), moved to {broken}; continuing with {b}')
                return data
            except Exception:
                continue
        sys.exit(f'store.json unreadable ({e}) and no readable backup; moved to {broken}')


def backup() -> None:
    """One copy of the store per day; the last KEEP_BACKUPS are kept."""
    if not os.path.exists(STORE):
        return
    os.makedirs(BACKUPS, exist_ok=True)
    target = os.path.join(BACKUPS, f'store-{now_local().date().isoformat()}.json')
    if not os.path.exists(target):
        shutil.copy2(STORE, target)
    for old in sorted(glob.glob(os.path.join(BACKUPS, 'store-*.json')))[:-KEEP_BACKUPS]:
        os.remove(old)


def save_atomic(path: str, data: Any) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, separators=(',', ':'))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def local(ts: str) -> Tuple[str, str]:
    # Transcript timestamps are UTC (...Z); days are counted in local time
    t = dt.datetime.fromisoformat(ts.replace('Z', '+00:00')).astimezone()
    return t.strftime('%Y-%m-%d'), t.strftime('%Y-%m-%dT%H')


def add(table: Dict[str, Dict[str, List[int]]], key: str, model: str, v: List[int]) -> None:
    row = table.setdefault(key, {}).setdefault(model, [0] * len(FIELDS))
    for i, x in enumerate(v):
        row[i] += x


def complete_lines(path: str, pos: List[int]) -> Iterator[bytes]:
    """Yields only complete lines from pos[0] on, one at a time (constant memory); pos[0] advances."""
    try:
        f = open(path, 'rb')
    except OSError:
        return  # unreadable or just moved: next run
    with f:
        f.seek(pos[0])
        for line in f:
            if not line.endswith(b'\n'):
                return  # half-written last line: next run
            pos[0] += len(line)
            yield line


def ingest(store: Store) -> int:
    today = now_local().date()
    hour_cutoff = (today - dt.timedelta(days=HOUR_DAYS)).isoformat()
    new_turns = 0
    for base in SOURCES:
        for dirpath, _dirs, files in os.walk(base, followlinks=True):
            for name in files:
                if not name.endswith('.jsonl'):
                    continue
                path = os.path.join(dirpath, name)
                key = file_key(path, base)
                is_sub = '/subagents/' in key.replace('__', '/')
                try:
                    size = os.path.getsize(path)
                except OSError:
                    continue
                offset = store['files'].get(key, 0)
                if offset > size:  # file was rewritten: start over, `seen` catches duplicates
                    offset = 0
                if offset == size:
                    continue
                pos = [offset]
                for line in complete_lines(path, pos):
                    if b'"usage"' not in line:
                        continue
                    try:
                        d = json.loads(line)
                    except Exception:
                        continue
                    if d.get('type') != 'assistant':
                        continue
                    m = d.get('message') or {}
                    u = m.get('usage') if isinstance(m, dict) else None
                    if not u or not d.get('timestamp'):
                        continue
                    model = m.get('model') or '?'
                    if model == '<synthetic>':
                        continue
                    try:
                        day, hour = local(d['timestamp'])
                    except (TypeError, ValueError, AttributeError):
                        continue
                    if m.get('id') or d.get('requestId'):
                        k = f'{m.get("id")}|{d.get("requestId")}'
                        if k in store['seen']:
                            continue
                        store['seen'][k] = day
                    cc = u.get('cache_creation') or {}
                    w_total = u.get('cache_creation_input_tokens') or 0
                    w1h = cc.get('ephemeral_1h_input_tokens') or 0
                    w5 = cc.get('ephemeral_5m_input_tokens')
                    if w5 is None:
                        w5 = max(w_total - w1h, 0)
                    raw = u.get('input_tokens') or 0
                    cr = u.get('cache_read_input_tokens') or 0
                    v = [raw, u.get('output_tokens') or 0, cr, w5, w1h, 1, (raw + cr + w5 + w1h) if is_sub else 0]
                    add(store['days'], day, model, v)
                    if day >= hour_cutoff:
                        add(store['hours'], hour, model, v)
                    new_turns += 1
                store['files'][key] = pos[0]
    seen_cutoff = (today - dt.timedelta(days=SEEN_DAYS)).isoformat()
    store['seen'] = {k: t for k, t in store['seen'].items() if t >= seen_cutoff}
    store['hours'] = {k: v for k, v in store['hours'].items() if k[:10] >= hour_cutoff}
    return new_turns


# ---------- aggregation for the widget ----------


def zero() -> Sums:
    return {'inp': 0, 'out': 0, 'usd': 0.0}


def daily_totals(store: Store) -> Dict[str, Sums]:
    result: Dict[str, Sums] = {}
    for day, models in store['days'].items():
        z = result.setdefault(day, zero())
        for m, v in models.items():
            z['inp'] += total_input(v)
            z['out'] += v[1]
            z['usd'] += usd(m, v)
    return result


def range_sum(totals: Dict[str, Sums], start: dt.date, end: dt.date) -> Sums:
    s = zero()
    d = start
    while d <= end:
        z = totals.get(d.isoformat())
        if z:
            for k in s:
                s[k] += z[k]
        d += dt.timedelta(days=1)
    return s


def change(now: float, before: float) -> float | None:
    if not before:
        return None
    return round((now - before) / before * 100, 1)


def until_now(store: Store, totals: Dict[str, Sums], day: str, now: dt.datetime) -> Sums:
    """Usage of an earlier day from midnight up to the current time of day (current hour pro rata).
    Only if that day has no hourly values at all: the daily total pro rata by elapsed time of day."""
    frac = now.minute / 60
    s = zero()
    has_hours = any(k.startswith(day + 'T') for k in store['hours'])
    for h in range(now.hour + 1):
        f = frac if h == now.hour else 1.0
        for m, v in store['hours'].get(f'{day}T{h:02d}', {}).items():
            s['inp'] += total_input(v) * f
            s['out'] += v[1] * f
            s['usd'] += usd(m, v) * f
    if not has_hours and day in totals:
        f = (now.hour + frac) / 24
        s = {k: totals[day][k] * f for k in s}
    return s


def add_sums(a: Sums, b: Sums) -> Sums:
    return {k: a[k] + b[k] for k in a}


def or_none(s: Sums) -> Sums | None:
    return s if s['inp'] else None


def cumulative(values: List[Sums]) -> List[Dict[str, Any]]:
    """Running total, starting with 0 at the beginning of the period (like a price line that starts at the open)."""
    points: List[Dict[str, Any]] = [{'input': 0, 'usd': 0.0}]
    run = zero()
    for v in values:
        run = add_sums(run, v)
        points.append({'input': round(run['inp']), 'usd': round(run['usd'], 2)})
    return points


def day_values(totals: Dict[str, Sums], start: dt.date, days: int) -> List[Sums]:
    return [dict(totals.get((start + dt.timedelta(days=i)).isoformat()) or zero()) for i in range(days)]


def hour_values(store: Store, totals: Dict[str, Sums], day: str, hours: int) -> List[Sums]:
    """Usage per hour of a day; a day without hourly values is spread evenly over 24 hours."""
    if not any(k.startswith(day + 'T') for k in store['hours']):
        z = totals.get(day) or zero()
        return [{k: z[k] / 24 for k in z} for _ in range(hours)]
    values = []
    for h in range(hours):
        z = zero()
        for m, v in store['hours'].get(f'{day}T{h:02d}', {}).items():
            z['inp'] += total_input(v)
            z['out'] += v[1]
            z['usd'] += usd(m, v)
        values.append(z)
    return values


def ghost(values: List[Sums], at: int, baseline: Sums | None) -> List[Dict[str, Any]] | None:
    """Running total of the previous period. At index `at` (now) it carries exactly the value the change
    is computed against, so line end vs. dotted line at the same x is what the pill says."""
    if baseline is None:
        return None
    points = cumulative(values)
    points[at] = {'input': round(baseline['inp']), 'usd': round(baseline['usd'], 2)}
    return points


def metric(
    s: Sums,
    previous: Sums | None,
    series: List[Dict[str, Any]],
    prev_series: List[Dict[str, Any]] | None,
    slots: int,
    start: str,
    end: str,
) -> Dict[str, Any]:
    return {
        'input': round(s['inp']),
        'output': round(s['out']),
        'usd': round(s['usd'], 2),
        'ratio': round(s['inp'] / s['out']) if s['out'] else None,
        'change_input': change(s['inp'], previous['inp']) if previous else None,
        'change_usd': change(s['usd'], previous['usd']) if previous else None,
        'series': series,
        'previous': prev_series,
        'slots': slots,
        'from': start,
        'to': end,
    }


def widget_data(store: Store, now: dt.datetime | None = None) -> Dict[str, Any]:
    """Every period is drawn like a stock chart: the line is the running total and ends at the headline,
    the dotted line is the running total of the previous period, the x axis covers the whole period."""
    now = now or now_local()
    today = now.date()
    totals = daily_totals(store)
    days = sorted(totals)
    first = dt.date.fromisoformat(days[0]) if days else today
    r: Dict[str, Any] = {}

    # 1D: hours 0-24; today so far vs. yesterday up to the same time of day
    yesterday = (today - dt.timedelta(days=1)).isoformat()
    cur = hour_values(store, totals, today.isoformat(), now.hour + 1)
    s = range_sum(totals, today, today)
    prev = or_none(until_now(store, totals, yesterday, now))
    r['1D'] = metric(
        s,
        prev,
        cumulative(cur),
        ghost(hour_values(store, totals, yesterday, 24), now.hour + 1, prev),
        25,
        today.isoformat(),
        today.isoformat(),
    )

    # 7D/30D: n days, today so far vs. the same window n days earlier up to the same time of day
    for name, n in (('7D', 7), ('30D', 30)):
        start = today - dt.timedelta(days=n - 1)
        s = range_sum(totals, start, today)
        prev = or_none(
            add_sums(
                range_sum(totals, start - dt.timedelta(days=n), today - dt.timedelta(days=n + 1)),
                until_now(store, totals, (today - dt.timedelta(days=n)).isoformat(), now),
            )
        )
        r[name] = metric(
            s,
            prev,
            cumulative(day_values(totals, start, n)),
            ghost(day_values(totals, start - dt.timedelta(days=n), n), n, prev),
            n + 1,
            start.isoformat(),
            today.isoformat(),
        )

    # YTD: axis Jan 1 - Dec 31, compared with last year up to the same date
    jan1 = dt.date(today.year, 1, 1)
    year_days = (dt.date(today.year + 1, 1, 1) - jan1).days
    elapsed = (today - jan1).days + 1
    try:
        ly_end = today.replace(year=today.year - 1)
    except ValueError:  # Feb 29
        ly_end = today.replace(year=today.year - 1, day=28)
    ly_jan1 = dt.date(today.year - 1, 1, 1)
    prev = or_none(range_sum(totals, ly_jan1, ly_end))
    ly_days = (jan1 - ly_jan1).days
    r['YTD'] = metric(
        range_sum(totals, jan1, today),
        prev,
        cumulative(day_values(totals, jan1, elapsed)),
        ghost(day_values(totals, ly_jan1, ly_days), min(elapsed, ly_days), prev),
        year_days + 1,
        jan1.isoformat(),
        today.isoformat(),
    )

    # 1Y: the last 365 days vs. the 365 days before
    y_start = today - dt.timedelta(days=364)
    p_start = y_start - dt.timedelta(days=365)
    prev = or_none(range_sum(totals, p_start, y_start - dt.timedelta(days=1)))
    r['1Y'] = metric(
        range_sum(totals, y_start, today),
        prev,
        cumulative(day_values(totals, y_start, 365)),
        ghost(day_values(totals, p_start, 365), 365, prev),
        366,
        y_start.isoformat(),
        today.isoformat(),
    )

    # ALL: since the first recorded day, nothing to compare with
    n_all = (today - first).days + 1
    r['ALL'] = metric(
        range_sum(totals, first, today),
        None,
        cumulative(day_values(totals, first, n_all)),
        None,
        n_all + 1,
        first.isoformat(),
        today.isoformat(),
    )
    return {'updated': now.astimezone().isoformat(timespec='seconds'), 'periods': r, 'order': PERIODS}


def rebuild(old: Store) -> Tuple[Store, int]:
    """Re-read everything without losing history: per day the version with more input wins,
    so days whose transcripts are gone come from the old store."""
    new = empty()
    n = ingest(new)
    for day, models in old.get('days', {}).items():
        old_sum = sum(total_input(v) for v in models.values())
        new_sum = sum(total_input(v) for v in new['days'].get(day, {}).values())
        if old_sum > new_sum:
            new['days'][day] = models
    return new, n


def main() -> None:
    t0 = time.time()
    os.makedirs(DATA_DIR, exist_ok=True)
    lock = open(os.path.join(DATA_DIR, '.lock'), 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('another collector run is in progress; skipping')
        return
    store = load()
    backup()
    if '--rebuild' in sys.argv:
        store, n = rebuild(store)
    else:
        n = ingest(store)
    # Write the store only when something changed: the job runs every 5 minutes, mostly with nothing new
    if n or '--rebuild' in sys.argv or not os.path.exists(STORE):
        save_atomic(STORE, store)
    w = widget_data(store)
    save_atomic(WIDGET, w)
    print(f'{n} new turns · {time.time() - t0:.1f} s · updated {w["updated"]}')


if __name__ == '__main__':
    main()
