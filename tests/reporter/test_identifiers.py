"""Reject path/glob identifiers without touching files outside an isolated state directory."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'hooks'))
from lookout_reporter.common import is_valid_file_id
from lookout_reporter.storage import session_file_path, token_file_path
from lookout_reporter.requests import request_file_path, answer_file_path


class IdentifierTests(unittest.TestCase):
    def test_safe_ids_and_path_builders(self):
        for value in ('my-task-1', 'abc_DEF.123', 'a' * 160):
            self.assertTrue(is_valid_file_id(value))
        for value in ('', '.', '..', '../escape', 'a/b', 'a\\b', '*', '[a]', 'a\n', 'a' * 161, None):
            self.assertFalse(is_valid_file_id(value))
            for function in (session_file_path, token_file_path):
                with self.assertRaises(ValueError):
                    function('/unused', 'test', value)
            for function in (request_file_path, answer_file_path):
                with self.assertRaises(ValueError):
                    function('/unused', 'test', 'session', value)

    def test_invalid_hook_and_manual_input_never_creates_session_or_leaks_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / 'state'
            sentinel = Path(temporary) / 'keep.json'
            sentinel.write_text('unchanged')
            for identifier in ('../keep', 'x/../../keep', '*', 'private-id\nvalue'):
                for arguments, payload in (
                    (['--event', 'Stop'], {'session_id': identifier}),
                    (['--set', 'done', '--session', identifier], None),
                    (['--end', '--session', identifier], None),
                ):
                    result = subprocess.run(
                        [sys.executable, str(ROOT / 'hooks/lookout-report.py'), '--agent', 'test'] + arguments,
                        input=json.dumps(payload) if payload else '', text=True, capture_output=True,
                        env={'PATH': os.defpath, 'LOOKOUT_HOME': str(home)}, timeout=10,
                    )
                    self.assertEqual(result.returncode, 0)
                    self.assertEqual(result.stdout + result.stderr, '')
                    self.assertEqual(sentinel.read_text(), 'unchanged')
                    self.assertFalse((home / 'sessions').exists())
                    self.assertNotIn(identifier, (home / 'reporter.log').read_text())
