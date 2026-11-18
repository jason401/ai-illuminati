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
real_stop_app = m.stop_app


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

    def test_remote_install_waits_longer_and_records_it(self):
        records = []
        def started(*args, **kwargs):
            records.append(json.loads((self.support / 'updates/transaction.json').read_text()))
            self.started()
        with patch.object(m.subprocess, 'run', started):
            m.install(self.staged, self.target, self.current, self.support, 999, 'token', False, remote=True)
        self.assertTrue(records[0]['remote'])
        self.assertEqual(records[0]['ackSeconds'], m.REMOTE_ACK_SECONDS)
        self.assertGreater(m.REMOTE_ACK_SECONDS, m.ACK_SECONDS)
        state = json.loads((self.support / 'update.json').read_text())
        self.assertEqual((state['lastResult'], state['lastRemote']), ('installed', '1'))
        self.assertTrue(all(isinstance(value, str) for value in state.values()))

    def test_remote_install_without_ack_rolls_back(self):
        # The new app never writes the ack (its phone page did not come up): the old app comes back.
        opened = []
        (self.support / 'updates').mkdir(parents=True)
        (self.support / 'updates/install.log').write_text('starting\nlast line here\n')
        with patch.object(m, 'REMOTE_ACK_SECONDS', 0.3), patch.object(m.subprocess, 'run', lambda args, **kw: opened.append(args)):
            with self.assertRaisesRegex(TimeoutError, 'phone page'):
                m.install(self.staged, self.target, self.current, self.support, 999, 'token', False, remote=True)
        self.assertEqual((self.target / 'content').read_text(), 'old')
        self.assertEqual(opened[-1], ['/usr/bin/open', '-n', str(self.current)])
        state = json.loads((self.support / 'update.json').read_text())
        self.assertEqual((state['status'], state['lastResult'], state['lastRemote']), ('failed', 'rolled-back', '1'))
        self.assertEqual(state['lastLog'], 'last line here')
        self.assertTrue(all(isinstance(value, str) for value in state.values()))
        self.assertEqual(json.loads((self.support / 'updates/transaction.json').read_text())['phase'], 'failed')

    def test_first_install_failure_is_not_a_rollback(self):
        m.shutil.rmtree(self.target)
        with patch.object(m.subprocess, 'run', side_effect=RuntimeError('launch failed')):
            with self.assertRaises(RuntimeError):
                self.run_install()
        self.assertEqual(json.loads((self.support / 'update.json').read_text())['lastResult'], 'failed')
    def test_hung_candidate_ignoring_sigterm_is_killed_then_restored(self):
        # The new app hangs and ignores SIGTERM: SIGKILL ends it, the old app is put back and opened again.
        sent, alive = [], {'pids': [4242]}
        def kill(pid, sig):
            sent.append(sig)
            if sig == m.signal.SIGKILL:
                alive['pids'] = []
        opened = []
        with patch.object(m, 'stop_app', real_stop_app), patch.object(m, 'app_pids', lambda _: list(alive['pids'])), \
                patch.object(m.os, 'kill', kill), patch.object(m, 'ACK_SECONDS', 0.2), \
                patch.object(m.time, 'sleep', lambda _: None), \
                patch.object(m.subprocess, 'run', lambda args, **kw: opened.append(args)):
            clock = iter(range(0, 10**6, 1))
            with patch.object(m.time, 'monotonic', lambda: next(clock) * 0.5):
                with self.assertRaises(TimeoutError):
                    self.run_install()
        self.assertEqual(sent, [m.signal.SIGTERM, m.signal.SIGKILL])
        self.assertEqual((self.target / 'content').read_text(), 'old')
        self.assertEqual(opened[-1], ['/usr/bin/open', '-n', str(self.current)])
        self.assertEqual(json.loads((self.support / 'update.json').read_text())['lastResult'], 'rolled-back')

    def test_success_clears_last_log(self):
        with patch.object(m.subprocess, 'run', self.started):
            self.run_install()
        self.assertEqual(json.loads((self.support / 'update.json').read_text())['lastLog'], '')


if __name__ == '__main__':
    unittest.main()
