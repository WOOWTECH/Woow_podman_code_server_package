#!/usr/bin/env python3
"""Real Home Assistant OS + Supervisor gate for the HA add-on R4 candidate (HAOS OVA under QEMU/KVM on the runner).

Supervisor installs, updates, restores and reinstalls the add-on itself; the add-on is offered as a LOCAL add-on
(the same config.yaml / image as the candidate commit), because the candidate only exists under its QA tag.
Supervisor offers an update whenever installed version != catalog version, so 0.1.16 -> qa-<sha>-<run>-<n> is a
real Supervisor update of the same slug and data directory.

  boot HAOS -> onboarding -> 0.1.16 (released GHCR image) -> seed data + pair the legacy daemon
  -> Supervisor update (with backup) to the candidate -> data/options/identity checks -> same browser still paired
  -> three-client core suite (47) over docker exec -> native panel through real HA login + Ingress
  -> add-on restart / stop+start / disabled-stays-disabled / host reboot -> restore the pre-update backup
  -> update again -> uninstall + fresh install of the candidate.
Public log: stage names, PASS/FAIL, codes, hashes and versions only.
"""
import asyncio
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402
import suite  # noqa: E402
from common import run, say, sha  # noqa: E402
from qga import Guest  # noqa: E402
import websockets  # noqa: E402

TMP = Path(os.environ.get('RUNNER_TEMP', '/tmp')) / 'haos'
HA_REPO = Path(os.environ['HA_REPO'])
HAOS_VERSION = os.environ.get('HAOS_VERSION', '18.3')
HAOS_URL = f'https://github.com/home-assistant/operating-system/releases/download/{HAOS_VERSION}/haos_ova-{HAOS_VERSION}.qcow2.xz'
# HA Core 2026.11 under Supervisor serves on port 80; 8123 is only a 307 redirect until onboarding completes.
# The runner's 127.0.0.1:8123 forwards to the guest's port 80 (Host header stays 127.0.0.1:8123).
BASE = 'http://127.0.0.1:8123'
CLIENT = BASE + '/'
SLUG = 'local_woow_ha_code_server'
ADDON_DIR = '/mnt/data/supervisor/addons/local/woow_ha_code_server'
OLD_REF, OLD_VERSION = 'v0.1.16', '0.1.16'
CANDIDATE_COMMIT = '314a7126a588ffb3f7f859aa038df4f7a5cb9303'
CANDIDATE_TAG = 'qa-314a7126a588ffb3f7f859aa038df4f7a5cb9303-45924502578-1'
CANDIDATE_DIGEST = 'sha256:4d531926a6ba35305431cfd267fac66f25edefc3a0451fdcd02ca8b980756a16'
IMAGE_REPO = 'woowtech/woow-ha-code-server-amd64'
WS = '/share/agent-connect-acceptance'
NAME = 'Agent Connect real-host QA (haos-amd64)'
ADDON_FILES = ['config.yaml', 'build.yaml', 'icon.png', 'logo.png', 'README.md', 'DOCS.md', 'CHANGELOG.md']
MARKERS = {'piState': '/data/pi-agent/qa-realhost-marker.txt', 'vscode': '/data/vscode/qa-realhost-marker.txt',
           'share': '/share/projects/qa-realhost-marker.txt'}

receipt = {'schemaVersion': 1, 'gate': 'haos-supervisor-amd64', 'modelCalls': 0, 'accountLogins': 0,
           'qaBranchHead': os.environ.get('GITHUB_SHA'), 'checks': []}
if os.environ.get('GITHUB_RUN_ID'):
    receipt['runUrl'] = f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
checks = common.Checks(receipt)
guest = Guest(str(TMP / 'qga.sock'))
state = {'container': None}
AUTH = {}


