#!/usr/bin/env python3
"""Native rootless Podman + systemd (Quadlet) gate for the Agent Connect R4 candidate.

MODE=upgrade     install main (4.139.1-9, GHCR main-a70b33d) with scripts/install.sh, seed data and pair a
                 browser with the legacy daemon, upgrade with scripts/upgrade.sh to the R4 candidate
                 (GHCR main-e087b31, same digest as every other acceptance run), then run the three-client
                 core suite, the native panel and systemd/linger persistence checks.
MODE=fresh-build the README default path on a clean host: scripts/install.sh builds the image locally with
                 podman build, then the same suites.
Public log: only stage names, PASS/FAIL, codes, hashes and versions.
"""
import asyncio
import http.client
import json
import os
import platform
import sys
import time
import urllib.parse
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402
import suite  # noqa: E402
from common import run, say, sha  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
HOME = Path.home()
OLD = HOME / 'pkg-old'
HOST_WS = HOME / 'qa-workspace'
WS = '/workspace/agent-connect-acceptance'
MODE = os.environ.get('MODE', 'upgrade')
ARCH = {'x86_64': 'amd64', 'aarch64': 'arm64'}[platform.machine()]
REPOSITORY = f'woowtech/woow-code-server-{ARCH}'
OLD_SOURCE, NEW_SOURCE = 'a70b33d9b96c9d0d23832c4928d62eeed00fd0f7', 'e087b314c89bfec8c1331e7c728885c7751ee440'
DIGESTS = {'amd64': {'old': 'sha256:8fbcef08bc2d99915e824f1de1238f02a042f033003e2d596765711f8d333b62',
                     'new': 'sha256:32421d32e188a7f769762f61b901a5e77fe73e992672d276d31d85fd02175cf6'},
           'arm64': {'old': 'sha256:6271ef92dc5a665c20f5ba8f3fc2d2b0bf647959f6a4ff4a64b82365e9ba3000',
                     'new': 'sha256:62316fa037376416c7f51f53f139e3588020d99186ca7796094cae1af6ef1b69'}}
UNIT = 'code-server.service'
PORT = 18443
NAME = f'Agent Connect real-host QA (podman-{ARCH})'
GIT_ENV = {'GIT_USER_NAME': 'Agent Connect QA', 'GIT_USER_EMAIL': 'agent-connect-qa@example.invalid'}
MARKERS = {'piState': '/data/pi-agent/qa-realhost-marker.txt',
           'ideUser': '/home/coder/.local/share/code-server/User/qa-realhost-marker.txt',
           'extensions': '/home/coder/.local/share/code-server/extensions/qa-realhost-marker.txt'}

receipt = {'schemaVersion': 1, 'gate': f'podman-{MODE}-{ARCH}', 'modelCalls': 0, 'accountLogins': 0,
           'qaBranchHead': os.environ.get('GITHUB_SHA'), 'runUrl': None, 'checks': []}
if os.environ.get('GITHUB_RUN_ID'):
    receipt['runUrl'] = f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
checks = common.Checks(receipt)
host = suite.Host(suite.PodmanTransport('code-server'), WS, NAME)


def podman_inspect(fmt, target='code-server', kind='container'):
    return run(['podman', kind, 'inspect', '--format', fmt, target]).stdout.decode().strip()


def wait_healthy(timeout=900, previous_id=None):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = run(['podman', 'inspect', '--format', '{{.Id}} {{.State.Status}} {{.State.Health.Status}}', 'code-server'],
                    check=False).stdout.decode().split()
        if len(state) == 3 and state[1] == 'running' and state[2] == 'healthy' and state[0] != previous_id:
            return state[0]
        time.sleep(3)
    raise AssertionError('CONTAINER_NOT_HEALTHY')


def unit_active(unit=UNIT):
    return run(['systemctl', '--user', 'is-active', unit], check=False).stdout.decode().strip()


