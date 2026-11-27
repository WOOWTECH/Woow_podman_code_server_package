"""Shared helpers for the real-host gates: registry identity, sanitized command runs, receipts."""
import hashlib
import json
import os
import platform
import subprocess
import time
import urllib.request
from pathlib import Path

import suite

OUT = Path(os.environ.get('QA_OUT', str(Path.home() / 'qa-out')))
SECRETS = []          # values that must never reach the public log


def remember_secret(value):
    if value and value not in SECRETS:
        SECRETS.append(value)
    return value


def say(stage, **facts):
    suite.log(stage, **facts)


def run(argv, check=True, timeout=1800, env=None, data=None, show_tail_on_failure=40):
    """Run a host command. Output is never printed, except a redacted tail when it fails."""
    started = time.monotonic()
    result = subprocess.run(argv, input=data, capture_output=True, timeout=timeout,
                            env={**os.environ, **(env or {})})
    if check and result.returncode:
        tail = (result.stdout + b'\n' + result.stderr).decode(errors='replace').splitlines()[-show_tail_on_failure:]
        for line in tail:
            print('  | ' + suite.redact(line, SECRETS), flush=True)
        raise RuntimeError('HOST_COMMAND_FAILED:' + Path(argv[0]).name)
    result.seconds = round(time.monotonic() - started, 1)
    return result


def ghcr_identity(repository, reference, arch):
    """Resolve a public GHCR reference (tag or digest) to its index, platform manifest and config digests."""
    accept = ', '.join(['application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json',
                        'application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json'])
    with urllib.request.urlopen(f'https://ghcr.io/token?scope=repository:{repository}:pull', timeout=30) as r:
        token = json.load(r)['token']

    def get(ref):
        request = urllib.request.Request(f'https://ghcr.io/v2/{repository}/manifests/{ref}',
                                         headers={'Authorization': 'Bearer ' + token, 'Accept': accept})
        with urllib.request.urlopen(request, timeout=60) as r:
            return r.headers.get('Docker-Content-Digest'), json.load(r)
    top_digest, top = get(reference)
    out = {'repository': repository, 'reference': reference, 'topDigest': top_digest}
    if 'manifests' in top:
        entry = next(m for m in top['manifests'] if m.get('platform', {}).get('architecture') == arch and m['platform'].get('os') == 'linux')
        out['manifestDigest'] = entry['digest']
        _, manifest = get(entry['digest'])
    else:
        out['manifestDigest'] = top_digest
        manifest = top
    out['configDigest'] = manifest['config']['digest']
    out['compressedBytes'] = sum(layer['size'] for layer in manifest['layers'])
    return out


def host_facts():
    facts = {'machine': platform.machine(), 'kernel': platform.release()}
    try:
        facts['os'] = next(line.split('=', 1)[1].strip().strip('"') for line in Path('/etc/os-release').read_text().splitlines()
                           if line.startswith('PRETTY_NAME='))
    except Exception:
        pass
    for name, argv in [('systemd', ['systemctl', '--version']), ('podman', ['podman', '--version'])]:
        try:
            facts[name] = subprocess.run(argv, capture_output=True, text=True, timeout=30).stdout.splitlines()[0]
        except Exception:
            facts[name] = None
    facts['cpus'] = os.cpu_count()
    try:
        facts['memoryGiB'] = round(int(next(l.split()[1] for l in Path('/proc/meminfo').read_text().splitlines()
                                            if l.startswith('MemTotal:'))) / 2**20, 1)
    except Exception:
        pass
    facts['runner'] = {'environment': os.environ.get('RUNNER_ENVIRONMENT'), 'os': os.environ.get('RUNNER_OS'),
                       'arch': os.environ.get('RUNNER_ARCH'), 'imageVersion': os.environ.get('ImageVersion')}
    return facts


def sha(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode()).hexdigest()


def write_receipt(name, receipt):
    OUT.mkdir(parents=True, exist_ok=True)
    text = json.dumps(receipt, indent=2, ensure_ascii=False)
    for secret in SECRETS:
        assert secret not in text, 'SECRET_IN_RECEIPT'
    (OUT / (name + '.json')).write_text(text + '\n')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as stream:
            stream.write(f"### {name}: {receipt.get('result')}\n\n| check | result |\n|---|---|\n")
            for row in receipt.get('checks', []):
                stream.write(f"| {row['id']} | {row['result']} |\n")
            for key in ('coreSuite', 'persistence', 'nativePanel', 'freshInstallCore'):
                part = receipt.get(key)
                if isinstance(part, dict):
                    cases = part.get('caseCount', len(part.get('cases', [])))
                    stream.write(f"| {key} | {part.get('result')} ({cases} cases) |\n")
            stream.write('\n')
    print(text, flush=True)


class Checks:
    """Ordered list of named checks; a failing check records a sanitized failure and stops the gate."""

    def __init__(self, receipt):
        self.receipt = receipt
        receipt.setdefault('checks', [])

    def add(self, check_id, **facts):
        row = {'id': check_id, 'result': 'PASS', **facts}
        self.receipt['checks'].append(row)
        say('check', **row)
        return row

    def fail(self, check_id, error, **facts):
        """Record a failed check without stopping the gate (the gate result becomes FAIL)."""
        row = {'id': check_id, 'result': 'FAIL', **facts, **suite.failure(error, SECRETS)}
        self.receipt['checks'].append(row)
        say('check', **row)
        return row

    def all_passed(self):
        return all(row['result'] == 'PASS' for row in self.receipt['checks'])
