"""Agent Connect three-client acceptance for real hosts (native Podman+systemd, HAOS Supervisor).

Same cases as the isolated k3s/HA-mock core suite (three_clients_qa.py, 47 cases), with the transport
(kubectl exec) replaced by a host transport (podman exec / docker exec over the QEMU guest agent).
Everything this module returns is a case id, PASS/FAIL, a stable error code, a hash or a version.
Pairing offers, passwords and tokens are only held in memory and never printed (public CI logs).
"""
import asyncio
import base64
import hashlib
import io
import json
import re
import subprocess
import time
import traceback
import uuid
import zipfile
from pathlib import Path
from urllib.parse import urlsplit

from playwright.async_api import async_playwright, Error as BrowserError

REVISION = '0.17.5-r4-2b20ef5fac0a'
PROFILES = [('paseo', 'https://app.paseo.sh', 'relay.paseo.sh:443'),
            ('woowtech', 'https://smart.woowtech.io', 'relay.woowtech.io:443'),
            ('apporo', 'https://smart.apporo.ai', 'relay.apporo.ai:443')]
SAFE_CODE = re.compile(r'[A-Z][A-Z0-9_]{1,80}')
URL = re.compile(r'(https?|wss?)://([^/\s"\'<>#?]+)[^\s"\'<>]*')
LONG = re.compile(r'[A-Za-z0-9_\-+/=]{32,}')


# ---------------------------------------------------------------- sanitizing
def redact(text, secrets=()):
    text = str(text)
    for secret in secrets:
        if secret:
            text = text.replace(secret, '[secret]')
    text = URL.sub(lambda m: m.group(1) + '://' + m.group(2) + '/[path]', text)
    return LONG.sub('[long]', text)[:600]


def failure(error, secrets=()):
    """Public, sanitized failure facts: exception type, stable code, frames and a redacted message."""
    code = str(error) if isinstance(error, AssertionError) and SAFE_CODE.fullmatch(str(error)) else None
    frames = [f'{Path(f.filename).name}:{f.lineno}:{f.name}' for f in traceback.extract_tb(error.__traceback__)][-6:]
    return {'errorType': type(error).__name__, 'errorCode': code or 'CASE_FAILED', 'frames': frames,
            'detail': redact(error, secrets)}


def log(stage, **facts):
    print(json.dumps({'stage': stage, **facts}), flush=True)


# ---------------------------------------------------------------- transports
class PodmanTransport:
    """podman exec into the Quadlet-managed container, as the container's own user (like kubectl exec)."""

    def __init__(self, container='code-server'):
        self.container = container

    def remote(self, args, data=None, timeout=180, allow_failure=False):
        result = subprocess.run(['podman', 'exec', '-i', self.container, *args], input=data or b'',
                                capture_output=True, timeout=timeout)
        if result.returncode and not allow_failure:
            raise RuntimeError('REMOTE_QA_COMMAND_FAILED')
        return result.stdout


class GuestDockerTransport:
    """docker exec into the Supervisor-managed add-on container, through the QEMU guest agent of the HAOS VM."""

    def __init__(self, guest, container):
        self.guest, self.container = guest, container

    def remote(self, args, data=None, timeout=180, allow_failure=False):
        code, out, _ = self.guest.run(['/usr/bin/docker', 'exec', '-i', self.container, *args], stdin=data or b'',
                                      timeout=timeout)
        if code and not allow_failure:
            raise RuntimeError('REMOTE_QA_COMMAND_FAILED')
        return out