def password(repo):
    value = run([str(repo / 'scripts/show-password.sh')]).stdout.decode().strip().splitlines()[-1].strip()
    assert len(value) >= 12, 'PASSWORD_UNREADABLE'
    return common.remember_secret(value)


def login(value):
    """code-server password login; returns True when a session cookie is issued."""
    connection = http.client.HTTPConnection('127.0.0.1', PORT, timeout=30)
    connection.request('POST', '/login', urllib.parse.urlencode({'password': value}),
                       {'Content-Type': 'application/x-www-form-urlencoded'})
    response = connection.getresponse()
    response.read()
    return response.status in (301, 302, 303) and 'code-server-session' in (response.getheader('Set-Cookie') or '')


def image_identity(which):
    identity = common.ghcr_identity(REPOSITORY, DIGESTS[ARCH][which], ARCH)
    assert identity['topDigest'] == DIGESTS[ARCH][which], 'REGISTRY_DIGEST_MISMATCH'
    return identity


def pull_and_tag(which, tag):
    identity = image_identity(which)
    ref = f'ghcr.io/{REPOSITORY}@{DIGESTS[ARCH][which]}'
    pulled = run(['podman', 'pull', '--quiet', ref], timeout=3600)
    image_id = pulled.stdout.decode().strip().splitlines()[-1]
    assert 'sha256:' + image_id == identity['configDigest'], 'PULLED_IMAGE_CONFIG_MISMATCH'
    run(['podman', 'tag', image_id, tag])
    source = podman_inspect('{{index .Labels "org.opencontainers.image.version"}}', tag, 'image')
    assert source == {'old': OLD_SOURCE, 'new': NEW_SOURCE}[which], 'IMAGE_SOURCE_LABEL_MISMATCH'
    checks.add(f'{which}_image_pulled_by_digest', reference=ref, configDigest=identity['configDigest'],
               sourceCommitLabel=source, compressedBytes=identity['compressedBytes'], seconds=pulled.seconds)
    return identity


def write_marker(path):
    value = uuid.uuid4().hex
    host.remote(['sh', '-c', 'mkdir -p "$(dirname "$1")" && cat > "$1"', '_', path], value.encode())
    return sha(value)


def read_marker(path):
    return sha(host.remote(['cat', path]))


def systemd_checks(tag):
    image = podman_inspect('{{.ImageName}}')
    assert image == f'localhost/woow-code-server:{tag}', 'RUNNING_IMAGE_TAG_MISMATCH'
    assert unit_active() == 'active', 'UNIT_NOT_ACTIVE'
    assert unit_active('code-server-health.timer') == 'active', 'HEALTH_TIMER_NOT_ACTIVE'
    linger = run(['loginctl', 'show-user', str(os.getuid()), '--property=Linger']).stdout.decode().strip()
    assert linger == 'Linger=yes', 'LINGER_NOT_ENABLED'
    generated = run(['systemctl', '--user', 'show', UNIT, '--property=SourcePath']).stdout.decode().strip()
    assert generated.endswith('/containers/systemd/code-server.container'), 'UNIT_NOT_FROM_QUADLET'
    rootless = run(['podman', 'info', '--format', '{{.Host.Security.Rootless}}']).stdout.decode().strip()
    assert rootless == 'true', 'NOT_ROOTLESS'
    return {'image': image, 'unit': 'active', 'healthTimer': 'active', 'linger': True, 'quadletSource': True, 'rootless': True}


def upgrade():
    started = time.monotonic()
    run([str(ROOT / 'scripts/upgrade.sh')], env=GIT_ENV, timeout=3600)
    receipt['upgradeSeconds'] = round(time.monotonic() - started)


async def open_direct_workbench(page, secret):
    await page.goto(f'http://127.0.0.1:{PORT}/?folder={WS}', wait_until='domcontentloaded', timeout=60000)
    field = page.locator('input[type=password]')
    if await field.count() and await field.first.is_visible():
        await field.first.fill(secret)
        await field.first.press('Enter')
    return page.main_frame


