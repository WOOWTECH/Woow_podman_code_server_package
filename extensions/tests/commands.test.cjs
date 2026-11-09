'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createExtension } = require('../shared/extension.cjs');
const { html } = require('../shared/ui.cjs');
function harness(connector, responses={}) {
  const commands=new Map(), calls=[], logs=[], updates=[], notices=[], opened=[], posted=[], inputOptions=[];
  const values={runtimePath:'/usr/local/bin/woow-connectors',workspace:'/workspace',hostName:'test',server:'https://omnigent.example.org',webUrl:'https://app.paseo.sh'};
  const inputs=[], picks=[];
  let receive;
  const disposable={dispose(){}};
  const panel={webview:{html:'',postMessage:message=>posted.push(message),onDidReceiveMessage:fn=>{receive=fn;return disposable;}},reveal(){},onDidDispose(){return disposable;},dispose(){}};
  const vscode={
    ConfigurationTarget:{Global:1},ViewColumn:{One:1},Uri:{parse:value=>value},
    EventEmitter:class {event=()=>{};fire(){}dispose(){}},
    workspace:{isTrusted:true,getConfiguration:()=>({inspect:key=>({defaultValue:values[key]}),update:async(key,value)=>{updates.push([key,value]);values[key]=value;}}),onDidChangeConfiguration:()=>disposable},
    env:{openExternal:async url=>{opened.push(url);return true;}},
    commands:{registerCommand:(id,fn)=>{commands.set(id,fn);return disposable;},executeCommand:async()=>{}},
    window:{createOutputChannel:()=>({appendLine:line=>logs.push(line),dispose(){}}),registerTreeDataProvider:()=>disposable,createWebviewPanel:()=>panel,showInputBox:async options=>{inputOptions.push(options);return inputs.shift();},showQuickPick:async()=>picks.shift(),showInformationMessage:async text=>notices.push(text),showErrorMessage:async text=>notices.push(text)},
  };
  const ext=createExtension(connector,{vscode,createRuntime:options=>async request=>{calls.push(request);const response=responses[request.action]??{ok:true,phase:'online'};options.onEvent({connector,action:request.action,ok:response.ok});return response;}});
  const api=ext.activate({subscriptions:[]});
  return {ext,api,vscode,commands,calls,logs,updates,notices,opened,posted,inputs,picks,inputOptions,panel,receive:message=>receive(message)};
}
test('activation and window deactivation do not start or stop backend processes', () => {
  for(const name of ['paseo','omnigent']) {const h=harness(name);assert.equal(h.calls.length,0);assert.ok(h.commands.has(`woow.${name}.configure`));h.ext.deactivate();assert.equal(h.calls.length,0);}
});
test('native commands dispatch explicit connector actions; configure fields remain top-level', async () => {
  const h=harness('paseo');
  await h.commands.get('woow.paseo.start')();
  assert.deepEqual(h.calls[0],{connector:'paseo',action:'start'});
  await h.api.perform('configure',{workspace:'/workspace/team',hostName:'my host',webUrl:'https://app.paseo.sh'});
  assert.deepEqual(h.calls.find(c=>c.action==='configure'),{connector:'paseo',action:'configure',workspace:'/workspace/team',hostName:'my host'});
  assert.equal(h.updates.some(([key])=>key==='workspace'),true);
});
test('Omnigent sign-in prompts masked password and never persists or renders it', async () => {
  const h=harness('omnigent');h.inputs.push('operator','private-password-value');
  await h.commands.get('woow.omnigent.connect')();
  const request=h.calls.find(c=>c.action==='connect');
  assert.equal(request.password,'private-password-value');assert.equal(request.username,'operator');assert.equal(h.inputOptions[1].password,true);
  assert.equal(JSON.stringify([h.logs,h.updates,h.notices,h.posted,h.api.getPublicState()]).includes('private-password-value'),false);
});
test('cancelled sign-in performs no connect and untrusted workspace cannot start', async () => {
  const h=harness('omnigent');h.inputs.push(undefined);
  await h.commands.get('woow.omnigent.connect')();assert.equal(h.calls.some(c=>c.action==='connect'),false);
  h.vscode.workspace.isTrusted=false;await h.commands.get('woow.omnigent.start')();assert.equal(h.calls.some(c=>c.action==='start'),false);
});
test('pair opens private URL only on explicit action without rendering or logging', async () => {
  const privateUrl='https://app.paseo.sh/#private-pairing-credential';
  const h=harness('paseo',{pair:{ok:true,pairingUrl:privateUrl}});
  h.commands.get('woow.paseo.open')();assert.equal(h.opened.length,0);
  await h.commands.get('woow.paseo.pair')();assert.deepEqual(h.opened,[privateUrl]);
  assert.equal(JSON.stringify([h.logs,h.posted,h.updates,h.api.getPublicState()]).includes('private-pairing'),false);
  const bad=harness('paseo',{pair:{ok:true,url:'https://unrelated.example/#private'}});
  await bad.commands.get('woow.paseo.pair')();assert.equal(bad.opened.length,0);
});
test('verify passes selected engine and model; success requires explicit verification evidence', async () => {
  const h=harness('paseo',{models:{ok:true,models:[{agent:'codex',id:'test-model',name:'Test model'}]},verify:{ok:true}});
  h.picks.push({label:'Codex',engine:'codex'},{model:'test-model'});
  await h.commands.get('woow.paseo.verify')();
  assert.deepEqual(h.calls.find(c=>c.action==='verify'),{connector:'paseo',action:'verify',engine:'codex',model:'test-model'});
  assert.equal(h.notices.some(n=>n.includes('has not reported a verified reply')),true);
  assert.equal(h.api.getPublicState().verification,'unverified');
});
test('webview rejects unsupported messages and connector-mismatched actions', async () => {
  const h=harness('paseo');h.commands.get('woow.paseo.open')();
  h.receive({action:'exec',command:'bash'});h.receive({action:'connect'});h.receive({action:'start',fields:{connector:'omnigent'}});
  await new Promise(resolve=>setImmediate(resolve));assert.equal(h.calls.length,0);
  const markup=html('omnigent');assert.ok(markup.includes("default-src 'none'"));assert.ok(markup.includes("form-action 'none'"));
  assert.equal(markup.includes('innerHTML'),false);assert.equal(markup.includes('setState'),false);assert.equal(markup.includes('type="password"'),false);
});
test('native status command reports connection and separate unverified state without webview', async () => {
  const h=harness('paseo');await h.commands.get('woow.paseo.status')();
  assert.ok(h.notices.some(message=>message.includes('connection online; conversation unverified')));
});
test('activity-bar container IDs meet the live VS Code contribution schema', () => {
  for (const connector of ['paseo','omnigent']) {
    const manifest=require(`../${connector}/package.json`);
    const id=manifest.contributes.viewsContainers.activitybar[0].id;
    assert.match(id,/^[a-zA-Z0-9_-]+$/);
    assert.ok(manifest.contributes.views[id].some(view=>view.id===`woow.${connector}.statusView`));
  }
});
