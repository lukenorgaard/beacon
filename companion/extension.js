'use strict';

// Lookout Companion — a localhost bridge into this editor window's integrated
// terminals. See docs/history/SPEC.md section 16.

const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const MAX_BODY_BYTES = 64 * 1024;
const VERSION = require('./package.json').version;

// The single live instance, so deactivate() (called by VS Code without
// arguments) and the process-exit hook can find it.
let current = null;

function stateDir() {
  return path.join(os.homedir(), '.lookout', 'companion');
}

function slugify(name) {
  const slug = String(name || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return slug || 'editor';
}

function appSlug(appName) {
  const name = String(appName || '').toLowerCase();
  if (name.includes('cursor')) return 'cursor';
  if (name.includes('devin') || name.includes('windsurf')) return 'devin';
  if (name.includes('visual studio code') || name.includes('code')) return 'vscode';
  return slugify(name);
}

function normalizeCwd(cwd) {
  if (typeof cwd === 'string') return cwd;
  if (cwd && typeof cwd.fsPath === 'string') return cwd.fsPath;
  if (cwd && typeof cwd.path === 'string') return cwd.path;
  return null;
}

function workspaceFolders(vscode) {
  const folders = (vscode.workspace && vscode.workspace.workspaceFolders) || [];
  return folders
    .map((folder) => normalizeCwd(folder && folder.uri))
    .filter((folder) => typeof folder === 'string');
}

function windowTitle(vscode, folders) {
  const name = vscode.workspace && vscode.workspace.name;
  if (typeof name === 'string' && name.length > 0) return name;
  if (folders.length > 0) return path.basename(folders[0]);
  return null;
}

function writeTokenFile(file, payload) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const fd = fs.openSync(file, 'w', 0o600);
  try {
    fs.writeFileSync(fd, JSON.stringify(payload, null, 2) + '\n');
  } finally {
    fs.closeSync(fd);
  }
  // openSync honours the mode only when it creates the file; a leftover file
  // from a crashed host would keep its old permissions.
  fs.chmodSync(file, 0o600);
}

function removeTokenFile(file) {
  try {
    fs.unlinkSync(file);
  } catch (err) {
    if (err && err.code !== 'ENOENT') {
      // Nothing useful to do — Lookout ignores files whose pid is dead.
    }
  }
}

function equalTokens(given, expected) {
  const a = Buffer.from(String(given), 'utf8');
  const b = Buffer.from(String(expected), 'utf8');
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

function authorized(req, token) {
  const header = req.headers && req.headers.authorization;
  if (typeof header !== 'string') return false;
  const match = /^Bearer\s+(\S+)$/i.exec(header.trim());
  if (!match) return false;
  return equalTokens(match[1], token);
}

function sendJson(ctx, req, res, status, body, note) {
  const payload = JSON.stringify(body);
  if (!res.headersSent) {
    res.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': Buffer.byteLength(payload),
      'Cache-Control': 'no-store'
    });
  }
  res.end(payload);
  ctx.log(`${req.method} ${ctx.pathOf(req)} -> ${status}${note ? ' ' + note : ''}`);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const onData = (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        req.removeListener('data', onData);
        req.removeListener('end', onEnd);
        req.removeListener('error', onError);
        req.resume(); // drain without buffering
        resolve({ tooLarge: true });
        return;
      }
      chunks.push(chunk);
    };
    const onEnd = () => resolve({ raw: Buffer.concat(chunks).toString('utf8') });
    const onError = (err) => reject(err);
    req.on('data', onData);
    req.once('end', onEnd);
    req.once('error', onError);
  });
}

async function listTerminals(vscode) {
  const terminals = (vscode.window && vscode.window.terminals) || [];
  const active = vscode.window ? vscode.window.activeTerminal : null;
  return Promise.all(
    terminals.map(async (terminal, index) => {
      let processId = null;
      try {
        const pid = await terminal.processId;
        processId = typeof pid === 'number' && Number.isFinite(pid) ? pid : null;
      } catch (err) {
        processId = null;
      }
      const options = terminal.creationOptions || {};
      const cwd = normalizeCwd(options.cwd);
      return {
        index,
        name: typeof terminal.name === 'string' ? terminal.name : null,
        processId,
        cwd,
        creationOptions: { cwd },
        isActive: Boolean(active) && terminal === active
      };
    })
  );
}

async function findTerminal(vscode, processId) {
  const terminals = (vscode.window && vscode.window.terminals) || [];
  for (let index = 0; index < terminals.length; index += 1) {
    const terminal = terminals[index];
    let pid = null;
    try {
      pid = await terminal.processId;
    } catch (err) {
      pid = null;
    }
    if (typeof pid === 'number' && pid === processId) return { terminal, index };
  }
  return null;
}

async function jsonBody(ctx, req, res) {
  const body = await readBody(req);
  if (body.tooLarge) {
    sendJson(ctx, req, res, 413, { error: 'body too large', limit: MAX_BODY_BYTES });
    return null;
  }
  const raw = body.raw.trim();
  if (raw.length === 0) return {};
  try {
    const parsed = JSON.parse(raw);
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      sendJson(ctx, req, res, 400, { error: 'body must be a JSON object' });
      return null;
    }
    return parsed;
  } catch (err) {
    sendJson(ctx, req, res, 400, { error: 'invalid JSON body' });
    return null;
  }
}