def persistence_actions():
    uid = os.getuid()

    def restart_unit():
        before = podman_inspect('{{.Id}}')
        run(['systemctl', '--user', 'restart', UNIT], timeout=900)
        wait_healthy(previous_id=before)

    def crash():
        before = podman_inspect('{{.Id}}')
        run(['podman', 'kill', 'code-server'])
        wait_healthy(previous_id=before)          # Restart=always, RestartSec=10

    def disabled_restart():
        host.okay(host.cli('stop'))
        restart_unit()
        time.sleep(45)                             # one full 30 s restore cycle of the connector service

    def enable():
        host.okay(host.cli('start'))

    def user_manager_restart():
        before = podman_inspect('{{.Id}}')
        run(['sudo', 'systemctl', 'restart', f'user@{uid}.service'], timeout=900)
        for _ in range(60):
            if Path(f'/run/user/{uid}/bus').exists():
                break
            time.sleep(1)
        wait_healthy(previous_id=before)

    return [('systemctl_user_restart_keeps_trust', restart_unit, True),
            ('container_crash_restart_always_keeps_trust', crash, True),
            ('agent_connect_disabled_stays_disabled_across_restart', disabled_restart, False),
            ('agent_connect_reenabled_same_identity', enable, True),
            ('user_manager_restart_with_linger_like_boot', user_manager_restart, True)]