# ------------------------------------------------------------------ VM
def prepare_and_boot():
    TMP.mkdir(parents=True, exist_ok=True)
    disk = TMP / 'haos.qcow2'
    started = time.monotonic()
    with urllib.request.urlopen(HAOS_URL, timeout=600) as response, open(TMP / 'haos.qcow2.xz', 'wb') as out:
        shutil.copyfileobj(response, out, 1 << 20)
    run(['xz', '-d', '-T0', '-f', str(TMP / 'haos.qcow2.xz')], timeout=1200)
    run(['qemu-img', 'resize', str(disk), '64G'])
    shutil.copy('/usr/share/OVMF/OVMF_VARS_4M.fd', TMP / 'OVMF_VARS.fd')
    run(['qemu-system-x86_64', '-enable-kvm', '-cpu', 'host', '-smp', '3', '-m', '8192', '-machine', 'q35',
         '-drive', 'if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd',
         '-drive', f'if=pflash,format=raw,file={TMP / "OVMF_VARS.fd"}',
         '-drive', f'file={disk},if=virtio,format=qcow2,cache=writeback,discard=unmap',
         '-netdev', 'user,id=n0,ipv6=off,hostfwd=tcp:127.0.0.1:8123-:80', '-device', 'virtio-net-pci,netdev=n0',
         '-chardev', f'socket,path={TMP / "qga.sock"},server=on,wait=off,id=qga0',
         '-device', 'virtio-serial-pci', '-device', 'virtserialport,chardev=qga0,name=org.qemu.guest_agent.0',
         '-serial', f'file:{TMP / "serial.log"}', '-display', 'none', '-daemonize', '-pidfile', str(TMP / 'qemu.pid')])
    checks.add('haos_ova_booted_under_kvm', haosVersion=HAOS_VERSION, seconds=round(time.monotonic() - started))


def http_json(method, path, body=None, token=None, form=False, timeout=60):
    data = None
    headers = {'User-Agent': 'agent-connect-realhost-qa'}
    if body is not None:
        data = urllib.parse.urlencode(body).encode() if form else json.dumps(body).encode()
        headers['Content-Type'] = 'application/x-www-form-urlencoded' if form else 'application/json'
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        raw = response.read()
        return json.loads(raw) if raw else {}


def wait_for(predicate, timeout, interval=5, code='WAIT_TIMEOUT'):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except Exception:
            pass
        time.sleep(interval)
    raise AssertionError(code)


def front_door():
    """What answers on the forwarded port 8123: status code and kind, never the body."""
    try:
        request = urllib.request.Request(BASE + '/api/onboarding', headers={'User-Agent': 'agent-connect-realhost-qa'})
        with urllib.request.urlopen(request, timeout=20) as response:
            kind = response.headers.get('Content-Type', '').split(';')[0]
            body = response.read()
            return {'status': response.status, 'contentType': kind,
                    'onboardingList': kind == 'application/json' and isinstance(json.loads(body), list)}
    except urllib.error.HTTPError as error:
        return {'status': error.code}
    except urllib.error.URLError as error:
        return {'error': 'URLError', 'reason': type(error.reason).__name__, 'detail': suite.redact(error.reason)[:120]}
    except Exception as error:
        return {'error': type(error).__name__, 'detail': suite.redact(error)[:120]}


def inside_view():
    """Is Core listening inside the guest, and does it answer locally? (separates Core from the port forward)"""
    view = {}
    for name, script in [
            ('listeners', "ss -ltn 2>/dev/null | grep -E ':8123|:80 ' | head -5 || netstat -ltn 2>/dev/null | grep 8123 | head -5"),
            ('hostCurl', "curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:8123/api/onboarding 2>&1 || echo curl-failed"),
            ('hostCurlIface', "curl -s -m 10 -o /dev/null -w '%{http_code}' http://10.0.2.15/api/onboarding 2>&1 || echo curl-failed"),
            ('coreCurl', "docker exec homeassistant curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:8123/api/onboarding 2>&1 || echo exec-failed"),
            ('firewall', "nft list ruleset 2>/dev/null | grep -c -E 'drop|reject' || iptables -S 2>/dev/null | grep -c -E 'DROP|REJECT'")]:
        try:
            _, out, err = guest.sh(script, check=False, timeout=60)
            view[name] = suite.redact((out or err).decode(errors='replace').strip())[:300]
        except Exception as error:
            view[name] = type(error).__name__
    return view


