'use strict';

// Runs the companion's HTTP server against a fake `vscode` API injected as the
// second argument of activate(). No editor, no npm dependencies.
//   node --test companion/test

const test = require('node:test');
const http = require('node:http');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// os.homedir() reads $HOME on POSIX, so the token file lands in a temp dir.
const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'lookout-companion-home-'));
const REAL_HOME = process.env.HOME;
process.env.HOME = TMP_HOME;

const extension = require('../extension.js');
const pkg = require('../package.json');

process.on('exit', () => {
  process.env.HOME = REAL_HOME;
  fs.rmSync(TMP_HOME, { recursive: true, force: true });
});

function asProcessId(value) {
  if (value instanceof Promise) {
    // Mark the rejection handled so the test runner does not see it as an
    // unhandled rejection before the server awaits it.
    value.catch(() => {});
    return value;
  }
  return Promise.resolve(value);
}

function fakeTerminal(name, processId, creationOptions) {
  const calls = { show: [], sendText: [] };
  return {
    name,
    processId: asProcessId(processId),
    creationOptions: creationOptions || {},
    calls,
    show(...args) {
      calls.show.push(args);
    },
    sendText(...args) {
      calls.sendText.push(args);
    }
  };
}

function fakeVscode(options) {
  const opts = options || {};
  const logLines = [];
  const channels = [];
  return {
    logLines,
    channels,
    env: { appName: opts.appName === undefined ? 'Cursor' : opts.appName },
    workspace: {
      name: opts.workspaceName,
      workspaceFolders: opts.folders
        ? opts.folders.map((folder) => ({ uri: { fsPath: folder } }))
        : undefined
    },
    window: {
      terminals: opts.terminals || [],
      activeTerminal: opts.activeTerminal || null,
      createOutputChannel(name) {
        const channel = {
          name,
          disposed: false,
          appendLine(line) {
            logLines.push(line);
          },
          dispose() {
            channel.disposed = true;
          },
          show() {}
        };
        channels.push(channel);
        return channel;
      }
    }
  };
}

async function start(options) {
  const vscode = fakeVscode(options);
  const context = { subscriptions: [] };
  const info = await extension.activate(context, vscode);
  const state = JSON.parse(fs.readFileSync(info.file, 'utf8'));
  return {
    vscode,
    context,
    info,
    state,
    token: state.token,
    base: `http://127.0.0.1:${info.port}`
  };
}

// A one-shot http.request (agent: false) instead of fetch: no connection pool,
// so no sockets outlive a test and keep the runner alive.
function call(base, route, options) {
  const opts = options || {};
  const headers = Object.assign({}, opts.headers);
  if (opts.token) headers.Authorization = `Bearer ${opts.token}`;
  if (opts.body !== undefined) {
    headers['Content-Type'] = 'application/json';
    headers['Content-Length'] = Buffer.byteLength(opts.body);
  }
  const target = new URL(route, base);
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: target.hostname,
        port: target.port,
        path: target.pathname + target.search,
        method: opts.method || 'GET',
        headers,
        agent: false
      },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.once('end', () => {
          const raw = Buffer.concat(chunks).toString('utf8');
          resolve({
            status: res.statusCode,
            raw,
            json: () => JSON.parse(raw)
          });
        });
        res.once('error', reject);
      }
    );
    req.once('error', reject);
    if (opts.body !== undefined) req.write(opts.body);
    req.end();
  });
}

test('every endpoint requires the bearer token', async () => {
  const ctx = await start({ terminals: [fakeTerminal('zsh', 4242)] });
  try {
    for (const route of ['/ping', '/terminals']) {
      const anonymous = await call(ctx.base, route);
      assert.strictEqual(anonymous.status, 401, `${route} without a token`);
      assert.deepStrictEqual(anonymous.json(), { error: 'unauthorized' });

      const wrong = await call(ctx.base, route, { token: 'f'.repeat(32) });
      assert.strictEqual(wrong.status, 401, `${route} with a wrong token`);
    }

    const malformed = await call(ctx.base, '/ping', { headers: { Authorization: ctx.token } });
    assert.strictEqual(malformed.status, 401, 'raw token without the Bearer scheme');

    const post = await call(ctx.base, '/focus', {
      method: 'POST',
      body: JSON.stringify({ processId: 4242 })
    });
    assert.strictEqual(post.status, 401);

    const ok = await call(ctx.base, '/ping', { token: ctx.token });
    assert.strictEqual(ok.status, 200);
  } finally {
    extension.deactivate();
  }
});

test('GET /ping reports app, pid and version', async () => {
  const ctx = await start({ appName: 'Cursor' });
  try {
    const res = await call(ctx.base, '/ping', { token: ctx.token });
    assert.strictEqual(res.status, 200);
    assert.deepStrictEqual(res.json(), {
      app: 'cursor',
      pid: process.pid,
      version: pkg.version
    });
  } finally {
    extension.deactivate();
  }
});