async def main():
    stage = 'host'
    try:
        receipt['host'] = common.host_facts()
        assert receipt['host']['podman'].endswith('4.9.3'), 'PODMAN_VERSION_UNEXPECTED'
        HOST_WS.mkdir(exist_ok=True)
        (HOST_WS / 'agent-connect-acceptance').mkdir(exist_ok=True)
        new_tag = (ROOT / 'VERSION').read_text().strip()
        assert new_tag == '4.139.1-10', 'CANDIDATE_VERSION_MISMATCH'
        if MODE == 'upgrade':
            stage = 'old_install'
            run(['git', '-C', str(ROOT), 'fetch', '--quiet', 'origin', 'main'])
            run(['git', '-C', str(ROOT), 'worktree', 'add', '--detach', str(OLD), OLD_SOURCE])
            old_tag = (OLD / 'VERSION').read_text().strip()
            assert old_tag == '4.139.1-9', 'BASE_VERSION_MISMATCH'
            pull_and_tag('old', f'localhost/woow-code-server:{old_tag}')
            installed = run([str(OLD / 'scripts/install.sh'), '--no-build', '--yes', '--set', f'CODE_SERVER_WORKSPACE={HOST_WS}'],
                            env=GIT_ENV, timeout=3600)
            wait_healthy()
            secret = password(OLD)
            assert login(secret) and not login(secret + 'x'), 'LOGIN_BEHAVIOUR_UNEXPECTED'
            checks.add('main_installed_with_install_sh', version=old_tag, seconds=installed.seconds, **systemd_checks(old_tag))
            stage = 'seed'
            seeded = {name: write_marker(path) for name, path in MARKERS.items()}
            (HOST_WS / 'qa-realhost-marker.txt').write_text(uuid.uuid4().hex)
            seeded['hostWorkspace'] = sha((HOST_WS / 'qa-realhost-marker.txt').read_bytes())
            receipt['fixtureSha256'] = host.fixtures()
            checks.add('data_seeded_in_three_volumes_and_workspace', markers=sorted(seeded))
            stage = 'candidate_image'
            identity = pull_and_tag('new', f'localhost/woow-code-server:{new_tag}')
            stage = 'upgrade'
            async def do_upgrade():
                await asyncio.to_thread(upgrade)
            await suite.legacy_migration(host, checks, do_upgrade)
            new_id = podman_inspect('{{.Image}}')
            assert 'sha256:' + new_id == identity['configDigest'], 'RUNNING_IMAGE_IS_NOT_THE_CANDIDATE'
            after = {name: read_marker(path) for name, path in MARKERS.items()}
            after['hostWorkspace'] = sha((HOST_WS / 'qa-realhost-marker.txt').read_bytes())
            assert after == seeded, 'DATA_CHANGED_BY_UPGRADE'
            assert password(ROOT) == secret and login(secret), 'PASSWORD_CHANGED_BY_UPGRADE'
            snapshots = sorted((HOME / '.local/state/woow-quadlet/woow-code-server/rollback').glob('*/manifest'))
            tags = run(['podman', 'images', '--format', '{{.Repository}}:{{.Tag}}']).stdout.decode().split()
            assert f'localhost/woow-code-server:{old_tag}' in tags, 'PREVIOUS_IMAGE_NOT_KEPT'
            backups = sorted(p.name for p in (HOME / 'backups/woow-code-server').glob('*') if p.is_dir())   # backup.sh default --dest
            assert backups, 'UPGRADE_BACKUP_MISSING'
            checks.add('upgrade_sh_to_candidate_keeps_data_password_and_rollback_point', version=new_tag,
                       runningConfigDigest=identity['configDigest'], markersUnchanged=sorted(after),
                       rollbackSnapshots=len(snapshots), previousImageKept=True, backupEntries=len(backups),
                       seconds=receipt.get('upgradeSeconds'), **systemd_checks(new_tag))
        else:
            stage = 'fresh_build_install'
            built = run([str(ROOT / 'scripts/install.sh'), '--yes', '--set', f'CODE_SERVER_WORKSPACE={HOST_WS}'],
                        env=GIT_ENV, timeout=7200)
            wait_healthy()
            secret = password(ROOT)
            assert login(secret), 'LOGIN_FAILED'
            image_id = podman_inspect('{{.Image}}')
            checks.add('readme_default_install_builds_image_locally', version=new_tag, seconds=built.seconds,
                       localImageId='sha256:' + image_id, **systemd_checks(new_tag))
            receipt['fixtureSha256'] = host.fixtures()
            host.okay(host.cli('configure', workspace=WS, hostName=NAME, target='paseo'))
            host.okay(host.cli('start'))
        stage = 'runtime'
        identity = host.runtime_identity()
        checks.add('agent_connect_runtime_ready', revision=identity['managed'])
        stage = 'core_suite'
        receipt['coreSuite'] = await suite.core_suite(host)
        stage = 'native_panel'
        receipt['nativePanel'] = await suite.native_panel(lambda page: open_direct_workbench(page, secret), f'podman-{ARCH}')
        stage = 'persistence'
        receipt['persistence'] = await suite.trust_persistence(host, persistence_actions())
        stage = 'final'
        receipt['finalSystemd'] = systemd_checks(new_tag)
        journal = run(['journalctl', '--user', '-u', UNIT, '--no-pager', '-o', 'cat'], check=False).stdout.decode(errors='replace')
        error_lines = [line for line in journal.splitlines() if 'error' in line.lower()]
        receipt['journalErrorLines'] = len(error_lines)
        # Redacted samples (URLs reduced to host, long tokens removed) so a non-zero count can be judged.
        receipt['journalErrorSamples'] = [suite.redact(line, common.SECRETS)[:240] for line in error_lines[:5]]
        parts = [receipt.get('coreSuite', {}), receipt.get('nativePanel', {}), receipt.get('persistence', {})]
        receipt['result'] = 'PASS' if checks.all_passed() and all(p.get('result') == 'PASS' for p in parts) else 'FAIL'
    except Exception as error:
        receipt.update(result='FAIL', failedStage=stage, **suite.failure(error, common.SECRETS))
    finally:
        common.write_receipt(receipt['gate'], receipt)
    return 0 if receipt['result'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(asyncio.run(main()))