def guest_progress():
    """Sanitized view from inside the HAOS host: containers, Core state, Supervisor jobs."""
    view = {'qga': guest.ping()}
    if not view['qga']:
        return view
    try:
        _, out, _ = guest.sh("docker ps --format '{{.Names}}|{{.Status}}'", check=False, timeout=60)
        view['containers'] = [line.split('|')[0] + ':' + line.split('|')[1].split(' ')[0] for line in out.decode().split()
                              if '|' in line]
        _, out, _ = guest.sh('docker exec hassio_cli ha core info --raw-json 2>/dev/null', check=False, timeout=90)
        core = (json.loads(out or b'{}').get('data') or {})
        view['core'] = {k: core.get(k) for k in ('version', 'version_latest', 'state', 'image')}
        _, out, _ = guest.sh('docker exec hassio_cli ha jobs info --raw-json 2>/dev/null', check=False, timeout=90)
        jobs = (json.loads(out or b'{}').get('data') or {}).get('jobs') or []
        view['runningJobs'] = sorted({j.get('name') for j in jobs if not j.get('done')})[:10]
    except Exception as error:
        view['guestError'] = type(error).__name__
    return view


def diagnostics():
    facts = {'frontDoor': front_door(), 'guest': guest_progress(), 'inside': inside_view()}
    try:
        _, out, _ = guest.sh('docker logs --tail 50 hassio_supervisor 2>&1', check=False, timeout=60)
        facts['supervisorLogTail'] = [suite.redact(l, common.SECRETS)[:240] for l in out.decode(errors='replace').splitlines()[-50:]]
        _, out, _ = guest.sh('ip -4 -o addr show 2>&1; ip route 2>&1 | head -3; nmcli -t -f CONNECTIVITY general 2>&1', check=False, timeout=60)
        facts['network'] = out.decode(errors='replace').splitlines()[:12]
    except Exception as error:
        facts['guestLogError'] = type(error).__name__
    try:
        serial = (TMP / 'serial.log').read_text(errors='replace').splitlines()[-40:]
        facts['serialTail'] = [suite.redact(l, common.SECRETS)[:200] for l in serial]
    except Exception:
        pass
    return facts


def wait_core(timeout=2400):
    started = time.monotonic()
    wait_for(guest.ping, 900, code='QGA_NOT_RESPONDING')
    deadline, report, core_up_since = time.monotonic() + timeout, 0, None
    while time.monotonic() < deadline:
        door = front_door()
        # Only HA Core answers the onboarding step list (200, also once onboarded); the Supervisor landing page that
        # serves port 80 while Core is still being installed answers 401, which must not count as ready.
        if door.get('onboardingList'):
            return round(time.monotonic() - started)
        if time.monotonic() - started >= report:
            progress = guest_progress()
            if core_up_since is None and 'homeassistant:Up' in progress.get('containers', []):
                core_up_since = time.monotonic()
            say('waiting_for_core', elapsed=round(time.monotonic() - started), frontDoor=door, guest=progress,
                inside=inside_view() if core_up_since else None)
            report += 60 if core_up_since else 120
        if core_up_since and time.monotonic() - core_up_since > 420:
            raise AssertionError('FRONT_DOOR_UNREACHABLE_WHILE_CORE_UP')
        time.sleep(10)
    raise AssertionError('HA_CORE_NOT_READY')