class Host:
    def __init__(self, transport, workspace, host_name):
        self.t, self.workspace, self.host_name = transport, workspace, host_name

    def remote(self, *a, **k):
        return self.t.remote(*a, **k)

    def cli(self, action, **fields):
        raw = self.remote(['/usr/local/bin/woow-connectors'],
                          (json.dumps({'connector': 'paseo', 'action': action, **fields}) + '\n').encode(),
                          allow_failure=True)
        return json.loads(raw)

    def okay(self, result):
        assert result.get('ok') is True, result.get('error', {}).get('code', 'CLI_FAILED')
        return result

    def bootstrap(self):
        code = ("import {withClient} from '/opt/woow-connectors/paseo/src/runtime.mjs';"
                "import {acceptanceWorkspace} from '/opt/woow-connectors/paseo/src/acceptance-workspace.mjs';"
                "const result=await withClient(async client=>({serverId:client.getLastServerInfoMessage().serverId,"
                "workspaceId:await acceptanceWorkspace(client,process.argv[1])}));console.log(JSON.stringify(result));")
        return json.loads(self.remote(['node', '--input-type=module', '-e', code, self.workspace]))

    def runtime_identity(self, require_running=True):
        code = ('''import fs from 'node:fs';import {RUNTIME_REVISION,runtimeDirectory,runtimeReady} from '/opt/woow-connectors/paseo/src/runtime-layout.mjs';'''
                '''import{locations,readState}from'/opt/woow-connectors/paseo/src/state.mjs';const state=readState(),loc=locations(),'''
                '''env=state.daemonPid?fs.readFileSync('/proc/'+state.daemonPid+'/environ','utf8').split('\\0'):[];'''
                '''const actual=env.find(x=>x.startsWith('PI_PASEO_RUNTIME_REVISION='))?.slice('PI_PASEO_RUNTIME_REVISION='.length)??null;'''
                '''console.log(JSON.stringify({managed:RUNTIME_REVISION,recorded:state.daemonRuntimeRevision??null,actual,ready:runtimeReady(loc),runtimeDir:loc.runtimeDir}));''')
        value = json.loads(self.remote(['node', '--input-type=module', '-e', code]))
        assert value['ready'] and value['managed'] == REVISION, 'MANAGED_RUNTIME_IDENTITY_MISMATCH'
        assert value['runtimeDir'] == '/opt/woow-connectors/paseo/runtime', 'UNEXPECTED_RUNTIME_LOCATION'
        if require_running or value['actual'] is not None:
            assert value['managed'] == value['recorded'] == value['actual'], 'DAEMON_RUNTIME_IDENTITY_MISMATCH'
        return value

    def fixtures(self):
        """Create the four workspace fixture files through the container itself (owned by the IDE user)."""
        token = uuid.uuid4().hex
        files = {'README.md': b'# Agent Connect real-host acceptance\n',
                 'proof.txt': ('Agent Connect real-host fixture ' + token + '\n').encode(),
                 'binary.bin': bytes(range(256))}
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr('proof.txt', files['proof.txt'])
        files['fixture.zip'] = archive.getvalue()
        script = ('const fs=require("fs"),p=require("path");const d=process.argv[1];fs.mkdirSync(d,{recursive:true,mode:0o700});'
                  'const files=JSON.parse(require("fs").readFileSync(0,"utf8"));'
                  'for(const [n,b] of Object.entries(files))fs.writeFileSync(p.join(d,n),Buffer.from(b,"base64"));'
                  'console.log(JSON.stringify(Object.keys(files).sort()));')
        payload = json.dumps({k: base64.b64encode(v).decode() for k, v in files.items()}).encode()
        names = json.loads(self.remote(['node', '-e', script, self.workspace], payload))
        assert names == sorted(files), 'FIXTURE_INCOMPLETE'
        return {k: hashlib.sha256(v).hexdigest() for k, v in files.items()}


async def visible(page, test_id):
    return page.get_by_test_id(test_id).filter(visible=True).first


async def connect_offer(page, url, origin):
    await page.goto(origin, wait_until='domcontentloaded', timeout=60000)
    await page.wait_for_function('document.body.innerText.trim().length>30', timeout=45000)
    versions = sorted(set(re.findall(r'\bv?0\.17\.\d+\b', await page.locator('body').inner_text())))
    await page.goto(url, wait_until='domcontentloaded', timeout=60000)
    await page.get_by_text('Connect to this host?', exact=True).wait_for(timeout=45000)
    await page.get_by_role('button', name='Connect', exact=True).click()
    await page.get_by_text('Connect to this host?', exact=True).wait_for(state='hidden', timeout=45000)
    await page.get_by_test_id('wide-shell').wait_for(timeout=60000)
    setup = page.get_by_test_id('onboarding-modal')
    try:
        await setup.wait_for(timeout=3000)
    except Exception:
        pass
    if await setup.count() and await setup.is_visible():
        await setup.get_by_role('button', name='Skip setup', exact=True).click()
    return versions


