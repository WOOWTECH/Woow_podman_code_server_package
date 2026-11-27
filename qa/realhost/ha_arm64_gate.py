#!/usr/bin/env python3
"""HA add-on aarch64 candidate on native arm64 hardware (GitHub ubuntu-24.04-arm runner).

There is no arm64 HA OS host with virtualization available, so this is NOT a real Supervisor test: the actual aarch64
candidate image runs through its real /init next to the Store's own mock Supervisor (WOOWTECH/Woow_HA_App_Store
.addon-sync/mock_supervisor.py at a pinned commit), the same arrangement as the amd64 HA-mock receipt, but on arm64.
Covers: the aarch64 image boots natively, Agent Connect R4 runtime is ready on arm64, the three-client core suite,
container restart keeps trust, disabled stays disabled.
Public log: stage names, PASS/FAIL, codes, hashes and versions only.
"""
import asyncio
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.request
import uuid
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402
import suite  # noqa: E402
from common import run, say  # noqa: E402

HERE = Path(__file__).resolve().parent
HA_REPO = Path(os.environ['HA_REPO'])
WORK = Path(os.environ.get('RUNNER_TEMP', '/tmp')) / 'ha-arm64'
CANDIDATE_COMMIT = '314a7126a588ffb3f7f859aa038df4f7a5cb9303'
REPOSITORY = 'woowtech/woow-ha-code-server-aarch64'
TAG = 'qa-314a7126a588ffb3f7f859aa038df4f7a5cb9303-45924502578-1'
DIGEST = 'sha256:2ece3ec3fecaebbea2de07383437afa03b0f6fef06dc5a924dd5e2e01776636b'
STORE_COMMIT = '421de9746b5b1ce5756cbb0ecc546b959aa560ac'
TOOLING = ['mock_supervisor.py', 'shipping_core.py', 'shipping-core.json']
WS = '/workspace/agent-connect-acceptance'
NAME = 'Agent Connect real-host QA (ha-aarch64-mock)'
ADDON, MOCK = 'ha-addon', 'ha-mock'

receipt = {'schemaVersion': 1, 'gate': 'ha-aarch64-native-mock-supervisor', 'modelCalls': 0, 'accountLogins': 0,
           'realHaSupervisorTested': False, 'qaBranchHead': os.environ.get('GITHUB_SHA'), 'checks': []}
if os.environ.get('GITHUB_RUN_ID'):
    receipt['runUrl'] = f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
checks = common.Checks(receipt)


class DockerTransport:
    def __init__(self, container):
        self.container = container

    def remote(self, args, data=None, timeout=180, allow_failure=False):
        result = subprocess.run(['docker', 'exec', '-i', self.container, *args], input=data or b'', capture_output=True,
                                timeout=timeout)
        if result.returncode and not allow_failure:
            raise RuntimeError('REMOTE_QA_COMMAND_FAILED')
        return result.stdout


host = suite.Host(DockerTransport(ADDON), WS, NAME)


def healthz():
    out = host.remote(['node', '-e', 'fetch("http://127.0.0.1:1337/healthz").then(r=>console.log(r.status)).catch(()=>console.log(0))'],
                      allow_failure=True, timeout=60)
    return out.decode().strip() == '200'