# ------------------------------------------------------------------ HA + Supervisor API
class HA:
    async def __aenter__(self):
        self.n = 0
        self.ws = await websockets.connect(BASE.replace('http', 'ws') + '/api/websocket', max_size=None, open_timeout=60)
        await self.ws.recv()
        await self.ws.send(json.dumps({'type': 'auth', 'access_token': AUTH['token']}))
        if json.loads(await self.ws.recv()).get('type') != 'auth_ok':
            raise AssertionError('HA_WS_AUTH_FAILED')
        return self

    async def __aexit__(self, *_):
        await self.ws.close()

    async def call(self, payload, timeout=60):
        self.n += 1
        await self.ws.send(json.dumps({'id': self.n, **payload}))
        async with asyncio.timeout(timeout):
            while True:
                reply = json.loads(await self.ws.recv())
                if reply.get('id') == self.n and reply.get('type') == 'result':
                    if reply.get('success') is not True:
                        error = reply.get('error') or {}
                        raise RuntimeError('HA_API ' + suite.redact(f"{error.get('code')} {error.get('message')}", common.SECRETS))
                    return reply.get('result')


async def sv(endpoint, method='get', data=None, timeout=120, retries=6):
    for attempt in range(retries):
        try:
            async with HA() as h:
                return await h.call({'type': 'supervisor/api', 'endpoint': endpoint, 'method': method, 'data': data or {},
                                     'timeout': timeout}, timeout=timeout + 20)
        except Exception:
            if attempt == retries - 1:
                raise
            await asyncio.sleep(10)


def onboard():
    password = common.remember_secret(secrets.token_urlsafe(18))
    created = http_json('POST', '/api/onboarding/users', {'client_id': CLIENT, 'name': 'QA Owner', 'username': 'qa',
                                                          'password': password, 'language': 'en'})
    token = http_json('POST', '/auth/token', {'grant_type': 'authorization_code', 'code': created['auth_code'],
                                              'client_id': CLIENT}, form=True)
    AUTH.update(password=password, token=common.remember_secret(token['access_token']),
                refresh=common.remember_secret(token['refresh_token']), expires=token['expires_in'], obtained=time.time())
    for step, body in [('core_config', {}), ('analytics', {}), ('integration', {'client_id': CLIENT, 'redirect_uri': CLIENT})]:
        http_json('POST', '/api/onboarding/' + step, body, token=AUTH['token'])

    async def long_lived():
        async with HA() as h:
            return await h.call({'type': 'auth/long_lived_access_token', 'client_name': 'agent-connect-realhost-qa', 'lifespan': 1})
    AUTH['token'] = common.remember_secret(asyncio.run(long_lived()))


async def wait_supervisor(timeout=1800):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            info = await sv('/supervisor/info', retries=1)
            jobs = await sv('/jobs/info', retries=1)
            busy = [j for j in (jobs or {}).get('jobs', []) if not j.get('done')]
            if info.get('version') and not busy:
                return info
        except Exception:
            pass
        await asyncio.sleep(10)
    raise AssertionError('SUPERVISOR_NOT_IDLE')


async def facts():
    supervisor = await sv('/supervisor/info')
    core, os_info, resolution = await sv('/core/info'), await sv('/os/info'), await sv('/resolution/info')
    host_info = await sv('/info')
    return {'supervisor': supervisor.get('version'), 'core': core.get('version'), 'os': os_info.get('version'),
            'arch': host_info.get('arch'), 'machine': host_info.get('machine'), 'supported': supervisor.get('supported'),
            'healthy': supervisor.get('healthy'), 'unsupported': resolution.get('unsupported'), 'unhealthy': resolution.get('unhealthy')}


async def addon_info():
    return await sv(f'/addons/{SLUG}/info')


async def wait_addon(version, want_state='started', timeout=3600):
    deadline = time.monotonic() + timeout
    info = {}
    while time.monotonic() < deadline:
        try:
            info = await addon_info()
            jobs = await sv('/jobs/info', retries=1)
            busy = any(not j.get('done') for j in (jobs or {}).get('jobs', []))
            if info.get('version') == version and info.get('state') == want_state and not busy:
                return info
        except Exception:
            pass
        await asyncio.sleep(10)
    raise AssertionError('ADDON_STATE_NOT_REACHED')


