import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { launchBrowser, freshPage, pairBrowser, openProjectInBrowser, BrowserCheckError, safeFailure, validatePairUrl } from './browser-support.mjs';

const fail = code => { throw new BrowserCheckError(code); };
const providers = ['claude', 'codex', 'pi'];

export function validatePlan(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail('INVALID_BROWSER_PLAN');
  validatePairUrl(value.pairUrl);
  if (typeof value.workspace !== 'string' || !path.isAbsolute(value.workspace) || /[\x00-\x1f]/.test(value.workspace)) fail('INVALID_WORKSPACE');
  if (value.mode === 'pair') return value;
  if (value.allowModelCalls !== true) fail('MODEL_CALLS_NOT_AUTHORIZED');
  if (!Array.isArray(value.providers) || value.providers.length !== 3 || providers.some(id => value.providers.filter(row => row.id === id).length !== 1)) fail('THREE_PROVIDERS_REQUIRED');
  for (const row of value.providers) {
    if (!Array.isArray(row.models) || row.models.length !== 2 || row.models[0].id === row.models[1].id) fail('TWO_DISTINCT_MODELS_REQUIRED');
    if (row.models.some(model => typeof model.id !== 'string' || !/^[A-Za-z0-9_./:+-]{1,200}$/.test(model.id) || typeof model.label !== 'string' || !model.label || model.label.length > 200)) fail('INVALID_MODEL_SELECTION');
  }
  if (value.turnTimeoutMs !== undefined && (!Number.isInteger(value.turnTimeoutMs) || value.turnTimeoutMs < 1000 || value.turnTimeoutMs > 600000)) fail('INVALID_TIMEOUT');
  return value;
}

export function readPrivatePlan(file) {
  if (!file || !path.isAbsolute(file)) fail('PRIVATE_PLAN_REQUIRED');
  const checkout = fileURLToPath(new URL('../../../', import.meta.url));
  if (path.resolve(file).startsWith(checkout)) fail('PLAN_MUST_BE_OUTSIDE_GIT_CHECKOUT');
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid() || (stat.mode & 0o077) || stat.size > 65536) fail('UNSAFE_PLAN_FILE');
  return validatePlan(JSON.parse(fs.readFileSync(file, 'utf8')));
}

export async function chooseModelInBrowser(page, provider, model) {
  await page.getByTestId('combined-model-selector').filter({ visible: true }).first().click();
  const row = page.getByTestId(`model-row-${provider}-${model.id}`).filter({ visible: true });
  if (!(await row.count())) {
    const providerRow = page.getByTestId(`model-provider-${provider}`).filter({ visible: true });
    if (!(await providerRow.count())) {
      const back = page.getByRole('dialog').getByRole('button', { name: 'Back', exact: true });
      if (await back.isVisible()) await back.click();
    }
    if (await providerRow.count()) await providerRow.click();
  }
  await row.first().waitFor({ timeout: 30000 });
  await row.first().click();
  const selected = page.getByRole('button', { name: `Select model (${model.label})`, exact: true }).filter({ visible: true });
  await selected.first().waitFor({ timeout: 15000 });
}

export async function waitForNewAssistant(page, previousCount, marker, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    // Only assistant DOM nodes count. The user prompt/previous turn cannot satisfy this.
    const assistant = page.getByTestId('assistant-message').filter({ visible: true });
    const count = await assistant.count();
    if (count > previousCount && (await assistant.last().innerText()).includes(marker)) {
      const working = page.getByTestId('turn-working-indicator').filter({ visible: true });
      if (!(await working.count())) return { assistantCount: count, replyMatched: true };
    }
    await page.waitForTimeout(500);
  }
  fail('NEW_ASSISTANT_REPLY_NOT_VERIFIED');
}

async function selectedAgentId(page) {
  const tab = page.locator('[data-testid^="workspace-tab-agent_"]').filter({ visible: true }).last();
  await tab.waitFor({ timeout: 30000 });
  const id = (await tab.getAttribute('data-testid')).slice('workspace-tab-agent_'.length);
  if (!/^[A-Za-z0-9_-]{8,100}$/.test(id)) fail('AGENT_ID_UNAVAILABLE');
  return id;
}

async function checkRuntime(inspect, input) {
  const result = await inspect(input);
  if (!result || result.ok !== true || result.provider !== input.provider || result.model !== input.model || result.assistantMarkerMatched !== true || !result.cursor) fail('RUNTIME_REPLY_OR_MODEL_UNCONFIRMED');
  if (input.previousCursor && result.cursor === input.previousCursor) fail('RUNTIME_REPLY_NOT_NEW');
  return result;
}

async function closeTestAgent(page, agentId) {
  const tab = page.getByTestId(`workspace-tab-agent_${agentId}`).filter({ visible: true }).first();
  if (await page.getByTestId('turn-working-indicator').filter({ visible: true }).count()) {
    await page.getByRole('button', { name: /stop|cancel/i }).filter({ visible: true }).first().click();
    await page.getByTestId('turn-working-indicator').filter({ visible: true }).first().waitFor({ state: 'hidden', timeout: 30000 });
  }
  await tab.hover();
  await page.getByTestId(`workspace-agent-close-${agentId}`).filter({ visible: true }).first().click();
  await tab.waitFor({ state: 'hidden', timeout: 30000 });
}