def wait_for(predicate, timeout, code, interval=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if predicate():
                return True
        except Exception:
            pass
        time.sleep(interval)
    raise AssertionError(code)


def start_addon(token):
    run(['docker', 'run', '-d', '--name', ADDON, '--network', f'container:{MOCK}', '-e', 'TZ=UTC', '-e', 'HOME=/root',
         '-e', f'SUPERVISOR_TOKEN={token}', '-e', f'HASSIO_TOKEN={token}', '-v', 'ha-data:/data', '-v', 'ha-workspace:/workspace',
         '--entrypoint', '/init', f'ghcr.io/{REPOSITORY}@{DIGEST}'])


def prepare(token):
    WORK.mkdir(parents=True, exist_ok=True)
    for sub in ('tooling', 'qa', 'fixtures/addons/self'):
        (WORK / sub).mkdir(parents=True, exist_ok=True)
    for name in TOOLING:
        url = f'https://raw.githubusercontent.com/WOOWTECH/Woow_HA_App_Store/{STORE_COMMIT}/.addon-sync/{name}'
        with urllib.request.urlopen(url, timeout=60) as response:
            (WORK / 'tooling' / name).write_bytes(response.read())
    config = yaml.safe_load(run(['git', '-C', str(HA_REPO), 'show', f'{CANDIDATE_COMMIT}:config.yaml']).stdout)
    options = {**config['options'], 'config_path': WS}
    keys = ['name', 'slug', 'version', 'description', 'url', 'arch', 'ingress', 'ingress_port', 'watchdog', 'ports']
    addon = {k: config[k] for k in keys}
    addon.update(hostname='local-woow-ha-code-server', ip_address='127.0.0.1', state='started', boot='auto', repository='local',
                 version_latest=config['version'], update_available=False, options=options, network=config['ports'])
    (WORK / 'qa' / 'fixture-id').write_text(str(uuid.uuid4()))
    (WORK / 'qa' / 'options.json').write_text(json.dumps(options))
    (WORK / 'qa' / 'addon.json').write_text(json.dumps(addon))
    (WORK / 'qa' / 'seed.py').write_bytes((HERE / 'ha_mock_seed.py').read_bytes())
    (WORK / 'fixtures' / 'services.json').write_text(json.dumps({'services': [{'slug': x, 'available': False} for x in ['mysql', 'mqtt']]}))
    (WORK / 'fixtures' / 'addons' / 'self' / 'options.json').write_text('{}')
    for volume in ('ha-data', 'ha-workspace', 'ha-state'):
        run(['docker', 'volume', 'create', volume])
    image = f'ghcr.io/{REPOSITORY}@{DIGEST}'
    pulled = run(['docker', 'pull', '--quiet', image], timeout=3600)
    identity = common.ghcr_identity(REPOSITORY, TAG, 'arm64')
    assert identity['topDigest'] == DIGEST, 'CANDIDATE_TAG_MOVED'
    image_id = run(['docker', 'image', 'inspect', '--format', '{{.Id}}', image]).stdout.decode().strip()
    assert image_id == identity['configDigest'], 'PULLED_IMAGE_CONFIG_MISMATCH'
    checks.add('aarch64_candidate_pulled_by_digest', reference=f'ghcr.io/{REPOSITORY}:{TAG}@{DIGEST}', configDigest=image_id,
               seconds=pulled.seconds)
    run(['docker', 'run', '--rm', '--entrypoint', 'python3', '-e', f'SUPERVISOR_TOKEN={token}',
         '-v', 'ha-data:/data', '-v', 'ha-workspace:/workspace', '-v', 'ha-state:/state', '-v', f'{WORK / "qa"}:/qa:ro',
         image, '/qa/seed.py'])
    run(['docker', 'run', '-d', '--name', MOCK, '--add-host', 'supervisor:127.0.0.1', '--add-host', 'hassio:127.0.0.1',
         '-e', f'SUPERVISOR_TOKEN={token}', '-e', 'PYTHONDONTWRITEBYTECODE=1', '-v', 'ha-state:/state',
         '-v', f'{WORK / "tooling"}:/tooling:ro', '-v', f'{WORK / "fixtures"}:/fixtures:ro', '--entrypoint', 'python3', image,
         '-u', '/tooling/mock_supervisor.py', 'serve', '--state', '/state', '--fixtures', '/fixtures'])
    wait_for(lambda: run(['docker', 'exec', MOCK, 'python3', '-c',
                          "import socket; socket.create_connection(('127.0.0.1',80),2).close()"], check=False).returncode == 0,
             120, 'MOCK_SUPERVISOR_NOT_LISTENING', interval=2)
    started = time.monotonic()
    start_addon(token)
    wait_for(healthz, 1200, 'ADDON_NOT_HEALTHY')
    arch = host.remote(['node', '-p', 'process.arch+" "+require("os").machine()']).decode().strip()
    assert arch == 'arm64 aarch64', 'NOT_NATIVE_ARM64'
    checks.add('aarch64_image_boots_through_real_init_with_store_mock_supervisor', seconds=round(time.monotonic() - started),
               nodeArch=arch.split()[0], machine=arch.split()[1], storeToolingCommit=STORE_COMMIT)


def persistence_actions():
    def restart():
        run(['docker', 'restart', '--time', '60', ADDON], timeout=600)
        wait_for(healthz, 900, 'ADDON_NOT_HEALTHY_AFTER_RESTART')

    def disabled_restart():
        host.okay(host.cli('stop'))
        restart()
        time.sleep(45)

    def enable():
        host.okay(host.cli('start'))

    return [('container_restart_keeps_trust', restart, True),
            ('agent_connect_disabled_stays_disabled_across_restart', disabled_restart, False),
            ('agent_connect_reenabled_same_identity', enable, True)]


async def main():
    stage = 'prepare'
    token = common.remember_secret(secrets.token_urlsafe(32))
    try:
        receipt['host'] = common.host_facts()
        assert receipt['host']['machine'] == 'aarch64', 'RUNNER_NOT_ARM64'
        await asyncio.to_thread(prepare, token)
        stage = 'runtime'
        host.okay(host.cli('configure', workspace=WS, hostName=NAME, target='paseo'))
        host.okay(host.cli('start'))
        identity = host.runtime_identity()
        checks.add('agent_connect_runtime_ready_on_arm64', revision=identity['managed'])
        stage = 'core_suite'
        receipt['coreSuite'] = await suite.core_suite(host)
        stage = 'persistence'
        receipt['persistence'] = await suite.trust_persistence(host, persistence_actions())
        logs = run(['docker', 'logs', ADDON], check=False)
        receipt['addonLogErrorLines'] = sum(1 for line in (logs.stdout + logs.stderr).decode(errors='replace').splitlines()
                                            if ' error' in line.lower() or line.lower().startswith('error'))
        parts = [receipt.get('coreSuite', {}), receipt.get('persistence', {})]
        receipt['result'] = 'PASS' if checks.all_passed() and all(p.get('result') == 'PASS' for p in parts) else 'FAIL'
    except Exception as error:
        receipt.update(result='FAIL', failedStage=stage, **suite.failure(error, common.SECRETS))
    finally:
        common.write_receipt(receipt['gate'], receipt)
    return 0 if receipt['result'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(asyncio.run(main()))