test('appName maps to the slug Lookout expects', async () => {
  const cases = [
    ['Cursor', 'cursor'],
    ['Devin', 'devin'],
    ['Windsurf', 'devin'],
    ['Visual Studio Code', 'vscode'],
    ['Code - OSS', 'vscode'],
    ['Some Other Editor', 'some-other-editor']
  ];
  for (const [appName, slug] of cases) {
    const ctx = await start({ appName });
    try {
      const res = await call(ctx.base, '/ping', { token: ctx.token });
      const body = res.json();
      assert.strictEqual(body.app, slug, `${appName} -> ${slug}`);
      assert.strictEqual(path.basename(ctx.info.file), `${slug}-${process.pid}.json`);
    } finally {
      extension.deactivate();
    }
  }
});

test('GET /terminals awaits processId and reports null when unknown', async () => {
  const zsh = fakeTerminal('zsh', 111, { cwd: '/Users/x/repo' });
  const pending = fakeTerminal('claude', new Promise((resolve) => setTimeout(() => resolve(222), 15)));
  const unknown = fakeTerminal('task', undefined);
  const rejected = fakeTerminal('broken', Promise.reject(new Error('gone')));
  const uriCwd = fakeTerminal('uri', 333, { cwd: { fsPath: '/Users/x/other' } });

  const ctx = await start({
    terminals: [zsh, pending, unknown, rejected, uriCwd],
    activeTerminal: pending
  });
  try {
    const res = await call(ctx.base, '/terminals', { token: ctx.token });
    assert.strictEqual(res.status, 200);
    const body = res.json();
    assert.strictEqual(body.length, 5);

    assert.deepStrictEqual(body[0], {
      index: 0,
      name: 'zsh',
      processId: 111,
      cwd: '/Users/x/repo',
      creationOptions: { cwd: '/Users/x/repo' },
      isActive: false
    });
    assert.strictEqual(body[1].processId, 222, 'a pending processId is awaited');
    assert.strictEqual(body[1].isActive, true);
    assert.strictEqual(body[1].cwd, null);
    assert.strictEqual(body[2].processId, null, 'undefined processId becomes null');
    assert.strictEqual(body[3].processId, null, 'a rejected processId becomes null');
    assert.strictEqual(body[4].cwd, '/Users/x/other', 'a Uri cwd is flattened to fsPath');
    assert.deepStrictEqual(body.map((t) => t.index), [0, 1, 2, 3, 4]);
  } finally {
    extension.deactivate();
  }
});

test('POST /focus shows the matching terminal, 404 otherwise', async () => {
  const a = fakeTerminal('zsh', 111);
  const b = fakeTerminal('claude', 222);
  const ctx = await start({ terminals: [a, b] });
  try {
    const res = await call(ctx.base, '/focus', {
      token: ctx.token,
      method: 'POST',
      body: JSON.stringify({ processId: 222 })
    });
    assert.strictEqual(res.status, 200);
    assert.deepStrictEqual(res.json(), {
      ok: true,
      index: 1,
      name: 'claude',
      processId: 222
    });
    assert.deepStrictEqual(b.calls.show, [[false]], 'show(false) on the match');
    assert.deepStrictEqual(a.calls.show, [], 'the other terminal is untouched');

    const missing = await call(ctx.base, '/focus', {
      token: ctx.token,
      method: 'POST',
      body: JSON.stringify({ processId: 999 })
    });
    assert.strictEqual(missing.status, 404);
    assert.deepStrictEqual(missing.json(), {
      error: 'no terminal with that processId',
      processId: 999
    });

    const bad = await call(ctx.base, '/focus', {
      token: ctx.token,
      method: 'POST',
      body: JSON.stringify({ processId: 'nope' })
    });
    assert.strictEqual(bad.status, 400);

    const wrongMethod = await call(ctx.base, '/focus', { token: ctx.token });
    assert.strictEqual(wrongMethod.status, 405);
  } finally {
    extension.deactivate();
  }
});

test('POST /send passes text and newline to sendText, 404 otherwise', async () => {
  const a = fakeTerminal('zsh', 111);
  const b = fakeTerminal('claude', 222);
  const ctx = await start({ terminals: [a, b] });
  try {
    const res = await call(ctx.base, '/send', {
      token: ctx.token,
      method: 'POST',
      body: JSON.stringify({ processId: 222, text: '/rename lookout' })
    });
    assert.strictEqual(res.status, 200);
    assert.deepStrictEqual(b.calls.sendText, [['/rename lookout', true]], 'newline defaults to true');

    await call(ctx.base, '/send', {
      token: ctx.token,
      method: 'POST',
      body: JSON.stringify({ processId: 222, text: 'no newline', newline: false })
    });
    assert.deepStrictEqual(b.calls.sendText[1], ['no newline', false]);
    assert.deepStrictEqual(a.calls.sendText, []);

    const missing = await call(ctx.base, '/send', {
      token: ctx.token,
      method: 'POST',
      body: JSON.stringify({ processId: 999, text: 'hi' })
    });
    assert.strictEqual(missing.status, 404);

    const noText = await call(ctx.base, '/send', {
      token: ctx.token,
      method: 'POST',
      body: JSON.stringify({ processId: 222 })
    });
    assert.strictEqual(noText.status, 400);
  } finally {
    extension.deactivate();
  }
});

