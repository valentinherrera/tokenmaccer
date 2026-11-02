#!/usr/bin/env python3
"""Checks the String Catalog (app/Shared/Localizable.xcstrings) for missing German.

  scripts/check_strings.py                      every entry of the catalog has a German translation
  scripts/check_strings.py --derived app/build  and every string the last build found in the Swift sources of the
                                                app, the widget and the collector core is in the catalog

The build writes what it finds to *.stringsdata files (SWIFT_EMIT_LOC_STRINGS in app/project.yml): Text("…"),
String(localized: …), LocalizedStringResource and the like. A string that is shown but missing here would appear
in English on a German Mac. Exit status 1 with a list when something is missing.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Iterable
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / 'app' / 'Shared' / 'Localizable.xcstrings'
# targets whose strings are shown to the user (the tests and the preview renderers are not)
TARGETS = ('TokenMaccer.build', 'TokenMaccerWidget.build', 'TokenMaccerCore.build')


def load(path: Path) -> dict[str, Any]:
    data: dict[str, Any] = json.loads(path.read_text(encoding='utf-8'))
    return data


def _units(localization: dict[str, Any]) -> Iterable[dict[str, Any]]:
    """Every stringUnit of one language, including plural and device variations."""
    if 'stringUnit' in localization:
        yield localization['stringUnit']
    for variants in localization.get('variations', {}).values():
        for variant in variants.values():
            yield from _units(variant)


def missing_german(catalog: dict[str, Any]) -> list[str]:
    """Keys without a translated, non-empty German value (keys marked shouldTranslate false are skipped)."""
    missing = []
    for key, entry in catalog.get('strings', {}).items():
        if entry.get('shouldTranslate') is False:
            continue
        de = entry.get('localizations', {}).get('de')
        units = list(_units(de)) if de else []
        if not units or any(u.get('state') != 'translated' or not u.get('value', '').strip() for u in units):
            missing.append(key)
    return sorted(missing)


def _target(path: Path) -> str | None:
    """The target folder of a build product: Intermediates.noindex/<project>.build/<config>/<target>.build/…
    (the project folder is called TokenMaccer.build too, so only the second .build counts)."""
    builds = [part for part in path.parts if part.endswith('.build')]
    return builds[1] if len(builds) > 1 else None


def extracted_keys(derived: Path) -> set[str]:
    """Keys of the default table in the build's .stringsdata files of the shown targets."""
    keys: set[str] = set()
    for path in derived.rglob('*.stringsdata'):
        if _target(path) not in TARGETS:
            continue
        tables = load(path).get('tables', {})
        for table, entries in tables.items():
            if table != 'Localizable':
                continue
            for entry in entries:
                keys.add(entry['key'])
    return keys


def missing_in_catalog(catalog: dict[str, Any], keys: set[str]) -> list[str]:
    return sorted(keys - set(catalog.get('strings', {})))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--catalog', type=Path, default=CATALOG)
    parser.add_argument('--derived', type=Path, action='append', default=[], help='derived data folder of a build')
    args = parser.parse_args(argv)
    catalog = load(args.catalog)
    failed = False
    german = missing_german(catalog)
    if german:
        failed = True
        print(f'{len(german)} catalog entries without German:')
        for key in german:
            print(f'  {key!r}')
    for derived in args.derived:
        keys = extracted_keys(derived)
        if not keys:
            print(f'{derived}: no .stringsdata found (build with SWIFT_EMIT_LOC_STRINGS=YES first)')
            failed = True
            continue
        absent = missing_in_catalog(catalog, keys)
        if absent:
            failed = True
            print(f'{len(absent)} strings from the sources are not in the catalog ({derived}):')
            for key in absent:
                print(f'  {key!r}')
        else:
            print(f'ok  {len(keys)} strings from the sources, all in the catalog ({derived})')
    if not failed:
        print(f'ok  {len(catalog.get("strings", {}))} catalog entries, all with German')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