async def open_files(page):
    toggle = await visible(page, 'workspace-explorer-toggle')
    await toggle.wait_for(timeout=45000)
    if await toggle.get_attribute('aria-expanded') != 'true':
        await toggle.click()
    await (await visible(page, 'workspace-tab-files')).click()
    tree = await visible(page, 'file-explorer-tree-scroll')
    await tree.wait_for()
    return tree


async def read_proof(page, host):
    tree = await open_files(page)
    await tree.get_by_text('proof.txt', exact=True).click()
    editor = await visible(page, 'file-source-editor')
    await editor.wait_for()
    expected = host.remote(['cat', host.workspace + '/proof.txt']).decode().strip()
    for _ in range(100):
        if expected and expected in await editor.inner_text():
            return True
        await asyncio.sleep(.1)
    raise AssertionError('WORKSPACE_TEXT_NOT_SHOWN')


async def editor_terminal_and_restart(page, host, target, row):
    name = 'qa-' + target + '-' + uuid.uuid4().hex[:10] + '.txt'
    content = 'Agent Connect editor ' + uuid.uuid4().hex
    filename = host.workspace + '/' + name
    created = False
    terminal_id = None
    try:
        row['stage'] = 'owned_file_edit_save'
        tree = await open_files(page)
        await (await visible(page, 'files-new-file')).click()
        entry = await visible(page, 'file-explorer-name-input')
        await entry.fill(name)
        await entry.press('Enter')
        await tree.get_by_text(name, exact=True).wait_for()
        created = True
        await tree.get_by_text(name, exact=True).click()
        editor = (await visible(page, 'file-source-editor')).locator('.cm-content')
        await editor.fill(content)
        await editor.press('Control+s')
        for _ in range(100):
            if host.remote(['cat', filename], allow_failure=True).decode() == content:
                break
            await asyncio.sleep(.1)
        assert host.remote(['cat', filename]).decode() == content, 'EDIT_NOT_SAVED_TO_HOST'
        row['cases'].append({'id': 'file_created_edited_saved_to_real_workspace', 'result': 'PASS'})
        row['stage'] = 'terminal_real_output'
        before = await page.locator('[data-testid^="workspace-tab-terminal_"]').filter(visible=True).evaluate_all('(xs)=>xs.map(x=>x.dataset.testid)')
        await page.get_by_test_id('workspace-pane-main').get_by_test_id('workspace-new-tab-button').click()
        await (await visible(page, 'workspace-new-tab-menu-terminal')).click()
        tabs = page.locator('[data-testid^="workspace-tab-terminal_"]').filter(visible=True)
        ids = []
        for _ in range(100):
            ids = await tabs.evaluate_all('(xs)=>xs.map(x=>x.dataset.testid)')
            if any(x not in before for x in ids):
                break
            await asyncio.sleep(.1)
        tab_id = next(x for x in ids if x not in before)
        terminal_id = tab_id
        tab = await visible(page, tab_id)
        await tab.click(position={'x': 16, 'y': 12})
        pane = tab.locator('xpath=ancestor::*[starts-with(@data-testid,"workspace-pane-")][1]')
        prompt = pane.get_by_test_id('terminal-surface').locator('.xterm-helper-textarea')
        await prompt.wait_for(state='attached')
        await pane.get_by_test_id('terminal-attach-loading').wait_for(state='hidden', timeout=30000)
        marker = 'AC_PTY_' + uuid.uuid4().hex
        escaped = ''.join('\\' + format(ord(c), '03o') for c in marker) + '\\n'
        await prompt.focus()
        await prompt.press('Enter')
        await prompt.press_sequentially("printf '" + escaped + "'", delay=2)
        await prompt.press('Enter')
        await prompt.press('Control+f')
        search = page.get_by_role('textbox', name='Find in pane', exact=True)
        await search.fill(marker)
        status = page.get_by_role('status', name='Find matches', exact=True)
        for _ in range(100):
            if re.search('[1-9]', await status.inner_text()):
                break
            await asyncio.sleep(.1)
        assert re.search('[1-9]', await status.inner_text()), 'NO_ACTUAL_PTY_OUTPUT'
        await page.get_by_label('Find', exact=True).get_by_role('button', name=re.compile('close', re.I)).click()
        row['cases'].append({'id': 'real_pty_output_without_matching_command_echo', 'result': 'PASS'})
        await page.reload(wait_until='domcontentloaded', timeout=60000)
        tab = await visible(page, tab_id)
        await tab.wait_for(timeout=45000)
        await tab.click(position={'x': 16, 'y': 12})
        pane = tab.locator('xpath=ancestor::*[starts-with(@data-testid,"workspace-pane-")][1]')
        prompt = pane.get_by_test_id('terminal-surface').locator('.xterm-helper-textarea')
        await prompt.press('Control+f')
        await page.get_by_role('textbox', name='Find in pane', exact=True).fill(marker)
        status = page.get_by_role('status', name='Find matches', exact=True)
        for _ in range(100):
            if re.search('[1-9]', await status.inner_text()):
                break
            await asyncio.sleep(.1)
        assert re.search('[1-9]', await status.inner_text()), 'PTY_RELOAD_BUFFER_MISSING'
        await page.get_by_label('Find', exact=True).get_by_role('button', name=re.compile('close', re.I)).click()
        row['cases'].append({'id': 'terminal_and_buffer_retained_after_browser_reload', 'result': 'PASS'})
        await prompt.press_sequentially('exit')
        await prompt.press('Enter')
        await tab.wait_for(state='hidden', timeout=30000)
        terminal_id = None
        row['cases'].append({'id': 'owned_terminal_exit_and_cleanup', 'result': 'PASS'})
        row['stage'] = 'daemon_restart_retains_browser_trust'
        host.okay(host.cli('stop'))
        assert host.okay(host.cli('restore'))['daemon']['running'] is False, 'DISABLED_RESTORE_STARTED_DAEMON'
        assert host.okay(host.cli('start'))['daemon']['reachable'], 'DAEMON_NOT_REACHABLE'
        fresh = 'Fresh authenticated read ' + uuid.uuid4().hex
        host.remote(['node', '-e', 'require("fs").writeFileSync(process.argv[1],process.argv[2])', filename, fresh])
        await page.reload(wait_until='domcontentloaded', timeout=60000)
        await (await visible(page, 'workspace-explorer-toggle')).wait_for(timeout=45000)
        tree = await open_files(page)
        await tree.get_by_text(name, exact=True).click()
        editor = await visible(page, 'file-source-editor')
        for _ in range(100):
            if fresh in await editor.inner_text():
                break
            await asyncio.sleep(.1)
        assert fresh in await editor.inner_text() and content not in await editor.inner_text(), 'STALE_BYTES_AFTER_RESTART'
        row['cases'].append({'id': 'same_browser_trust_after_daemon_restart_reads_fresh_server_bytes', 'result': 'PASS'})
        row['stage'] = 'owned_file_delete'
        await tree.get_by_text(name, exact=True).click(button='right')

        async def confirm(dialog):
            if name in dialog.message or 'delete' in dialog.message.lower():
                await dialog.accept()
            else:
                await dialog.dismiss()
        page.once('dialog', confirm)
        await page.get_by_role('menuitem', name='Delete', exact=True).click()
        await tree.get_by_text(name, exact=True).wait_for(state='hidden')
        exists = host.remote(['node', '-e', 'console.log(require("fs").existsSync(process.argv[1]))', filename]).decode().strip()
        assert exists == 'false', 'UI_DELETE_NOT_ON_SERVER'
        created = False
        row['cases'].append({'id': 'owned_file_ui_delete_confirmed_on_server', 'result': 'PASS'})
    finally:
        if created:
            host.remote(['rm', '-f', filename], allow_failure=True)
            row['ownedFileEmergencyCleanup'] = True
        if terminal_id:
            row['terminalCleanupUnconfirmed'] = True


