"""State transitions and cleanup must survive usage-parser failures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
REPORTER = Path(os.environ.get('LOOKOUT_TEST_REPORTER', ROOT / 'hooks/lookout-report.py'))


class ReporterFailureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='lookout-usage-failure-')
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.session_id = 'usage-failure-test'
        self.session_file = self.home / 'sessions' / ('codex-' + self.session_id + '.json')
        self.transcript = self.home / 'rollout.jsonl'
        self.transcript.write_text(json.dumps({
            'type': 'event_msg',
            'payload': {'type': 'token_count', 'info': {
                'last_token_usage': {'input_tokens': 'private-transcript-value'}
            }}
        }) + '\n')
        self.report('UserPromptSubmit')
        self.assertEqual(self.record()['state'], 'working')

    def report(self, event):
        payload = {
            'session_id': self.session_id, 'hook_event_name': event,
            'transcript_path': str(self.transcript), 'model': 'test-model',
            'cwd': str(self.home), 'prompt': 'Test usage failures',
            'last_assistant_message': 'Finished the test.'
        }
        result = subprocess.run(
            [sys.executable, str(REPORTER), '--agent', 'codex', '--event', event],
            input=json.dumps(payload), text=True, capture_output=True, timeout=10,
            env={'PATH': os.defpath, 'LOOKOUT_HOME': str(self.home)}
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, '')

    def record(self):
        return json.loads(self.session_file.read_text())

    def history(self):
        return [json.loads(line) for line in (self.home / 'history.jsonl').read_text().splitlines()]

    def assert_safe_log(self):
        log = (self.home / 'reporter.log').read_text()
        self.assertIn('accumulate_usage failed: ValueError', log)
        self.assertNotIn('private-transcript-value', log)
        self.assertNotIn('unhandled exception', log)

    def test_stop_writes_done_and_history_when_usage_parsing_fails(self):
        self.report('Stop')
        self.assertEqual(self.record()['state'], 'done')
        self.assertEqual(self.record()['last_message'], 'Finished the test.')
        self.assertEqual(self.history()[-1]['to'], 'done')
        self.assert_safe_log()

    def test_session_end_cleans_all_session_artifacts_when_usage_parsing_fails(self):
        artifacts = []
        for directory, suffix in [('tokens', '.token'), ('requests', '-r.json'), ('answers', '-r.json')]:
            folder = self.home / directory
            folder.mkdir()
            artifact = folder / ('codex-' + self.session_id + suffix)
            artifact.write_text('{}')
            artifacts.append(artifact)
        self.report('SessionEnd')
        self.assertFalse(self.session_file.exists())
        self.assertFalse(Path(str(self.session_file) + '.lock').exists())
        for artifact in artifacts:
            self.assertFalse(artifact.exists(), str(artifact))
        self.assertEqual(self.history()[-1]['to'], 'ended')
        self.assert_safe_log()


class ReporterBundleTests(unittest.TestCase):
    def test_relocated_reporter_loads_modules_without_changing_bundle_resources(self):
        with tempfile.TemporaryDirectory(prefix='lookout-bundle-test-') as temporary:
            root = Path(temporary)
            hooks = root / 'Lookout.app/Contents/Resources/hooks'
            hooks.mkdir(parents=True)
            shutil.copy2(ROOT / 'hooks/lookout-report.py', hooks / 'lookout-report.py')
            shutil.copytree(ROOT / 'hooks/lookout_reporter', hooks / 'lookout_reporter',
                            ignore=shutil.ignore_patterns('__pycache__'))
            result = subprocess.run(
                [sys.executable, str(hooks / 'lookout-report.py'), '--agent', 'test',
                 '--set', 'done', '--session', 'bundled-session'],
                env={'PATH': os.defpath, 'LOOKOUT_HOME': str(root / 'state')},
                text=True, capture_output=True, timeout=10
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')
            record = json.loads((root / 'state/sessions/test-bundled-session.json').read_text())
            self.assertEqual(record['state'], 'done')
            self.assertEqual(list(hooks.rglob('__pycache__')), [])


class HookConfigurationTests(unittest.TestCase):
    def test_codex_interrupt_has_supported_timeout(self):
        config = json.loads((ROOT / 'hooks/codex-hooks.json').read_text())
        entries = config['hooks']['Interrupt']
        for group in entries:
            for hook in group['hooks']:
                self.assertGreaterEqual(hook['timeout'], 1)
                self.assertLessEqual(hook['timeout'], 3)


if __name__ == '__main__':
    unittest.main()