# ------------------------------------------------------------------ guest helpers
def place_addon(ref, version=None):
    """Write the add-on's catalog files from the HA add-on repository at `ref` as a Supervisor local add-on."""
    present = set(run(['git', '-C', str(HA_REPO), 'ls-tree', '--name-only', ref]).stdout.decode().split())
    names = [n for n in ADDON_FILES if n in present]
    assert 'config.yaml' in names, 'CONFIG_MISSING_AT_REF'
    names += [p for p in run(['git', '-C', str(HA_REPO), 'ls-tree', '-r', '--name-only', ref, 'translations']).stdout.decode().split()]
    guest.sh(f'rm -rf {ADDON_DIR} && mkdir -p {ADDON_DIR}/translations')
    written = {}
    for name in names:
        data = run(['git', '-C', str(HA_REPO), 'show', f'{ref}:{name}']).stdout
        if name == 'config.yaml' and version:
            text, count = re.subn(r'(?m)^version: "[^"]+"$', f'version: "{version}"', data.decode())
            assert count == 1, 'CONFIG_VERSION_LINE_NOT_FOUND'
            data = text.encode()
        code, _, _ = guest.run(['/bin/sh', '-c', 'cat > "$1"', '_', f'{ADDON_DIR}/{name}'], stdin=data)
        assert code == 0, 'ADDON_FILE_WRITE_FAILED'
        written[name] = sha(data)
    code, out, _ = guest.sh(f'cd {ADDON_DIR} && find . -type f | wc -l')
    assert int(out.decode().strip()) == len(names), 'ADDON_FILES_INCOMPLETE'
    return written


def container_name():
    _, out, _ = guest.sh("docker ps --format '{{.Names}}'")
    names = [n for n in out.decode().split() if n.endswith(SLUG)]
    assert len(names) == 1, 'ADDON_CONTAINER_NOT_FOUND'
    state['container'] = names[0]
    host.t.container = names[0]
    return names[0]


def container_facts():
    name = container_name()
    _, out, _ = guest.sh(f"docker inspect --format '{{{{.Image}}}}|{{{{.Config.Image}}}}|{{{{.State.Status}}}}|{{{{.RestartCount}}}}' {name}")
    image_id, config_image, status, restarts = out.decode().strip().split('|')
    _, digests, _ = guest.sh(f"docker image inspect --format '{{{{json .RepoDigests}}}}' {image_id}")
    return {'imageId': image_id, 'configImage': config_image, 'status': status, 'restartCount': int(restarts),
            'repoDigests': json.loads(digests.decode())}


def healthz():
    """The add-on's own watchdog endpoint (config.yaml: watchdog http://[HOST]:[PORT:1337]/healthz)."""
    out = host.remote(['node', '-e', 'fetch("http://127.0.0.1:1337/healthz").then(r=>console.log(r.status)).catch(()=>console.log(0))'],
                      allow_failure=True, timeout=60)
    return out.decode().strip() == '200'


def write_marker(path):
    value = uuid.uuid4().hex
    host.remote(['sh', '-c', 'mkdir -p "$(dirname "$1")" && cat > "$1"', '_', path], value.encode())
    return sha(value)


def read_marker(path):
    return sha(host.remote(['cat', path]))


class GuestDocker(suite.GuestDockerTransport):
    docker = '/usr/bin/docker'

    def remote(self, args, data=None, timeout=180, allow_failure=False):
        code, out, _ = self.guest.run([self.docker, 'exec', '-i', self.container, *args], stdin=data or b'', timeout=timeout)
        if code and not allow_failure:
            raise RuntimeError('REMOTE_QA_COMMAND_FAILED')
        return out


host = suite.Host(GuestDocker(guest, 'unset'), WS, NAME)


