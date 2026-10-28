#!/usr/bin/python3
"""Install a locally signed build. Runs detached; never reads account credentials."""
import argparse
import ctypes
import signal
import datetime
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time


def atomic_json(path, value):
    path = Path(path)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, indent=2))
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def info(app):
    with (Path(app) / 'Contents/Info.plist').open('rb') as stream:
        return plistlib.load(stream)


def requirement(app):
    result = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(app)],
                            capture_output=True, text=True, check=True)
    return next(line.split('designated => ', 1)[1]
                for line in (result.stdout + result.stderr).splitlines()
                if 'designated => ' in line)


def verify(app, expected, resources=True):
    if info(app).get('CFBundleIdentifier') != 'local.aiilluminati':
        raise ValueError('Unexpected bundle identifier')
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + expected,
                    str(app)], check=True, capture_output=True)
    for resource in (['workspace_mcp.py', 'WorkspaceDocument', 'install_app.py', 'InstallBridge'] if resources else []):
        if not (Path(app) / 'Contents/Resources' / resource).is_file():
            raise ValueError('Missing bundled resource: ' + resource)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def app_pids(app):
    """Read executable paths, not command-line substring matches."""
    library = ctypes.CDLL('/usr/lib/libproc.dylib')
    executable = str(Path(app) / 'Contents/MacOS/AIIlluminati')
    pids = subprocess.check_output(['/bin/ps', '-axo', 'pid='], text=True)
    found = []
    for value in pids.split():
        pid = int(value)
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(pid, buffer, len(buffer)) > 0:
            if os.fsdecode(buffer.value) == executable:
                found.append(pid)
    return found


def stop_app(app):
    for pid in app_pids(app):
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 10
    while app_pids(app):
        if time.monotonic() > deadline:
            raise RuntimeError('New app still running; backup preserved')
        time.sleep(0.1)


