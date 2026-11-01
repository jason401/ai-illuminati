#!/usr/bin/env python3
"""Refresh only the app's update-source checkout; keep account and conversation data untouched."""
import argparse
import fcntl
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

REPOSITORY = 'https://github.com/jason401/ai-illuminati.git'


def git(*args):
    return subprocess.check_output(['/usr/bin/git', *map(str, args)], stderr=subprocess.PIPE).decode().strip()


def prepare(support):
    support = Path(support).expanduser().absolute()
    support.mkdir(parents=True, exist_ok=True, mode=0o700)
    source = support / 'source'
    with (support / 'source.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if source.is_symlink():
            raise RuntimeError('Refusing symbolic-link update source.')
        if source.exists():
            if not (source / '.git').exists():
                raise RuntimeError('Existing source is not a Git checkout; leaving it untouched.')
            if git('-C', source, 'remote', 'get-url', 'origin') != REPOSITORY:
                raise RuntimeError('Unexpected update repository; leaving it untouched.')
            if git('-C', source, 'status', '--porcelain', '--untracked-files=normal'):
                raise RuntimeError('Update source has local changes; back them up and resolve them first.')
        temporary = Path(tempfile.mkdtemp(prefix='source-refresh-', dir=support))
        backup = None
        try:
            checkout = temporary / 'checkout'
            git('clone', '--branch', 'stable', '--single-branch', REPOSITORY, checkout)
            if source.exists():
                backups = support / 'migration-backups'
                backups.mkdir(exist_ok=True, mode=0o700)
                backup = backups / ('source-history-' + uuid.uuid4().hex)
                source.rename(backup)
            try:
                checkout.rename(source)
            except Exception:
                if backup and not source.exists():
                    backup.rename(source)
                raise
        finally:
            shutil.rmtree(temporary)
        return backup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--support', type=Path, default=Path.home() / 'Library/Application Support/AI Illuminati')
    args = parser.parse_args()
    backup = prepare(args.support)
    print('Update source refreshed. Accounts, conversations and signing keys were not changed.')
    if backup:
        print('Previous source kept in the local migration-backups folder; never upload it.')


if __name__ == '__main__':
    main()
