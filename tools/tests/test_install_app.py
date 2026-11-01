"""Installer transactions with disposable bundles and simulated macOS process APIs."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).resolve().parents[1] / 'install_app.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.support = self.root / 'support'
        self.staged = self.root / 'staged.app'
        self.target = self.root / 'Applications/App.app'
        self.current = self.root / 'old.app'
        for app, content in [(self.staged, 'new'), (self.current, 'old'), (self.target, 'old')]:
            app.mkdir(parents=True)
            (app / 'content').write_text(content)
        for name, replacement in [('requirement', lambda _: 'pinned'), ('verify', lambda *_, **kwargs: None),
                                  ('info', lambda _: {'AISourceRevision': 'revision'}),
                                  ('alive', lambda _: False), ('stop_app', lambda _: None), ('app_pids', lambda _: [])]:
            mock = patch.object(m, name, replacement)
            mock.start()
            self.addCleanup(mock.stop)

    def run_install(self):
        m.install(self.staged, self.target, self.current, self.support, 999, 'token', True)

    def started(self, *args, **kwargs):
        m.atomic_json(self.support / 'updates/token.ack', {'revision': 'revision', 'pid': 888})

    def test_success_acknowledged_before_success(self):
        with patch.object(m.subprocess, 'run', self.started):
            self.run_install()
        self.assertEqual((self.target / 'content').read_text(), 'new')
        self.assertEqual(json.loads((self.support / 'update.json').read_text())['status'], 'updated')
        self.assertFalse((self.support / 'updates/transaction.json').exists())
        self.assertEqual(json.loads((self.support / 'update.json').read_text())['previous'], 'revision')

    def test_launch_failure_restores_previous(self):
        with patch.object(m.subprocess, 'run', side_effect=RuntimeError('launch failed')):
            with self.assertRaises(RuntimeError):
                self.run_install()
        self.assertEqual((self.target / 'content').read_text(), 'old')
        self.assertEqual(json.loads((self.support / 'update.json').read_text())['status'], 'failed')

    def test_wrong_ack_restores_previous(self):
        def wrong(*args, **kwargs):
            m.atomic_json(self.support / 'updates/token.ack', {'revision': 'wrong'})
        with patch.object(m.subprocess, 'run', wrong):
            with self.assertRaises(ValueError):
                self.run_install()
        self.assertEqual((self.target / 'content').read_text(), 'old')

    def test_signature_failure_does_not_touch_target(self):
        with patch.object(m, 'verify', side_effect=ValueError('wrong identity')):
            with self.assertRaises(ValueError):
                self.run_install()
        self.assertEqual((self.target / 'content').read_text(), 'old')

    def test_first_install_failure_preserves_original(self):
        m.shutil.rmtree(self.target)
        with patch.object(m.subprocess, 'run', side_effect=RuntimeError('launch failed')):
            with self.assertRaises(RuntimeError):
                self.run_install()
        self.assertFalse(self.target.exists())
        self.assertEqual((self.current / 'content').read_text(), 'old')

    def test_cancel_preparation_does_not_touch_running_app(self):
        with patch.object(m, 'alive', return_value=True), patch.object(m.time, 'sleep', side_effect=InterruptedError('cancel')):
            with self.assertRaises(InterruptedError):
                self.run_install()
        self.assertEqual((self.target / 'content').read_text(), 'old')
        self.assertEqual(json.loads((self.support / 'updates/transaction.json').read_text())['phase'], 'failed')

    def test_interrupted_transaction_requires_recovery(self):
        updates = self.support / 'updates'
        updates.mkdir(parents=True)
        m.atomic_json(updates / 'transaction.json', {'phase': 'swapping'})
        with self.assertRaisesRegex(RuntimeError, 'recover'):
            self.run_install()
        self.assertEqual((self.target / 'content').read_text(), 'old')

    def test_recover_swap_from_backup(self):
        updates = self.support / 'updates'
        updates.mkdir(parents=True)
        work = self.target.parent / '.ai-illuminati-install-test'
        work.mkdir()
        self.target.rename(work / 'previous.app')
        m.atomic_json(updates / 'transaction.json', dict(phase='swapping', target=str(self.target),
                      current=str(self.current), work=str(work)))
        with patch.object(m.subprocess, 'run'):
            m.recover(self.support)
        self.assertEqual((self.target / 'content').read_text(), 'old')

    def test_hung_candidate_preserves_backup(self):
        with patch.object(m.subprocess, 'run', side_effect=RuntimeError('launch failed')):
            with patch.object(m, 'stop_app', side_effect=RuntimeError('still running')):
                with self.assertRaises(RuntimeError):
                    self.run_install()
        record = json.loads((self.support / 'updates/transaction.json').read_text())
        self.assertTrue((Path(record['work']) / 'previous.app').exists())


if __name__ == '__main__':
    unittest.main()