async def core_suite(host, targets=None):
    """The 47-case three-client core suite. Returns a sanitized report."""
    report = {'runtime': host.runtime_identity(require_running=False)['managed'], 'modelCalls': 0, 'clients': []}
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        try:
            for target, origin, relay in PROFILES:
                if targets and target not in targets:
                    continue
                row = {'target': target, 'origin': origin, 'cases': [], 'freshBrowserContext': True}
                report['clients'].append(row)
                context = await browser.new_context(viewport={'width': 1440, 'height': 1000}, locale='en-US', accept_downloads=True)
                page = await context.new_page()
                page.set_default_timeout(20000)
                errors = []
                page.on('pageerror', lambda error: errors.append(type(error).__name__))
                started = time.monotonic()
                try:
                    row['stage'] = 'configure_profile'
                    configured = host.okay(host.cli('configure', workspace=host.workspace, hostName=host.host_name, target=target))
                    if configured['configurationPending'] and configured['daemon']['running']:
                        denied = host.cli('pair')
                        assert denied.get('ok') is False and denied['error']['code'] == 'CONFIGURATION_PENDING', 'PENDING_OFFER_NOT_REFUSED'
                        row['cases'].append({'id': 'pending_target_refuses_private_offer', 'result': 'PASS'})
                    host.okay(host.cli('stop'))
                    assert host.okay(host.cli('restore'))['daemon']['running'] is False, 'DISABLED_RESTORE_STARTED_DAEMON'
                    started_state = host.okay(host.cli('start'))
                    assert started_state['activeTarget'] == target and started_state['configurationPending'] is False, 'TARGET_NOT_ACTIVE'
                    assert started_state['daemon']['version'] == '0.17.5' and started_state['daemon']['reachable'], 'DAEMON_NOT_REACHABLE'
                    row['runtimeIdentity'] = host.runtime_identity()
                    row['cases'].append({'id': 'profile_lifecycle_and_disabled_restore', 'result': 'PASS'})
                    pair = host.okay(host.cli('pair'))
                    url = pair['url']
                    parsed = urlsplit(url)
                    assert parsed.scheme + '://' + parsed.netloc == origin and parsed.path == '/' and not parsed.query and parsed.fragment.startswith('offer='), 'OFFER_URL_SHAPE'
                    encoded = parsed.fragment[6:]
                    offer = json.loads(base64.urlsafe_b64decode(encoded + '=' * ((-len(encoded)) % 4)))
                    assert offer['v'] == 2 and offer['relay'] == {'endpoint': relay, 'useTls': True}, 'OFFER_RELAY_MISMATCH'
                    if target != 'paseo':
                        assert 'minimumSecurityMode' not in offer, 'OFFER_SECURITY_MISMATCH'
                    else:
                        assert offer.get('minimumSecurityMode') == 'protected', 'OFFER_SECURITY_MISMATCH'
                    assert pair.get('sensitive') is True, 'OFFER_NOT_SENSITIVE'
                    assert url not in json.dumps(host.okay(host.cli('status'))), 'OFFER_LEAKED_IN_STATUS'
                    row['cases'].append({'id': 'exact_origin_v2_relay_tls_and_security', 'result': 'PASS'})
                    row['stage'] = 'fresh_browser_pair'
                    row['visibleVersions'] = await connect_offer(page, url, origin)
                    url = pair = offer = encoded = None
                    row['cases'].append({'id': 'fresh_explicit_browser_pair', 'result': 'PASS'})
                    info = host.bootstrap()
                    row['serverIdentitySha256'] = hashlib.sha256(info['serverId'].encode()).hexdigest()
                    workspace_url = origin + '/h/' + info['serverId'] + '/workspace/' + info['workspaceId']
                    row['stage'] = 'workspace_files'
                    await page.goto(workspace_url, wait_until='domcontentloaded', timeout=60000)
                    tree = await open_files(page)
                    await tree.get_by_text('proof.txt', exact=True).click()
                    editor = await visible(page, 'file-source-editor')
                    await editor.wait_for()
                    expected = host.remote(['cat', host.workspace + '/proof.txt']).decode().strip()
                    for _ in range(100):
                        if expected and expected in await editor.inner_text():
                            break
                        await asyncio.sleep(.1)
                    assert expected and expected in await editor.inner_text(), 'WORKSPACE_TEXT_NOT_SHOWN'
                    row['cases'].append({'id': 'authenticated_workspace_and_text_read', 'result': 'PASS'})
                    for name in ['proof.txt', 'fixture.zip', 'binary.bin']:
                        expected_hash = hashlib.sha256(host.remote(['cat', host.workspace + '/' + name])).hexdigest()
                        await tree.get_by_text(name, exact=True).click(button='right')
                        async with page.expect_download(timeout=30000) as event:
                            await page.get_by_role('menuitem', name='Download', exact=True).click()
                        download = await event.value
                        file = await download.path()
                        assert hashlib.sha256(Path(file).read_bytes()).hexdigest() == expected_hash, 'DOWNLOAD_HASH_MISMATCH'
                        row['cases'].append({'id': 'actual_browser_download_' + name, 'result': 'PASS', 'sha256': expected_hash})
                    row['stage'] = 'reconnect_reload'
                    await page.reload(wait_until='domcontentloaded', timeout=60000)
                    await (await visible(page, 'workspace-explorer-toggle')).wait_for(timeout=45000)
                    row['cases'].append({'id': 'paired_context_reload_without_new_offer', 'result': 'PASS'})
                    await editor_terminal_and_restart(page, host, target, row)
                    row['stage'] = 'unpaired_isolation'
                    isolated = await browser.new_context(viewport={'width': 1440, 'height': 1000}, locale='en-US')
                    try:
                        outsider = await isolated.new_page()
                        await outsider.goto(workspace_url, wait_until='domcontentloaded', timeout=60000)
                        await outsider.wait_for_function('document.body.innerText.trim().length>30', timeout=45000)
                        assert not await outsider.get_by_test_id('file-explorer-tree-scroll').filter(visible=True).count(), 'UNPAIRED_SEES_FILES'
                        assert expected not in await outsider.locator('body').inner_text(), 'UNPAIRED_READS_FIXTURE'
                        row['cases'].append({'id': 'fresh_unpaired_context_cannot_read_fixture', 'result': 'PASS'})
                    finally:
                        await isolated.close()
                    row['result'] = 'PASS_FOR_EXECUTED_CASES'
                except Exception as error:
                    row.update(result='FAIL', **failure(error))
                finally:
                    row['pageErrors'] = errors
                    row['durationSeconds'] = round(time.monotonic() - started)
                    await context.close()
                    log('core_client_done', target=target, result=row['result'], cases=len(row['cases']),
                        failedStage=row.get('stage') if row['result'] == 'FAIL' else None)
        finally:
            await browser.close()
            try:
                host.okay(host.cli('stop'))
                host.okay(host.cli('configure', workspace=host.workspace, target='paseo'))
                host.okay(host.cli('start'))
            except Exception:
                report['officialProfileRestore'] = 'FAILED'
    report['caseCount'] = sum(len(c['cases']) for c in report['clients'])
    report['result'] = 'PASS' if report['clients'] and all(c['result'] == 'PASS_FOR_EXECUTED_CASES' for c in report['clients']) else 'FAIL'
    return report


