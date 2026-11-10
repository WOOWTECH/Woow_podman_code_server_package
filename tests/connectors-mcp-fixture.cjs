// Explicit live acceptance fixture; never configured by normal installation.
const fs = require('node:fs'), crypto = require('node:crypto'), readline = require('node:readline');
readline.createInterface({input: process.stdin}).on('line', line => {
  let request;
  try {request = JSON.parse(line);} catch {return;}
  if (request.id === undefined) return;
  let result;
  if (request.method === 'initialize') result = {protocolVersion:'2024-11-05', capabilities:{tools:{}}, serverInfo:{name:'woow-connector-proof',version:'1.0.0'}};
  else if (request.method === 'tools/list') result = {tools:[{name:'read_proof', description:'Read a fresh proof that the deployment shared skill and MCP are active.', inputSchema:{type:'object',properties:{run:{type:'string',pattern:'^[a-z0-9-]{1,80}$'}},required:['run'],additionalProperties:false}}]};
  else if (request.method === 'tools/call' && request.params?.name === 'read_proof' && /^[a-z0-9-]{1,80}$/.test(request.params.arguments?.run || '')) {
    const proof = 'CONNECTOR-' + crypto.randomBytes(16).toString('hex');
    fs.appendFileSync(process.env.WOOW_CONNECTOR_PROOF_LOG, JSON.stringify({at:new Date().toISOString(),run:request.params.arguments.run,tool:'read_proof',proof}) + '\n', {mode:0o600});
    result = {content:[{type:'text',text:proof}]};
  } else if (request.method === 'ping') result = {};
  else {process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,error:{code:-32601,message:'Method not found or invalid arguments'}})+'\n'); return;}
  process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,result})+'\n');
});
