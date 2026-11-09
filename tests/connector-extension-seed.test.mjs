import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {seed} from '../connectors/seed-extensions.mjs';

function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'woow-extension-seed-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  const bundle = path.join(dir, 'bundle'); fs.mkdirSync(bundle);
  const entries = ['paseo', 'omnigent'].map(name => {
    const file = name + '.vsix'; fs.writeFileSync(path.join(bundle, file), name);
    return {id: 'woowtech.' + name, version: '0.1.0', file, sha256: crypto.createHash('sha256').update(name).digest('hex')};
  });
  fs.writeFileSync(path.join(bundle, 'manifest.json'), JSON.stringify(entries));
  const env = {WOOW_CONNECTOR_DATA_DIR: path.join(dir, 'state'), WOOW_CONNECTOR_VSIX_DIR: bundle, WOOW_CODE_EXTENSIONS_DIR: path.join(dir, 'extensions')};
  const installed = new Map(), installs = [];
  const run = (command, args) => {
    if (args.includes('--list-extensions')) return [...installed].map(([id, version]) => id + '@' + version).join('\n');
    const file = path.basename(args[args.indexOf('--install-extension') + 1]);
    const entry = entries.find(x => x.file === file); installs.push(entry.id); installed.set(entry.id, entry.version); return '';
  };
  return {dir, bundle, env, installed, installs, entries, run};
}

test('fresh boot installs both; next boot is idempotent and respects uninstall across upgrades', t => {
  const f = fixture(t);
  seed(f); assert.equal(f.installs.length, 2);
  seed(f); assert.equal(f.installs.length, 2);
  f.installed.delete('woowtech.paseo'); seed(f);
  f.entries[0].version = '0.2.0';
  fs.writeFileSync(path.join(f.bundle, 'manifest.json'), JSON.stringify(f.entries));
  seed(f); assert.equal(f.installs.length, 2); assert.equal(f.installed.has('woowtech.paseo'), false);
});

test('user versions are preserved while a managed old version can upgrade', t => {
  const f = fixture(t); f.installed.set('woowtech.paseo', '0.9.0');
  seed(f); assert.deepEqual(f.installs, ['woowtech.omnigent']);
  f.entries[1].version = '0.2.0'; fs.writeFileSync(path.join(f.bundle, 'manifest.json'), JSON.stringify(f.entries));
  seed(f); assert.equal(f.installed.get('woowtech.omnigent'), '0.2.0'); assert.equal(f.installed.get('woowtech.paseo'), '0.9.0');
});

test('tampered VSIX is rejected before executing code-server', t => {
  const f = fixture(t); fs.writeFileSync(path.join(f.bundle, 'paseo.vsix'), 'tampered');
  assert.throws(() => seed({...f, run: () => {throw new Error('should not run');}}), /checksum/);
  assert.equal(fs.existsSync(path.join(f.env.WOOW_CONNECTOR_DATA_DIR, 'extensions.json')), false);
});

test('failed installation leaves no success receipt and can retry', t => {
  const f = fixture(t);
  assert.throws(() => seed({...f, run: (command, args) => {
    if (args.includes('--install-extension')) throw new Error('offline'); return f.run(command, args);
  }}), /offline/);
  assert.equal(fs.existsSync(path.join(f.env.WOOW_CONNECTOR_DATA_DIR, 'extensions.json')), false);
  seed(f); assert.equal(f.installs.length, 2);
});
