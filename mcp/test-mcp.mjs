#!/usr/bin/env node
// Protocol test for talkread-mcp.mjs against a fake CLI (TALKREAD_CLI): needs no running app. Run: node mcp/test-mcp.mjs
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const adapter = fileURLToPath(new URL('./talkread-mcp.mjs', import.meta.url));
const dir = await mkdtemp(join(tmpdir(), 'talkread-mcp-'));
const fake = join(dir, 'talkread');
await writeFile(fake, `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'mcp-manifest') {
  console.log(JSON.stringify([
    { name: 'status', description: 'state', inputSchema: { type: 'object', properties: {}, required: [] } },
    { name: 'speak', description: 'read', inputSchema: { type: 'object', properties: { text: { type: 'string' }, force: { type: 'boolean' } }, required: ['text'] } },
    { name: 'dictate_file', description: 'file', inputSchema: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } },
    { name: 'history_delete', description: 'delete', inputSchema: { type: 'object', properties: { id: { type: 'string' }, yes: { type: 'boolean' } }, required: ['id', 'yes'] } }
  ]));
  process.exit(0);
}
if (args[0] === 'dictate-file') { console.log(JSON.stringify({ ok: false, code: 'busy' })); process.exit(1); }
console.log(JSON.stringify({ ok: true, data: { argv: args } }));
`);
await chmod(fake, 0o755);

function start() {
  const child = spawn(process.execPath, [adapter], { env: { ...process.env, TALKREAD_CLI: fake }, stdio: ['pipe', 'pipe', 'pipe'] });
  const lines = [];
  let buffer = '';
  child.stdout.setEncoding('utf8').on('data', chunk => {
    buffer += chunk;
    for (let i = buffer.indexOf('\n'); i >= 0; i = buffer.indexOf('\n')) { lines.push(JSON.parse(buffer.slice(0, i))); buffer = buffer.slice(i + 1); }
  });
  const send = message => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', ...message })}\n`);
  const reply = async id => {
    for (let n = 0; n < 300; n++) {
      const found = lines.find(m => m.id === id);
      if (found) return found;
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    throw new Error(`no reply to ${id}`);
  };
  const call = async (id, name, args) => { send({ id, method: 'tools/call', params: { name, arguments: args } }); return reply(id); };
  return { child, send, reply, call };
}
const argvOf = r => JSON.parse(r.result.content[0].text).data.argv;

try {
  const a = start(), b = start();
  a.send({ id: 1, method: 'initialize' });
  const init = (await a.reply(1)).result;
  assert.equal(init.serverInfo.name, 'talkread');
  assert.equal(init.serverInfo.version, '0.1.0');   // no Info.plist beside this script: fallback
  a.send({ id: 2, method: 'tools/list' });
  assert.deepEqual((await a.reply(2)).result.tools.map(t => t.name), ['status', 'speak', 'dictate_file', 'history_delete']);

  const spoken = await a.call(3, 'speak', { text: '--help me', force: true });
  assert.equal(spoken.result.isError, false);
  const argv = argvOf(spoken);
  assert.deepEqual(argv.slice(0, 3), ['speak', '--text=--help me', '--force']);   // a value starting with -- stays data
  assert.equal(argv[argv.indexOf('--request-id') + 1], '3');
  const callerA = argv[argv.indexOf('--caller') + 1];
  assert.match(callerA, /^mcp-\d+-[0-9a-f-]{36}$/);
  assert.ok(argv.includes('--json'));

  const other = argvOf(await b.call(3, 'speak', { text: 'hi' }));            // same tool-call id, different adapter
  assert.notEqual(other[other.indexOf('--caller') + 1], callerA);
  assert.equal(other.includes('--force'), false);
  for (const id of [4, 5]) {   // the caller is stable for the adapter's life
    const again = argvOf(await a.call(id, 'status', {}));
    assert.equal(again[again.indexOf('--caller') + 1], callerA);
  }

  // A confirmation reaches the CLI as --yes=true (the CLI refuses a destructive command without it, or with false).
  const deleted = argvOf(await a.call(6, 'history_delete', { id: 'abc', yes: true }));
  assert.deepEqual(deleted.slice(0, 3), ['history-delete', '--id=abc', '--yes=true']);

  const failed = await a.call(7, 'dictate_file', { path: '/x' });
  assert.equal(failed.result.isError, true);
  assert.equal(JSON.parse(failed.result.content[0].text).code, 'busy');
  assert.equal((await a.call(8, 'speak', { nope: 1 })).error.code, -32602);
  assert.equal((await a.call(9, 'missing', {})).error.code, -32602);
  a.send({ id: 10, method: 'ping' });
  assert.deepEqual((await a.reply(10)).result, {});
  a.send({ id: 11, method: 'bogus' });
  assert.equal((await a.reply(11)).error.code, -32601);
  a.child.kill(); b.child.kill();

  // The adapter refuses to start when the CLI cannot give a tool list.
  const dead = spawn(process.execPath, [adapter], { env: { ...process.env, TALKREAD_CLI: join(dir, 'missing') }, stdio: 'ignore' });
  assert.equal(await new Promise(resolve => dead.on('close', resolve)), 1);
  console.log('MCP adapter checks passed');
} finally {
  await rm(dir, { recursive: true, force: true });
}