async function handleRequest(ctx, req, res) {
  const route = ctx.pathOf(req);

  if (!authorized(req, ctx.token)) {
    sendJson(ctx, req, res, 401, { error: 'unauthorized' });
    return;
  }

  if (route === '/ping') {
    if (req.method !== 'GET') return sendJson(ctx, req, res, 405, { error: 'method not allowed' });
    return sendJson(ctx, req, res, 200, { app: ctx.app, pid: process.pid, version: VERSION });
  }

  if (route === '/terminals') {
    if (req.method !== 'GET') return sendJson(ctx, req, res, 405, { error: 'method not allowed' });
    const terminals = await listTerminals(ctx.vscode);
    return sendJson(ctx, req, res, 200, terminals, `n=${terminals.length}`);
  }

  if (route === '/focus' || route === '/send') {
    if (req.method !== 'POST') return sendJson(ctx, req, res, 405, { error: 'method not allowed' });
    const body = await jsonBody(ctx, req, res);
    if (body === null) return;

    const processId = body.processId;
    if (typeof processId !== 'number' || !Number.isFinite(processId)) {
      return sendJson(ctx, req, res, 400, { error: 'processId must be a number' });
    }

    let text = null;
    let newline = true;
    if (route === '/send') {
      if (typeof body.text !== 'string') {
        return sendJson(ctx, req, res, 400, { error: 'text must be a string' });
      }
      text = body.text;
      newline = body.newline === undefined ? true : Boolean(body.newline);
    }

    const found = await findTerminal(ctx.vscode, processId);
    if (!found) {
      return sendJson(ctx, req, res, 404, { error: 'no terminal with that processId', processId },
        `pid=${processId}`);
    }

    if (route === '/focus') {
      found.terminal.show(false);
    } else {
      found.terminal.sendText(text, newline);
    }
    return sendJson(
      ctx,
      req,
      res,
      200,
      { ok: true, index: found.index, name: found.terminal.name || null, processId },
      `pid=${processId}`
    );
  }

  return sendJson(ctx, req, res, 404, { error: 'not found' });
}

function listen(server, port, host) {
  return new Promise((resolve, reject) => {
    const onError = (err) => reject(err);
    server.once('error', onError);
    server.listen(port, host, () => {
      server.removeListener('error', onError);
      resolve();
    });
  });
}

async function activate(context, api) {
  // `api` is injected by the tests; VS Code calls activate(context) only.
  const vscode = api || require('vscode');

  const output = vscode.window.createOutputChannel('Beacon');
  const log = (line) => {
    try {
      output.appendLine(`${new Date().toISOString()} ${line}`);
    } catch (err) {
      // an OutputChannel disposed under us must never break a request
    }
  };

  const token = crypto.randomBytes(16).toString('hex'); // 32 hex chars
  const app = appSlug(vscode.env && vscode.env.appName);
  const folders = workspaceFolders(vscode);

  const ctx = {
    vscode,
    token,
    app,
    log,
    pathOf(req) {
      try {
        return new URL(req.url, 'http://127.0.0.1').pathname;
      } catch (err) {
        return '/';
      }
    }
  };

  const server = http.createServer((req, res) => {
    handleRequest(ctx, req, res).catch((err) => {
      try {
        sendJson(ctx, req, res, 500, { error: 'internal error' }, String(err && err.message));
      } catch (nested) {
        try { res.destroy(); } catch (ignored) { /* socket already gone */ }
      }
    });
  });
  server.on('clientError', (err, socket) => {
    try { socket.destroy(); } catch (ignored) { /* already gone */ }
  });

  await listen(server, 0, '127.0.0.1');
  const port = server.address().port;

  const file = path.join(stateDir(), `${app}-${process.pid}.json`);
  writeTokenFile(file, {
    app,
    pid: process.pid,
    port,
    token,
    windowTitle: windowTitle(vscode, folders),
    folders,
    started_at: new Date().toISOString(),
    version: VERSION
  });

  server.on('close', () => removeTokenFile(file));

  current = { server, file, output };
  log(`listening on 127.0.0.1:${port} app=${app} pid=${process.pid} file=${file}`);

  const disposable = { dispose: () => deactivate() };
  if (context && Array.isArray(context.subscriptions)) context.subscriptions.push(disposable);

  // Deliberately no token in the exported API — it lives only in the 0600 file.
  return { app, port, file, version: VERSION };
}

function deactivate() {
  const state = current;
  current = null;
  if (!state) return;
  try {
    if (typeof state.server.closeAllConnections === 'function') state.server.closeAllConnections();
    state.server.close();
  } catch (err) {
    // already closed
  }
  removeTokenFile(state.file);
  try {
    state.output.dispose();
  } catch (err) {
    // already disposed
  }
}

process.once('exit', () => {
  if (current) removeTokenFile(current.file);
});

module.exports = { activate, deactivate };