test('unknown routes are 404 and bad JSON is 400', async () => {
  const ctx = await start({});
  try {
    const missing = await call(ctx.base, '/nope', { token: ctx.token });
    assert.strictEqual(missing.status, 404);
    assert.deepStrictEqual(missing.json(), { error: 'not found' });

    const bad = await call(ctx.base, '/send', {
      token: ctx.token,
      method: 'POST',
      body: '{not json'
    });
    assert.strictEqual(bad.status, 400);
    assert.deepStrictEqual(bad.json(), { error: 'invalid JSON body' });
  } finally {
    extension.deactivate();
  }
});

test('bodies over 64 KB are rejected with 413', async () => {
  const ctx = await start({ terminals: [fakeTerminal('zsh', 111)] });
  try {
    const small = JSON.stringify({ processId: 111, text: 'x'.repeat(1024) });
    assert.ok(Buffer.byteLength(small) < 64 * 1024);
    const ok = await call(ctx.base, '/send', { token: ctx.token, method: 'POST', body: small });
    assert.strictEqual(ok.status, 200);

    const huge = JSON.stringify({ processId: 111, text: 'x'.repeat(70 * 1024) });
    assert.ok(Buffer.byteLength(huge) > 64 * 1024);
    const res = await call(ctx.base, '/send', { token: ctx.token, method: 'POST', body: huge });
    assert.strictEqual(res.status, 413);
    const body = res.json();
    assert.strictEqual(body.error, 'body too large');
    assert.strictEqual(body.limit, 64 * 1024);
  } finally {
    extension.deactivate();
  }
});

test('the token file is written 0600 and removed on deactivate', async () => {
  const folders = ['/Users/x/repo', '/Users/x/other'];
  const ctx = await start({
    appName: 'Devin',
    folders,
    workspaceName: 'repo (Workspace)',
    terminals: []
  });
  let file = ctx.info.file;
  try {
    assert.strictEqual(
      path.dirname(file),
      path.join(TMP_HOME, '.lookout', 'companion'),
      'lives under ~/.lookout/companion'
    );
    assert.strictEqual(path.basename(file), `devin-${process.pid}.json`);
    assert.strictEqual(fs.statSync(file).mode & 0o777, 0o600, 'mode 600');

    const state = ctx.state;
    assert.strictEqual(state.app, 'devin');
    assert.strictEqual(state.pid, process.pid);
    assert.strictEqual(state.port, ctx.info.port);
    assert.match(state.token, /^[0-9a-f]{32}$/, 'a fresh 32-hex token');
    assert.strictEqual(state.windowTitle, 'repo (Workspace)');
    assert.deepStrictEqual(state.folders, folders);
    assert.strictEqual(state.version, pkg.version);
    assert.ok(!Number.isNaN(Date.parse(state.started_at)), 'started_at is a timestamp');

    assert.strictEqual(ctx.context.subscriptions.length, 1, 'registered for dispose');
    assert.ok(ctx.vscode.channels.some((channel) => channel.name === 'Beacon'), 'output channel');
    assert.ok(
      ctx.vscode.logLines.every((line) => !line.includes(state.token)),
      'the token is never logged'
    );
  } finally {
    extension.deactivate();
  }

  assert.strictEqual(fs.existsSync(file), false, 'token file removed on deactivate');

  // A second window gets a different token and port.
  const again = await start({ appName: 'Devin' });
  try {
    assert.notStrictEqual(again.token, ctx.token, 'a fresh token per start');
  } finally {
    extension.deactivate();
  }
  assert.strictEqual(fs.existsSync(again.info.file), false);
});

test('one log line per request, without the token', async () => {
  const ctx = await start({ terminals: [fakeTerminal('zsh', 111)] });
  try {
    const before = ctx.vscode.logLines.length;
    await call(ctx.base, '/ping', { token: ctx.token });
    await call(ctx.base, '/terminals', { token: ctx.token });
    await call(ctx.base, '/ping');
    const lines = ctx.vscode.logLines.slice(before);
    assert.strictEqual(lines.length, 3, 'one line per request');
    assert.match(lines[0], /GET \/ping -> 200$/);
    assert.match(lines[1], /GET \/terminals -> 200 n=1$/);
    assert.match(lines[2], /GET \/ping -> 401$/);
    assert.ok(lines.every((line) => !line.includes(ctx.token)));
  } finally {
    extension.deactivate();
  }
});