async def trust_persistence(host, actions, target='paseo'):
    """Pair one fresh browser, then for each (name, action) run the host action and prove the SAME browser
    reaches the workspace again without a new offer, with the same server identity."""
    origin, _relay = next((o, r) for t, o, r in PROFILES if t == target)
    report = {'target': target, 'cases': [], 'modelCalls': 0}
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        context = await browser.new_context(viewport={'width': 1440, 'height': 1000}, locale='en-US')
        page = await context.new_page()
        page.set_default_timeout(20000)
        stage = 'pair'
        try:
            host.okay(host.cli('configure', workspace=host.workspace, hostName=host.host_name, target=target))
            host.okay(host.cli('stop'))
            assert host.okay(host.cli('start'))['daemon']['reachable'], 'DAEMON_NOT_REACHABLE'
            pair = host.okay(host.cli('pair'))
            await connect_offer(page, pair['url'], origin)
            pair = None
            info = host.bootstrap()
            server_hash = hashlib.sha256(info['serverId'].encode()).hexdigest()
            report['serverIdentitySha256'] = server_hash
            await page.goto(origin + '/h/' + info['serverId'] + '/workspace/' + info['workspaceId'],
                            wait_until='domcontentloaded', timeout=60000)
            await read_proof(page, host)
            report['cases'].append({'id': 'paired_before_host_actions', 'result': 'PASS'})
            for name, action, expect_running in actions:
                stage = name
                t0 = time.monotonic()
                await asyncio.to_thread(action)
                deadline = time.monotonic() + 600
                status = None
                while time.monotonic() < deadline:
                    try:
                        status = host.cli('status')
                        if status.get('ok') and bool(status['daemon'].get('running')) == expect_running and \
                                (not expect_running or status['daemon'].get('reachable')):
                            break
                    except Exception:
                        pass
                    await asyncio.sleep(3)
                else:
                    raise AssertionError('DAEMON_STATE_NOT_RESTORED')
                row = {'id': name, 'daemonRunning': expect_running, 'secondsUntilRestored': round(time.monotonic() - t0)}
                if expect_running:
                    again = host.bootstrap()
                    assert hashlib.sha256(again['serverId'].encode()).hexdigest() == server_hash, 'SERVER_IDENTITY_CHANGED'
                    host.runtime_identity()
                    for attempt in range(10):
                        try:
                            await page.reload(wait_until='domcontentloaded', timeout=60000)
                            await read_proof(page, host)
                            break
                        except (BrowserError, AssertionError):
                            if attempt == 9:
                                raise AssertionError('PAIRED_BROWSER_NOT_RECONNECTED')
                            await asyncio.sleep(6)
                    row.update(sameServerIdentity=True, pairedBrowserReconnectedWithoutNewOffer=True,
                               reloadAttempts=attempt + 1)
                row['result'] = 'PASS'
                report['cases'].append(row)
                log('persistence_case', **{k: v for k, v in row.items() if k != 'id'}, case=name)
            report['result'] = 'PASS'
        except Exception as error:
            report.update(result='FAIL', failedStage=stage, **failure(error))
        finally:
            await context.close()
            await browser.close()
    return report


