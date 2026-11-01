"""Offline source-cache migration tests; no real accounts, network or installed app."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare_source', Path(__file__).resolve().parents[1] / 'prepare_update_source.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def git(*args):
    return subprocess.check_output(['/usr/bin/git', *map(str, args)], stderr=subprocess.PIPE).decode().strip()


class SourceRefreshTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.remote = root / 'remote'
        git('init', '-b', 'stable', self.remote)
        (self.remote / 'README.md').write_text('public source\n')
        git('-C', self.remote, 'add', 'README.md')
        git('-C', self.remote, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'fixture')
        self.support = root / 'support'
        self.support.mkdir()
        self.data = self.support / 'accounts.json'
        self.data.write_text('fixture account marker')
        self.patch = patch.object(m, 'REPOSITORY', str(self.remote))
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def test_initial_checkout_and_data_preservation(self):
        self.assertIsNone(m.prepare(self.support))
        self.assertEqual(git('-C', self.support / 'source', 'rev-parse', 'HEAD'), git('-C', self.remote, 'rev-parse', 'HEAD'))
        self.assertEqual(self.data.read_text(), 'fixture account marker')

    def test_old_source_is_backed_up_and_new_checkout_has_no_old_history(self):
        source = self.support / 'source'
        git('init', '-b', 'stable', source)
        git('-C', source, 'remote', 'add', 'origin', self.remote)
        (source / 'old-notes.txt').write_text('old fixture notes')
        git('-C', source, 'add', '.')
        git('-C', source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'old')
        old = git('-C', source, 'rev-parse', 'HEAD')
        backup = m.prepare(self.support)
        self.assertTrue((backup / 'old-notes.txt').exists())
        self.assertFalse((source / 'old-notes.txt').exists())
        result = subprocess.run(['/usr/bin/git', '-C', str(source), 'cat-file', '-e', old + '^{commit}'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.data.read_text(), 'fixture account marker')

    def test_dirty_or_symlink_source_is_not_overwritten(self):
        m.prepare(self.support)
        source = self.support / 'source'
        (source / 'local.txt').write_text('keep')
        with self.assertRaises(RuntimeError):
            m.prepare(self.support)
        self.assertEqual((source / 'local.txt').read_text(), 'keep')
        other = self.support / 'other'
        source.rename(other)
        source.symlink_to(other, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            m.prepare(self.support)
        self.assertTrue((other / 'local.txt').exists())


if __name__ == '__main__':
    unittest.main()