# ------------------------------------------------------------------ browser through HA
async def open_ingress(page):
    """Real HA login form, then the add-on's panel; returns the Ingress frame hosting the workbench."""
    await page.goto(BASE + '/', wait_until='domcontentloaded', timeout=90000)
    await page.wait_for_function("() => location.pathname.startsWith('/auth/')", timeout=90000)
    user = page.locator('input[autocomplete="username"], input[name="username"]')
    secret_field = page.locator('input[autocomplete="current-password"], input[name="password"], input[type="password"]')
    try:
        await user.first.wait_for(timeout=60000)
    except Exception:
        user = page.get_by_label('Username')
        secret_field = page.get_by_label('Password')
    await user.first.fill('qa')
    await secret_field.first.fill(AUTH['password'])
    await secret_field.first.press('Enter')
    await page.wait_for_function("() => !location.pathname.startsWith('/auth/')", timeout=90000)
    receipt['haLoginForm'] = 'real-login-form'
    for path in (f'/app/{SLUG}', f'/hassio/ingress/{SLUG}'):
        await page.goto(BASE + path, wait_until='domcontentloaded', timeout=90000)
        for _ in range(90):
            frame = next((f for f in page.frames if '/api/hassio_ingress/' in f.url), None)
            if frame:
                receipt['haPanelPath'] = path.replace(SLUG, '<slug>')
                return frame
            await asyncio.sleep(1)
    raise AssertionError('INGRESS_FRAME_NOT_FOUND')


# ------------------------------------------------------------------ gate
def persistence_actions():
    def restart_addon():
        before = container_facts()['imageId'], state['container']
        asyncio.run(sv(f'/addons/{SLUG}/restart', 'post', timeout=600))
        wait_for(healthz, 600, code='ADDON_NOT_HEALTHY_AFTER_RESTART')

    def stop_start():
        asyncio.run(sv(f'/addons/{SLUG}/stop', 'post', timeout=600))
        asyncio.run(sv(f'/addons/{SLUG}/start', 'post', timeout=600))
        wait_for(healthz, 600, code='ADDON_NOT_HEALTHY_AFTER_START')

    def disabled_restart():
        host.okay(host.cli('stop'))
        restart_addon()
        time.sleep(45)

    def enable():
        host.okay(host.cli('start'))

    def reboot():
        try:
            asyncio.run(sv('/host/reboot', 'post', timeout=120, retries=1))
        except Exception:
            pass                                    # the connection drops while the host goes down
        time.sleep(30)
        wait_core()
        asyncio.run(wait_addon(CANDIDATE_TAG))
        container_name()
        wait_for(healthz, 900, code='ADDON_NOT_HEALTHY_AFTER_REBOOT')

    return [('supervisor_addon_restart_keeps_trust', restart_addon, True),
            ('supervisor_addon_stop_start_keeps_trust', stop_start, True),
            ('agent_connect_disabled_stays_disabled_across_addon_restart', disabled_restart, False),
            ('agent_connect_reenabled_same_identity', enable, True),
            ('haos_host_reboot_boot_auto_keeps_trust', reboot, True)]


