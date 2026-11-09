import {test} from 'node:test';
import assert from 'node:assert/strict';
import {Readable} from 'node:stream';
import {dispatch, readRequest} from '../connectors/cli.mjs';

test('dispatch never loads a user-selected module or unknown action', async () => {
  const loaded = [];
  const loader = async name => {loaded.push(name); throw new Error('unexpected');};
  for (const request of [null, [], {connector: '../foreign', action: 'start'}, {connector: '__proto__', action: 'start'}, {connector: 'paseo', action: 'shell'}]) {
    assert.equal((await dispatch(request, loader)).error.code, 'INVALID_REQUEST');
  }
  assert.deepEqual(loaded, []);
});

test('password reaches only the selected handler; arbitrary errors cannot echo it', async () => {
  const request = {connector: 'omnigent', action: 'connect', password: 'SECRET_SENTINEL'};
  const result = await dispatch(request, async name => ({handle: async input => {
    assert.equal(name, 'omnigent'); assert.equal(input.password, request.password);
    throw new Error('backend rejected SECRET_SENTINEL');
  }}));
  assert.equal(result.ok, false); assert.ok(!JSON.stringify(result).includes(request.password));
});

test('missing runtime and invalid handler output remain explicit failures', async () => {
  const missing = await dispatch({connector: 'paseo', action: 'status'}, async () => {throw Object.assign(new Error('missing'), {code: 'ERR_MODULE_NOT_FOUND'});});
  assert.equal(missing.error.code, 'RUNTIME_MISSING');
  const malformed = await dispatch({connector: 'paseo', action: 'status'}, async () => ({handle: async () => ({running: true})}));
  assert.equal(malformed.error.code, 'INVALID_RESPONSE');
});

test('stream accepts one JSON request and bounds data and waiting', async () => {
  assert.deepEqual(await readRequest(Readable.from(['{"connector":', '"paseo","action":"status"}'])), {connector: 'paseo', action: 'status'});
  await assert.rejects(readRequest(Readable.from(['{}{}'])));
  await assert.rejects(readRequest(Readable.from([' '.repeat(20)]), {maxBytes: 10}));
  const blocked = new Readable({read() {}});
  await assert.rejects(readRequest(blocked, {timeoutMs: 10})); blocked.destroy();
});