async def native_panel(open_workbench, host_label):
    """Native code-server panel through the real front door: activation, the three targets, one status read.
    `open_workbench(page)` must return the frame that hosts the VS Code workbench."""
    report = {'host': host_label, 'cases': [], 'backendActions': ['status'], 'modelCalls': 0}
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        context = await browser.new_context(viewport={'width': 1440, 'height': 1100}, locale='en-US')
        page = await context.new_page()
        page.set_default_timeout(20000)
        stage = 'open_workbench'
        try:
            work = await open_workbench(page)
            await work.locator('.monaco-workbench').wait_for(timeout=60000)
            trust = work.get_by_role('button', name=re.compile('Yes, I trust'))
            if await trust.count() and await trust.first.is_visible():
                await trust.first.click()
            stage = 'activity_bar'
            await work.locator('.activitybar [aria-label*="Agent Connect"]').first.wait_for(timeout=60000)
            report['cases'].append({'id': 'workbench_loads_with_agent_connect_activity', 'result': 'PASS'})
            stage = 'panel'
            tree = work.get_by_role('treeitem', name=re.compile('Configure & connect'))
            if not await tree.count() or not await tree.first.is_visible():
                await work.locator('.activitybar [aria-label*="Agent Connect"]').first.click()
            await tree.first.wait_for(timeout=20000)
            await tree.first.click()
            frame = None
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline and frame is None:
                for candidate in list(page.frames):
                    if candidate.is_detached():
                        continue
                    try:
                        heading = candidate.get_by_role('heading', name='Agent Connect', exact=True)
                        if await heading.count() and await heading.first.is_visible():
                            frame = candidate
                            break
                    except BrowserError:
                        continue
                await asyncio.sleep(.3)
            assert frame, 'NATIVE_PANEL_MISSING'
            options = await frame.locator('#web-client option').all_text_contents()
            assert options == ['Choose a Web app', 'Paseo official', 'Woowtech Smart', 'Apporo Smart'], 'TARGET_PROFILES_MISMATCH'
            assert await frame.locator('input[name=webUrl]').get_attribute('readonly') is not None, 'TARGET_URL_EDITABLE'
            report['cases'].append({'id': 'native_panel_three_targets_read_only_url', 'result': 'PASS'})
            stage = 'status_read'
            await frame.locator('button[data-action=status]').click(timeout=20000)
            await frame.locator('#phase').filter(has_text=re.compile(r'^Connection: (?!unknown$)\S+')).wait_for(timeout=45000)
            phase = (await frame.locator('#phase').inner_text()).strip()
            body = await frame.locator('body').inner_text()
            assert 'offer=' not in body and '#offer' not in body, 'PRIVATE_OFFER_VISIBLE'
            report['cases'].append({'id': 'native_status_read_through_front_door', 'result': 'PASS',
                                    'phase': phase if re.fullmatch(r'Connection: [A-Za-z_ -]{1,40}', phase) else 'other'})
            report['result'] = 'PASS'
        except Exception as error:
            report.update(result='FAIL', failedStage=stage, **failure(error))
        finally:
            await context.close()
            await browser.close()
    return report
