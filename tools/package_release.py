#!/usr/bin/env python3
"""Create a source-only release ZIP; never include local apps, Git history or credentials."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = {'LICENSE', 'README.md', 'SECURITY.md', 'THIRD_PARTY_NOTICES.md',
              '.gitignore', 'Build AI Illuminati.command', 'Install AI Illuminati.command'}
DOC_SUFFIXES = {'.md', '.png', '.gif', '.svg'}
CODE_SUFFIXES = {'.swift', '.py', '.sh'}
DENIED_SUFFIXES = {'.pem', '.key', '.p12', '.pfx', '.pyc', '.db', '.log'}
DENIED_NAMES = {'auth.json', 'accounts.json', 'poker.json', '.env'}


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args]).decode().strip()


def allowed(name):
    path = Path(name)
    if path.is_absolute() or '..' in path.parts:
        return False
    if any(part in {'.git', '.venv', '__pycache__', 'dist', '.release'} or part.endswith('.app') for part in path.parts):
        return False
    if path.suffix.lower() in DENIED_SUFFIXES or path.name in DENIED_NAMES or path.name.startswith(('.env.', 'credentials')):
        return False
    if name in ROOT_FILES:
        return True
    if path.parts[0] == 'docs':
        return path.suffix.lower() in DOC_SUFFIXES
    if path.parts[0] in {'app', 'tools'}:
        return path.suffix.lower() in CODE_SUFFIXES
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    parser.add_argument('--allow-dirty', action='store_true', help='Review builds only; not for publishing.')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?', args.version):
        parser.error('Version must be a semantic version without path characters.')
    dirty = bool(git('status', '--porcelain'))
    if dirty and not args.allow_dirty:
        parser.error('Worktree has changes. Commit reviewed files first, or use --allow-dirty for a review build.')
    revision = git('rev-parse', 'HEAD')
    names = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '--cached', '--others', '--exclude-standard', '-z']).decode().split('\0')
    files = sorted({name for name in names if name and allowed(name)})
    missing = ROOT_FILES - set(files)
    if missing:
        parser.error('Missing required release files: ' + ', '.join(sorted(missing)))
    sources = {}
    for name in files:
        source = ROOT / name
        if source.is_symlink() or not source.is_file() or not source.resolve().is_relative_to(ROOT):
            parser.error('Refusing non-regular or out-of-tree file: ' + name)
        sources[name] = source.read_bytes()
    installer = sources['Install AI Illuminati.command'].decode()
    if f"RELEASE_TAG='v{args.version}'" not in installer:
        parser.error('Installer RELEASE_TAG must match this release version.')
    if b'Copyright (c) 2026 jason401' not in sources['LICENSE']:
        parser.error('Expected copyright notice missing.')
    # Conservative content guard; an archive check is not a complete security audit.
    secret = re.compile(rb'(?:-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-(?:ant-|proj-)[A-Za-z0-9_-]{30,})')
    for name, data in sources.items():
        if secret.search(data):
            parser.error('Potential secret found; inspect privately before packaging: ' + name)
    manifest = {'version': args.version, 'revision': revision, 'review_worktree': dirty,
                'format': 'source-installer', 'files': {name: hashlib.sha256(data).hexdigest() for name, data in sources.items()}}
    sources['release-build.json'] = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
    args.output.mkdir(parents=True, exist_ok=True)
    stem = f'AI-Illuminati-{args.version}-source'
    archive = args.output / (stem + '.zip')
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as package:
        for name, data in sorted(sources.items()):
            entry = zipfile.ZipInfo(stem + '/' + name, date_time=(2026, 1, 1, 0, 0, 0))
            entry.create_system = 3
            mode = 0o755 if name.endswith(('.command', '.sh')) else 0o644
            entry.external_attr = (stat.S_IFREG | mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            package.writestr(entry, data)
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    (args.output / 'SHA256SUMS').write_text(f'{checksum}  {archive.name}\n')
    (args.output / (stem + '.manifest.json')).write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    print(f'Created {archive.name}: {len(sources)} files, {archive.stat().st_size} bytes')
    print('Review-only worktree build' if dirty else 'Clean tracked revision: ' + revision)
    print('No Git remote, tag, release, signing identity or installed app was changed.')


if __name__ == '__main__':
    main()
