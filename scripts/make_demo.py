#!/usr/bin/env python3
"""Writes made-up Claude Code transcripts for demos and screenshots (no real usage data).

Usage: make_demo.py <claude dir>     e.g. make_demo.py /tmp/demo-claude
Then:  TOKENMACCER_CLAUDE_DIR=/tmp/demo-claude TOKENMACCER_DATA_DIR=/tmp/demo-data python3 collector/collector.py
"""

from __future__ import annotations

import datetime as dt
import json
import math
import os
import random
import sys

MODELS = ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5']


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = os.path.join(sys.argv[1], 'projects', '-demo-project')
    os.makedirs(out, exist_ok=True)
    rng = random.Random(42)
    now = dt.datetime.now().astimezone()
    n = 0
    for days_ago in range(120, -1, -1):
        day = now - dt.timedelta(days=days_ago)
        if day.weekday() >= 5 and rng.random() < 0.6:
            continue
        # slow upward trend with a weekly wave
        level = 1.0 + (120 - days_ago) / 120 + 0.3 * math.sin(days_ago / 3)
        rows = []
        for _ in range(int(rng.randint(20, 60) * level)):
            hour = rng.randint(8, 22)
            t = day.replace(hour=hour, minute=rng.randint(0, 59), second=0, microsecond=0)
            if t > now:
                continue
            n += 1
            w5 = rng.randint(0, 20_000)
            w1h = rng.randint(0, 5_000)
            usage = {
                'input_tokens': rng.randint(5, 500),
                'output_tokens': rng.randint(100, 4_000),
                'cache_read_input_tokens': rng.randint(20_000, 180_000),
                'cache_creation_input_tokens': w5 + w1h,
                'cache_creation': {'ephemeral_5m_input_tokens': w5, 'ephemeral_1h_input_tokens': w1h},
            }
            rows.append(
                {
                    'type': 'assistant',
                    'timestamp': t.astimezone(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'),
                    'requestId': f'req_demo_{n}',
                    'message': {'id': f'msg_demo_{n}', 'model': rng.choice(MODELS), 'usage': usage},
                }
            )
        with open(os.path.join(out, f'session-{days_ago:03d}.jsonl'), 'w') as f:
            for r in rows:
                f.write(json.dumps(r) + '\n')
    print(f'wrote {n} demo turns to {out}')


if __name__ == '__main__':
    main()
