"""Own fresh PVC fixtures only; the image's real /init seeds all product state."""
import hashlib
import json
import os
from pathlib import Path
import stat
import zipfile


def safe(path):
    for part in [path, *path.parents]:
        try:
            assert not stat.S_ISLNK(part.lstat().st_mode), 'FIXTURE_SYMLINK'
        except FileNotFoundError:
            pass
    return path


def main():
    fixture = Path('/qa/fixture-id').read_text().strip()
    for root in [Path('/data'), Path('/workspace')]:
        safe(root)
        marker = safe(root / '.agent-connect-ha-r4-qa-owner')
        if marker.exists():
            assert marker.read_text() == fixture, 'PVC_OWNER_MISMATCH'
        else:
            assert {x.name for x in root.iterdir()} <= {'lost+found'}, 'PVC_NOT_FRESH'
            marker.write_text(fixture)
            marker.chmod(0o600)
    options = json.loads(Path('/qa/options.json').read_text())
    target = safe(Path('/data/options.json'))
    if target.exists():
        assert json.loads(target.read_text()) == options, 'OPTIONS_CHANGED'
    else:
        target.write_text(json.dumps(options))
        target.chmod(0o600)
    workspace = safe(Path('/workspace/agent-connect-acceptance'))
    if not workspace.exists():
        workspace.mkdir(mode=0o700)
        files = {'README.md': b'# HA actual image + mock Supervisor acceptance\n',
                 'proof.txt': ('HA R4 root fixture ' + fixture + '\n').encode(),
                 'binary.bin': bytes(range(256))}
        for name, data in files.items():
            (workspace / name).write_bytes(data)
        with zipfile.ZipFile(workspace / 'fixture.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('proof.txt', files['proof.txt'])
    for name in ['README.md', 'proof.txt', 'binary.bin', 'fixture.zip']:
        assert safe(workspace / name).is_file(), 'FIXTURE_INCOMPLETE'
    addon = json.loads(Path('/qa/addon.json').read_text())
    addon['ingress_entry'] = '/api/hassio_ingress/' + os.environ['SUPERVISOR_TOKEN']
    addon['ingress_url'] = addon['ingress_entry'] + '/'
    Path('/state/addon.json').write_text(json.dumps(addon))
    print(json.dumps({'fixturesReady': True, 'fixtureSha256': {
        name: hashlib.sha256((workspace / name).read_bytes()).hexdigest()
        for name in ['README.md', 'proof.txt', 'binary.bin', 'fixture.zip']}}))


if __name__ == '__main__':
    main()
