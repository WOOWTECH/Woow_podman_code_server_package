#!/usr/bin/env python3
"""Vendor the common connector source into a HA or PaaS image build context."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

SOURCE = Path(__file__).resolve().parents[1]
EXCLUDED = {'node_modules', 'dist', 'out', '__pycache__', '.git', 'bootstrap', 'python'}
WRAPPERS = ('woow-connectors', 'woow-connectors-service')


def sources():
    result = {}
    for directory in ('connectors', 'extensions'):
        for file in (SOURCE / directory).rglob('*'):
            relative = file.relative_to(SOURCE)
            if not file.is_file() or file.is_symlink() or any(part in EXCLUDED for part in relative.parts):
                continue
            if relative.as_posix().startswith('connectors/omnigent/runtime/') or file.suffix == '.pyc':
                continue
            result[relative.as_posix()] = file
    for name in WRAPPERS:
        relative = 'rootfs/usr/local/bin/' + name
        result[relative] = SOURCE / relative
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', type=Path, help='HA repository root or PaaS code-server image directory')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    target = args.target.resolve()
    if not target.is_dir() or not (target / 'Dockerfile').is_file() or target == SOURCE:
        parser.error('target must be an existing destination Dockerfile directory')
    files = sources()
    hashes = {name: hashlib.sha256(file.read_bytes()).hexdigest() for name, file in sorted(files.items())}
    record = target / 'CONNECTORS_SOURCE.json'
    if args.check:
        for name, expected in hashes.items():
            file = target / name
            if not file.is_file() or file.is_symlink() or hashlib.sha256(file.read_bytes()).hexdigest() != expected:
                raise SystemExit('Connector source drift: ' + name)
        if not record.is_file() or json.loads(record.read_text()).get('files') != hashes:
            raise SystemExit('Connector source receipt drift')
        print(f'Verified {len(files)} connector source files in {target.name}')
        return
    previous = json.loads(record.read_text()).get('files', {}) if record.exists() else {}
    for name in previous.keys() - files.keys():
        file = target / name
        if file.resolve().is_relative_to(target) and file.is_file() and not file.is_symlink():
            file.unlink()
    for name, source in files.items():
        destination = target / name
        if not destination.resolve().is_relative_to(target) or destination.is_symlink():
            raise SystemExit('Unsafe destination: ' + name)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=SOURCE, text=True).strip()
    record.write_text(json.dumps({'schemaVersion': 1, 'repository': 'https://github.com/WOOWTECH/Woow_podman_code_server_package',
                                  'sourceRevision': revision, 'files': hashes}, indent=2) + '\n')
    print(f'Vendored {len(files)} connector source files into {target.name}')


if __name__ == '__main__':
    main()