export async function runAcceptance(page, plan, inspect) {
  await pairBrowser(page, plan.pairUrl);
  const newAgentUrl = await openProjectInBrowser(page, plan.workspace);
  if (plan.mode === 'pair') return { ok: true, pairingConfirmedInBrowser: true, remoteDirectoryOpenedThroughBrowser: true, realModelsTested: false };
  if (typeof inspect !== 'function') fail('RUNTIME_INSPECTOR_REQUIRED');
  const results = [];
  for (const selection of plan.providers) {
    const row = { provider: selection.id, passed: false, uiCreated: false, twoTurns: false, modelSwitch: false, runtimeVerified: false, cleanupConfirmed: false };
    let id, submitted = false, priorTabs = [], stage = 'open_new_conversation';
    try {
      await page.goto(newAgentUrl, { waitUntil: 'domcontentloaded', timeout: 45000 });
      const composer = page.getByRole('textbox', { name: 'Message agent...' }).first();
      await composer.waitFor();
      stage = 'select_initial_model';
      await chooseModelInBrowser(page, selection.id, selection.models[0]);
      const marker = `WOOW_WEB_${randomUUID().replaceAll('-', '').slice(0, 16)}`;
      const previousCount = await page.getByTestId('assistant-message').filter({ visible: true }).count();
      await composer.fill(`Connection test only. Do not use tools or edit files. Remember ${marker} and reply with exactly that marker.`);
      priorTabs = await page.locator('[data-testid^="workspace-tab-agent_"]').evaluateAll(nodes => nodes.map(node => node.getAttribute('data-testid')));
      await page.getByTestId('message-input-root').getByRole('button', { name: 'Create', exact: true }).click();
      submitted = true;
      stage = 'first_reply';
      id = await selectedAgentId(page);
      row.agentId = id; row.uiCreated = true;
      await waitForNewAssistant(page, previousCount, marker, plan.turnTimeoutMs || 180000);
      stage = 'inspect_first_reply';
      const first = await checkRuntime(inspect, { agentId: id, provider: selection.id, model: selection.models[0].id, marker });
      const beforeSecond = await page.getByTestId('assistant-message').filter({ visible: true }).count();
      stage = 'switch_model_in_browser';
      await chooseModelInBrowser(page, selection.id, selection.models[1]);
      await composer.fill('What marker did I ask you to remember? Reply with the marker only. Do not use tools.');
      await composer.press('Enter');
      stage = 'second_reply';
      await waitForNewAssistant(page, beforeSecond, marker, plan.turnTimeoutMs || 180000);
      stage = 'inspect_second_reply';
      await checkRuntime(inspect, { agentId: id, provider: selection.id, model: selection.models[1].id, marker, previousCursor: first.cursor });
      row.twoTurns = true; row.modelSwitch = true; row.runtimeVerified = true;
      row.models = selection.models.map(model => model.id);
      row.sameAgent = (await selectedAgentId(page)) === id;
    } catch (error) {
      row.error = safeFailure(error).error;
      row.failedStage = stage;
    } finally {
      if (!id && submitted) {
        const candidates = await page.locator('[data-testid^="workspace-tab-agent_"]').filter({ visible: true }).evaluateAll(nodes => nodes.map(node => node.getAttribute('data-testid'))).catch(() => []);
        const created = candidates.filter(candidate => !priorTabs.includes(candidate));
        if (created.length === 1) {
          id = created[0].slice('workspace-tab-agent_'.length);
          row.agentId = id;
        }
      }
      if (id) {
        try {
          await closeTestAgent(page, id);
          const archived = await inspect({ agentId: id, archiveOnly: true });
          row.cleanupConfirmed = archived?.ok === true && archived.archived === true;
        } catch { row.cleanupConfirmed = false; }
      }
      row.passed = row.twoTurns && row.modelSwitch && row.sameAgent === true && row.runtimeVerified && row.cleanupConfirmed;
      results.push(row);
    }
  }
  return { ok: results.length === 3 && results.every(row => row.passed), pairingConfirmedInBrowser: true, realModelsTested: true, providers: results };
}

export async function main() {
  let browser;
  try {
    const plan = readPrivatePlan(process.env.WOOW_PASEO_WEB_PLAN);
    let inspect;
    if (plan.mode !== 'pair') {
      if (!process.env.WOOW_PASEO_INSPECT_MODULE) fail('RUNTIME_INSPECTOR_REQUIRED');
      ({ inspect } = await import(pathToFileURL(process.env.WOOW_PASEO_INSPECT_MODULE).href));
      if (typeof inspect !== 'function') fail('RUNTIME_INSPECTOR_REQUIRED');
    }
    browser = await launchBrowser();
    const { page } = await freshPage(browser);
    const result = await runAcceptance(page, plan, inspect);
    process.stdout.write(JSON.stringify(result) + '\n');
    if (!result.ok) process.exitCode = 1;
  } catch (error) {
    process.stdout.write(JSON.stringify(safeFailure(error)) + '\n'); process.exitCode = 1;
  } finally { await browser?.close(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main();