async def gate():
    stage = 'boot'
    try:
        receipt['runnerHost'] = common.host_facts()
        await asyncio.to_thread(prepare_and_boot)
        stage = 'core_first_start'
        seconds = await asyncio.to_thread(wait_core)
        await asyncio.to_thread(onboard)
        _, docker, _ = guest.sh('command -v docker')
        GuestDocker.docker = docker.decode().strip()
        assert GuestDocker.docker.startswith('/'), 'GUEST_DOCKER_NOT_FOUND'
        checks.add('ha_core_installed_and_onboarded_by_api', seconds=seconds)
        await wait_supervisor()
        receipt['haos'] = await facts()
        assert receipt['haos']['arch'] == 'amd64' and receipt['haos']['os'] == HAOS_VERSION, 'HAOS_FACTS_UNEXPECTED'
        checks.add('real_supervisor_ready', **{k: receipt['haos'][k] for k in ('supervisor', 'core', 'os', 'supported', 'healthy')})

        stage = 'install_released'
        old_identity = common.ghcr_identity(IMAGE_REPO, OLD_VERSION, 'amd64')
        place_addon(OLD_REF)
        await sv('/store/reload', 'post', timeout=600)
        store = await addon_info()
        assert store.get('version_latest') == OLD_VERSION, 'LOCAL_CATALOG_NOT_READ'
        t0 = time.monotonic()
        await sv(f'/store/addons/{SLUG}/install', 'post', {'background': True}, timeout=600)
        installed = await wait_addon(OLD_VERSION, 'stopped')
        await sv(f'/addons/{SLUG}/options', 'post', {'options': {**installed['options'], 'timezone': 'Asia/Taipei'}})
        await sv(f'/addons/{SLUG}/start', 'post', timeout=900)
        info = await wait_addon(OLD_VERSION)
        container_name()
        await asyncio.to_thread(wait_for, healthz, 900, 5, 'RELEASED_ADDON_NOT_HEALTHY')
        old = container_facts()
        assert old['imageId'] == old_identity['configDigest'], 'RELEASED_IMAGE_MISMATCH'
        checks.add('released_0_1_16_installed_by_supervisor', configDigest=old['imageId'], seconds=round(time.monotonic() - t0),
                   ingress=info.get('ingress'), boot=info.get('boot'), watchdog=info.get('watchdog'))

        stage = 'seed'
        seeded = {name: write_marker(path) for name, path in MARKERS.items()}
        receipt['fixtureSha256'] = host.fixtures()
        checks.add('data_seeded_in_addon_data_vscode_and_share', markers=sorted(seeded))

        stage = 'supervisor_update'
        candidate_files = place_addon(CANDIDATE_COMMIT, CANDIDATE_TAG)
        candidate = common.ghcr_identity(IMAGE_REPO, CANDIDATE_TAG, 'amd64')
        assert candidate['topDigest'] == CANDIDATE_DIGEST, 'CANDIDATE_TAG_MOVED'

        async def do_update():
            await sv('/store/reload', 'post', timeout=600)
            offer = await addon_info()
            assert offer.get('update_available') is True and offer.get('version_latest') == CANDIDATE_TAG, 'UPDATE_NOT_OFFERED'
            t1 = time.monotonic()
            await sv(f'/store/addons/{SLUG}/update', 'post', {'backup': True, 'background': True}, timeout=600)
            await wait_addon(CANDIDATE_TAG)
            receipt['updateSeconds'] = round(time.monotonic() - t1)
            container_name()
            await asyncio.to_thread(wait_for, healthz, 900, 5, 'CANDIDATE_NOT_HEALTHY')
        await suite.legacy_migration(host, checks, do_update)
        new = container_facts()
        assert new['imageId'] == candidate['configDigest'], 'RUNNING_IMAGE_IS_NOT_THE_CANDIDATE'
        assert any(d.endswith('@' + CANDIDATE_DIGEST) for d in new['repoDigests']), 'CANDIDATE_DIGEST_NOT_RECORDED'
        after = {name: read_marker(path) for name, path in MARKERS.items()}
        assert after == seeded, 'DATA_CHANGED_BY_UPDATE'
        info = await addon_info()
        assert info['options'].get('timezone') == 'Asia/Taipei', 'OPTIONS_CHANGED_BY_UPDATE'
        backups = [b for b in (await sv('/backups')).get('backups', []) if SLUG in ((b.get('content') or {}).get('addons') or [])]
        assert backups, 'PRE_UPDATE_BACKUP_MISSING'
        receipt['preUpdateBackup'] = backups[-1]['slug']
        checks.add('supervisor_update_to_candidate_keeps_data_options_and_backup', configDigest=new['imageId'],
                   manifestDigest=CANDIDATE_DIGEST, seconds=receipt.get('updateSeconds'), markersUnchanged=sorted(after),
                   backupName=backups[-1].get('name'), catalogFilesSha256=candidate_files.get('config.yaml'))

        stage = 'core_suite'
        receipt['coreSuite'] = await suite.core_suite(host)
        stage = 'native_panel_ingress'
        receipt['nativePanel'] = await suite.native_panel(open_ingress, 'haos-ingress')
        stage = 'persistence'
        receipt['persistence'] = await suite.trust_persistence(host, persistence_actions())

        stage = 'restore_pre_update_backup'
        t2 = time.monotonic()
        await sv(f"/backups/{receipt['preUpdateBackup']}/restore/partial", 'post', {'addons': [SLUG], 'background': True}, timeout=600)
        await wait_addon(OLD_VERSION, timeout=3600)
        container_name()
        await asyncio.to_thread(wait_for, healthz, 900, 5, 'RESTORED_ADDON_NOT_HEALTHY')
        restored = container_facts()
        assert restored['imageId'] == old_identity['configDigest'], 'RESTORE_DID_NOT_RETURN_RELEASED_IMAGE'
        assert {name: read_marker(path) for name, path in MARKERS.items()} == seeded, 'DATA_CHANGED_BY_RESTORE'
        checks.add('restore_pre_update_backup_returns_0_1_16_with_data', seconds=round(time.monotonic() - t2))
        stage = 'update_again'
        await sv('/store/reload', 'post', timeout=600)
        await sv(f'/store/addons/{SLUG}/update', 'post', {'backup': False, 'background': True}, timeout=600)
        await wait_addon(CANDIDATE_TAG)
        container_name()
        await asyncio.to_thread(wait_for, healthz, 900, 5, 'CANDIDATE_NOT_HEALTHY')
        status = await asyncio.to_thread(wait_for, lambda: (lambda s: s if s.get('ok') and s['daemon'].get('reachable') else None)(host.cli('status')),
                          600, code='DAEMON_NOT_RESTORED_AFTER_SECOND_UPDATE')
        assert container_facts()['imageId'] == candidate['configDigest'], 'SECOND_UPDATE_IMAGE_MISMATCH'
        checks.add('second_update_after_rollback_restores_agent_connect', daemonVersion=status['daemon'].get('version'))

        stage = 'fresh_install'
        await sv(f'/addons/{SLUG}/uninstall', 'post', {'remove_config': True}, timeout=900)
        await sv('/store/reload', 'post', timeout=600)
        await sv(f'/store/addons/{SLUG}/install', 'post', {'background': True}, timeout=600)
        await wait_addon(CANDIDATE_TAG, 'stopped')
        await sv(f'/addons/{SLUG}/start', 'post', timeout=900)
        await wait_addon(CANDIDATE_TAG)
        container_name()
        await asyncio.to_thread(wait_for, healthz, 900, 5, 'FRESH_ADDON_NOT_HEALTHY')
        assert host.remote(['sh', '-c', 'test -e /data/pi-agent/qa-realhost-marker.txt && echo stale || echo clean']).decode().strip() == 'clean', 'FRESH_INSTALL_HAS_OLD_DATA'
        host.fixtures()
        receipt['freshInstallCore'] = await suite.core_suite(host, targets=['paseo'])
        checks.add('uninstall_and_fresh_install_of_candidate', imageId=container_facts()['imageId'])

        stage = 'final'
        receipt['haosFinal'] = await facts()
        _, logs, _ = guest.sh(f"docker logs {state['container']} 2>&1 | tail -n 2000", check=False)
        receipt['addonLogErrorLines'] = sum(1 for line in logs.decode(errors='replace').splitlines() if re.search(r'\berror\b', line, re.I))
        parts = [receipt.get(k, {}) for k in ('coreSuite', 'nativePanel', 'persistence', 'freshInstallCore')]
        receipt['result'] = 'PASS' if checks.all_passed() and all(p.get('result') == 'PASS' for p in parts) else 'FAIL'
    except Exception as error:
        receipt.update(result='FAIL', failedStage=stage, **suite.failure(error, common.SECRETS))
        try:
            receipt['diagnostics'] = await asyncio.to_thread(diagnostics)
        except Exception:
            pass
        try:
            receipt['haosAtFailure'] = await facts()
        except Exception:
            pass
    finally:
        common.write_receipt(receipt['gate'], receipt)
    return 0 if receipt['result'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(asyncio.run(gate()))
