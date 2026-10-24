#!/usr/bin/env node
// Lists the MCP tools and round-trips `status` and `voices` against an installed app (the app must be running).
// Usage: node mcp/check-mcp.mjs "/Applications/JuniorOS Apps/Talk & Read.app"
// Exit 0 when every step passes, 1 otherwise. Uses the adapter inside the given app bundle.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

const app = process.argv[2];
if (!app) { console.error('usage: node check-mcp.mjs "/path/to/Talk & Read.app"'); process.exit(1); }
const adapter = join(app, 'Contents', 'Resources', 'mcp', 'talkread-mcp.mjs');
if (!existsSync(adapter)) { console.error(`FAIL no adapter at ${adapter}`); process.exit(1); }

const child = spawn(process.execPath, [adapter], { stdio: ['pipe', 'pipe', 'inherit'] });
const pending = new Map();
let buffer = '';
child.stdout.setEncoding('utf8').on('data', chunk => {
  buffer += chunk;
  for (let i = buffer.indexOf('\n'); i >= 0; i = buffer.indexOf('\n')) {
    const message = JSON.parse(buffer.slice(0, i));
    buffer = buffer.slice(i + 1);
    pending.get(message.id)?.(message);
  }
});
child.on('exit', code => { if (code) { console.error(`FAIL adapter exited with ${code}`); process.exit(1); } });

let nextId = 1;
function rpc(method, params, seconds = 60) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${method} timed out after ${seconds} s`)), seconds * 1000);
    pending.set(id, message => { clearTimeout(timer); resolve(message); });
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
  });
}

function check(condition, label, detail = '') {
  console.log(`${condition ? 'ok  ' : 'FAIL'} ${label}${detail ? `  ${detail}` : ''}`);
  if (!condition) { child.kill(); process.exit(1); }
}

try {
  const init = await rpc('initialize', {});
  check(init.result?.serverInfo?.name === 'talkread', 'initialize', `version ${init.result?.serverInfo?.version}`);
  const listed = await rpc('tools/list');
  const names = (listed.result?.tools ?? []).map(tool => tool.name);
  check(names.length >= 21 && ['status', 'voices', 'speak', 'dictate_file', 'mic', 'update_check'].every(n => names.includes(n)), 'tools/list', `${names.length} tools`);
  for (const name of ['status', 'voices']) {
    const called = await rpc('tools/call', { name, arguments: {} });
    const body = JSON.parse(called.result?.content?.[0]?.text ?? '{}');
    check(called.result?.isError === false && body.ok === true, `call ${name}`, called.result?.content?.[0]?.text.slice(0, 120));
  }
  console.log('MCP check passed');
  child.kill();
  process.exit(0);
} catch (error) {
  console.error(`FAIL ${error.message}`);
  child.kill();
  process.exit(1);
}
