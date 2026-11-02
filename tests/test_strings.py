"""German in the String Catalog: scripts/check_strings.py on the real catalog and on made-up builds."""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from typing import Any, Dict

ROOT = Path(__file__).resolve().parent.parent


def _load() -> ModuleType:
    spec = importlib.util.spec_from_file_location('check_strings', ROOT / 'scripts' / 'check_strings.py')
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


check = _load()


def translated(value: str) -> Dict[str, Any]:
    return {'localizations': {'de': {'stringUnit': {'state': 'translated', 'value': value}}}}


class CatalogTests(unittest.TestCase):
    def test_real_catalog_has_german_for_every_entry(self) -> None:
        catalog = check.load(check.CATALOG)
        self.assertGreater(len(catalog['strings']), 100)
        self.assertEqual(check.missing_german(catalog), [])

    def test_finds_missing_untranslated_and_empty_german(self) -> None:
        catalog = {
            'strings': {
                'Done': translated('Fertig'),
                'Empty entry': {},
                'English only': {'localizations': {'en': {'stringUnit': {'state': 'translated', 'value': 'x'}}}},
                'Needs review': {'localizations': {'de': {'stringUnit': {'state': 'needs_review', 'value': 'y'}}}},
                'Blank': translated('  '),
                't': {'shouldTranslate': False},
                '%lld places': {
                    'localizations': {
                        'de': {
                            'variations': {
                                'plural': {
                                    'one': {'stringUnit': {'state': 'translated', 'value': '%lld Platz'}},
                                    'other': {'stringUnit': {'state': 'new', 'value': ''}},
                                }
                            }
                        }
                    }
                },
            }
        }
        self.assertEqual(
            check.missing_german(catalog), ['%lld places', 'Blank', 'Empty entry', 'English only', 'Needs review']
        )

    def test_compares_build_strings_with_catalog(self) -> None:
        catalog = {'strings': {'Done': translated('Fertig')}}
        with tempfile.TemporaryDirectory() as tmp:
            for target, keys in [
                ('TokenMaccer.build', ['Done', 'Leave…']),
                ('TokenMaccerWidget.build', ['Waiting for the first numbers']),
                ('TokenMaccerCoreTests.build', ['only in a test']),
            ]:
                folder = Path(tmp, 'Build', 'Intermediates.noindex', 'TokenMaccer.build', 'Debug', target, 'Objects')
                os.makedirs(folder)
                data = {'version': 1, 'tables': {'Localizable': [{'key': k, 'comment': ''} for k in keys]}}
                (folder / 'View.stringsdata').write_text(json.dumps(data), encoding='utf-8')
            keys = check.extracted_keys(Path(tmp))
            self.assertEqual(keys, {'Done', 'Leave…', 'Waiting for the first numbers'})
            self.assertEqual(check.missing_in_catalog(catalog, keys), ['Leave…', 'Waiting for the first numbers'])


if __name__ == '__main__':
    unittest.main()