def recover(support):
    """Explicit repair after interrupted installation; never remove the previous build."""
    updates = support / 'updates'
    with (updates / 'install.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        journal = updates / 'transaction.json'
        record = json.loads(journal.read_text())
        target, current, work = (Path(record[key]) for key in ['target', 'current', 'work'])
        if work.parent != target.parent or not work.name.startswith('.ai-illuminati-install-'):
            raise ValueError('Invalid recovery path')
        if record['phase'] == 'complete':
            if work.exists():
                shutil.rmtree(work)
        elif record['phase'] != 'failed':
            if record['phase'] != 'prepared':
                stop_app(target)
            backup = work / 'previous.app'
            if backup.exists():
                if target.exists():
                    shutil.rmtree(target)
                os.replace(backup, target)
            record['phase'] = 'failed'
            record['detail'] = 'Recovered an interrupted installation'
            atomic_json(journal, record)
            if not app_pids(current):
                subprocess.run(['/usr/bin/open', '-n', str(current)], check=False, cwd='/')
        return record


def install(staged, target, current, support, parent_pid, token, restore_login, quit_parent=False):
    support.mkdir(parents=True, exist_ok=True, mode=0o700)
    updates = support / 'updates'
    updates.mkdir(exist_ok=True, mode=0o700)
    with (updates / 'install.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        journal = updates / 'transaction.json'
        if journal.exists():
            previous = json.loads(journal.read_text())
            if previous.get('phase') not in ['failed', 'complete']:
                raise RuntimeError('Interrupted installation found. Run install_app.py --recover first.')
        expected = requirement(current)
        # Pin to the running app's designated requirement, never just a valid signature.
        verify(current, expected, resources=False)
        verify(staged, expected)
        revision = info(staged)['AISourceRevision']
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink():
            raise ValueError('Refusing symbolic link install target')
        if target.exists():
            verify(target, expected, resources=False)
        # Copy to the destination volume before asking the old process to quit.
        work = Path(tempfile.mkdtemp(prefix='.ai-illuminati-install-', dir=target.parent))
        os.chmod(work, 0o700)
        prepared, backup = work / target.name, work / 'previous.app'
        journal = updates / 'transaction.json'
        ready, ack = updates / (token + '.ready'), updates / (token + '.ack')
        had_target = target.exists()
        record = dict(token=token, target=str(target), current=str(current),
                      work=str(work), revision=revision, restoreLogin=restore_login,
                      parentPID=parent_pid, phase='prepared')
        replaced = False
        try:
            shutil.copytree(staged, prepared, symlinks=True)
            verify(prepared, expected)
            atomic_json(journal, record)
            ready.touch(mode=0o600)
            if quit_parent:
                subprocess.run([str(staged / 'Contents/Resources/InstallBridge'), str(parent_pid), str(current)], check=True)
            deadline = time.monotonic() + 90
            while alive(parent_pid):
                if time.monotonic() > deadline:
                    raise TimeoutError('Original app did not exit; no app was replaced')
                time.sleep(0.2)
            record['phase'] = 'swapping'
            atomic_json(journal, record)
            if had_target:
                os.replace(target, backup)
            os.replace(prepared, target)
            replaced = True
            record['phase'] = 'starting'
            atomic_json(journal, record)
            subprocess.run(['/usr/bin/open', '-n', str(target)], check=True, cwd='/')
            deadline = time.monotonic() + 60
            while not ack.exists():
                if time.monotonic() > deadline:
                    raise TimeoutError('New app did not acknowledge startup')
                time.sleep(0.2)
            # Only the expected bundle/revision writes this transaction-specific acknowledgement.
            confirmation = json.loads(ack.read_text())
            if confirmation.get('revision') != revision:
                raise ValueError('Wrong startup acknowledgement')
            record['phase'] = 'complete'
            atomic_json(journal, record)
            atomic_json(support / 'update.json', dict(status='updated', current=revision,
                        at=datetime.datetime.now(datetime.timezone.utc).isoformat()))
            shutil.rmtree(work)
            journal.unlink()
        except Exception as error:
            # The new app can hang before it acknowledges. Identify by its exact executable
            # path before restoring the bundle; never overwrite a running candidate.
            if replaced:
                stop_app(target)
            if backup.exists():
                if target.exists():
                    shutil.rmtree(target)
                os.replace(backup, target)
            elif replaced and not had_target and target.exists():
                shutil.rmtree(target)
            record['phase'] = 'failed'
            record['detail'] = str(error)
            atomic_json(journal, record)
            atomic_json(support / 'update.json', dict(status='failed', detail=str(error),
                        at=datetime.datetime.now(datetime.timezone.utc).isoformat()))
            if not alive(parent_pid):
                subprocess.run(['/usr/bin/open', '-n', str(current)], cwd='/', check=False)
            if work.exists() and not backup.exists():
                shutil.rmtree(work)
            raise
        finally:
            ready.unlink(missing_ok=True)
            ack.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--recover', action='store_true')
    import sys
    if '--recover' in sys.argv:
        parser.add_argument('--support', required=True)
        args = parser.parse_args()
        recover(Path(args.support).resolve())
        return
    for name in ['staged', 'target', 'current', 'support', 'token']:
        parser.add_argument('--' + name, required=name not in ['pid'])
    parser.add_argument('--pid', type=int)
    parser.add_argument('--restore-login', action='store_true')
    parser.add_argument('--legacy', action='store_true')
    args = parser.parse_args()
    def cancelled(signum, frame):
        raise InterruptedError('Installation cancelled before completion')
    signal.signal(signal.SIGTERM, cancelled)
    if args.legacy:
        candidates = app_pids(Path(args.current).resolve())
        if len(candidates) != 1:
            raise RuntimeError('Expected exactly one legacy app at the update target')
        args.pid = candidates[0]
    if args.pid is None:
        parser.error('--pid is required without --legacy')
    install(Path(args.staged).resolve(), Path(args.target).absolute(), Path(args.current).resolve(),
            Path(args.support).resolve(), args.pid, args.token, args.restore_login, args.legacy)


if __name__ == '__main__':
    main()
