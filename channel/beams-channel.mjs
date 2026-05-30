#!/usr/bin/env node
// beams-channel.mjs — MCP stdio channel server for the beams plugin.
//
// WHAT THIS IS
//   An opt-in, experimental real-time bridge.  When the watcher daemon fires
//   its --on-message hook, it POSTs to this server's HTTP listener.  The
//   server emits a JSON-RPC notifications/claude/channel notification over
//   stdout, which Claude Code delivers as a <channel source="beams" ...>
//   event that wakes an already-open, idle session.
//
//   Architecture:
//     watcher daemon  -->  curl localhost  -->  this server  -->  <channel> event  -->  Claude wakes
//
//   This only wakes a session that is OPEN.  It does not start new sessions
//   and does not queue events across restarts.  See channel/README.md.
//
// STDOUT PURITY — THE #1 CORRECTNESS CONSTRAINT
//   stdout is reserved exclusively for newline-delimited JSON-RPC 2.0 messages.
//   One compact JSON object per line.  NO embedded newlines inside the object.
//   NO banners, NO console.log, NO debug output.  A single stray byte on
//   stdout breaks the MCP stdio protocol and Claude Code will drop the server.
//   ALL diagnostics, warnings, and info messages go to stderr via log().
//
// ENVIRONMENT VARIABLES
//   BEAMS_CHANNEL_PORT        HTTP port to listen on (default 8799).  Must be
//                             a positive integer; invalid values fall back to
//                             8799.
//
//   BEAMS_CHANNEL_TOKEN       Shared secret for the x-beams-token request
//                             header.  If neither TOKEN nor TOKEN_FILE is set,
//                             POSTs are accepted from localhost with a one-time
//                             stderr warning.
//
//   BEAMS_CHANNEL_TOKEN_FILE  Path to a file containing the token (trimmed).
//                             If the file is missing, a random token is
//                             generated, written at mode 0o600, and its PATH
//                             is logged to stderr (the token value is never
//                             logged).
//
// EXPERIMENTAL / OPT-IN
//   Channels are a Claude Code research preview (v2.1.80+).  This server
//   must be launched with:
//     claude --dangerously-load-development-channels server:beams
//   because community-marketplace plugins are not on the allowlist.
//   Anthropic auth (claude.ai or Console API key) is required; Bedrock,
//   Vertex, and Foundry are not supported.  The protocol contract may change.

import { createServer }  from 'node:http';
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { createInterface } from 'node:readline';
import process             from 'node:process';

// ---------------------------------------------------------------------------
// Logging — ALL output goes to stderr.  Never touch stdout except for JSON-RPC.
// ---------------------------------------------------------------------------

function log(...args) {
  const line = args.join(' ');
  process.stderr.write(`[beams-channel] ${line}\n`);
}

// ---------------------------------------------------------------------------
// JSON-RPC stdout emitter — the ONLY thing allowed to write to stdout.
// Compact (no embedded newlines) + trailing newline = one framing unit.
// ---------------------------------------------------------------------------

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function rpcReply(id, result) {
  emit({ jsonrpc: '2.0', id, result });
}

function rpcError(id, code, message) {
  emit({ jsonrpc: '2.0', id, error: { code, message } });
}

// ---------------------------------------------------------------------------
// Token configuration — read once at startup.
// ---------------------------------------------------------------------------

let _token = null;          // null means "no token configured"
let _noTokenWarned = false; // emit the localhost-only warning at most once

function loadToken() {
  const envToken = process.env.BEAMS_CHANNEL_TOKEN;
  if (envToken && envToken.trim()) {
    _token = envToken.trim();
    log('token loaded from BEAMS_CHANNEL_TOKEN');
    return;
  }

  const tokenFile = process.env.BEAMS_CHANNEL_TOKEN_FILE;
  if (tokenFile && tokenFile.trim()) {
    const filePath = tokenFile.trim();
    if (existsSync(filePath)) {
      const contents = readFileSync(filePath, 'utf8').trim();
      if (contents) {
        _token = contents;
        log(`token loaded from file: ${filePath}`);
        return;
      }
    }
    // File is configured but missing — generate a new token and write it.
    const generated = randomBytes(16).toString('hex');
    try {
      writeFileSync(filePath, generated, { mode: 0o600, flag: 'w' });
      _token = generated;
      // Log the PATH (never the value).
      log(`generated new token and wrote it to: ${filePath}`);
      log(`(set BEAMS_CHANNEL_TOKEN or point BEAMS_CHANNEL_TOKEN_FILE to that path before launching claude)`);
      return;
    } catch (err) {
      log(`ERROR: could not write generated token to ${filePath}: ${err.message}`);
      log('proceeding without a token — localhost-only, but NOT recommended');
    }
  }

  // No token configured at all.
  _token = null;
}

function checkToken(req) {
  if (_token === null) {
    // No token configured.  Warn once, then accept.
    if (!_noTokenWarned) {
      _noTokenWarned = true;
      log('WARNING: no BEAMS_CHANNEL_TOKEN configured. POSTs accepted from localhost without authentication.');
      log('Set BEAMS_CHANNEL_TOKEN (or BEAMS_CHANNEL_TOKEN_FILE) before launching claude for defense-in-depth.');
    }
    return true;
  }

  const provided = req.headers['x-beams-token'] || '';

  // Constant-time comparison to resist timing attacks.
  // If lengths differ we must NOT use timingSafeEqual (it throws on unequal
  // buffer lengths) — treat as mismatch immediately.
  const expectedBuf = Buffer.from(_token, 'utf8');
  const providedBuf = Buffer.from(provided, 'utf8');

  if (expectedBuf.length !== providedBuf.length) {
    return false;
  }
  return timingSafeEqual(expectedBuf, providedBuf);
}

// ---------------------------------------------------------------------------
// Port validation
// ---------------------------------------------------------------------------

function resolvePort() {
  const raw = process.env.BEAMS_CHANNEL_PORT;
  if (raw !== undefined && raw !== '') {
    const n = Number(raw);
    if (Number.isInteger(n) && n > 0 && n <= 65535) {
      return n;
    }
    log(`WARNING: BEAMS_CHANNEL_PORT="${raw}" is not a valid port; using default 8799`);
  }
  return 8799;
}

// ---------------------------------------------------------------------------
// Content sanitization — strip C0 control chars (0x00–0x1f), DEL (0x7f),
// C1 controls (0x80–0x9f), and the angle brackets < > .  Guards against
// prompt-injection / terminal hijack via crafted message bodies, and (defense
// in depth) stops a crafted body from forging a </channel> close or a fake
// <channel ...> open in Claude's rendered view.  Operates on the DECODED
// string, not raw bytes, so it never corrupts multi-byte UTF-8.  Mirrors the
// defense-in-depth strip in watcher_daemon.sh's dispatch_on_message().
// ---------------------------------------------------------------------------

function sanitizeContent(str) {
  // Remove U+0000–U+001F, U+007F, U+0080–U+009F, and < >
  // eslint-disable-next-line no-control-regex
  return str.replace(/[\x00-\x1f\x7f\x80-\x9f<>]/g, '');
}

// Sanitize a meta key or value to identifier-safe characters only.
// The Channels spec: "Keys must be identifiers: letters, digits, and
// underscores only.  Keys containing hyphens or other characters are
// silently dropped."  We drop the key if it becomes empty after stripping.
function sanitizeMetaValue(str) {
  return str.replace(/[^A-Za-z0-9_]/g, '');
}

// ---------------------------------------------------------------------------
// MCP initialize instructions (inserted into Claude's system prompt)
// ---------------------------------------------------------------------------

const CHANNEL_INSTRUCTIONS =
  'Events from the beams channel arrive as <channel source="beams" beam="..." from="...">. ' +
  'Each is a new cross-terminal beam message addressed to this session. ' +
  'Read the full message with the /beams:read command, then surface it to the user ' +
  '(who it\'s from + a short summary). ' +
  'Respond on the beam (e.g. /beams:send) ONLY if this session\'s role/instructions ' +
  'call for autonomous replies; otherwise just surface it. ' +
  'These are one-way notifications — no reply is expected through the channel.';

// ---------------------------------------------------------------------------
// JSON-RPC dispatch — called for every valid JSON object read from stdin.
// Requests have an `id`; notifications (from Claude Code) have no `id`.
// ---------------------------------------------------------------------------

function dispatch(msg) {
  const { id, method, params } = msg;
  const isRequest = id !== undefined && id !== null;

  if (!method) {
    // Malformed — ignore if notification, error if request.
    if (isRequest) {
      rpcError(id, -32600, 'Invalid Request: missing method');
    }
    return;
  }

  if (!isRequest) {
    // Notifications from Claude Code (notifications/initialized,
    // notifications/cancelled, etc.) — ignore silently.
    return;
  }

  // --- Requests ---

  if (method === 'initialize') {
    // Echo back the client's protocolVersion if it's a non-empty string.
    const proto =
      params && typeof params.protocolVersion === 'string' && params.protocolVersion
        ? params.protocolVersion
        : '2025-06-18';

    rpcReply(id, {
      protocolVersion: proto,
      capabilities: {
        experimental: { 'claude/channel': {} },
      },
      serverInfo: { name: 'beams', version: '0.9.0' },
      instructions: CHANNEL_INSTRUCTIONS,
    });
    return;
  }

  if (method === 'ping') {
    rpcReply(id, {});
    return;
  }

  if (method === 'tools/list') {
    // One-way channel — no reply tool in v1.
    rpcReply(id, { tools: [] });
    return;
  }

  // Everything else is "method not found".
  rpcError(id, -32601, 'Method not found');
}

// ---------------------------------------------------------------------------
// stdin reader — newline-delimited JSON-RPC from Claude Code.
// ---------------------------------------------------------------------------

function startStdinReader() {
  const rl = createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
    terminal: false,
  });

  rl.on('line', (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let msg;
    try {
      msg = JSON.parse(trimmed);
    } catch (_err) {
      // Unparseable line — log and ignore.  Never crash.
      log(`WARNING: could not parse stdin line as JSON (ignored): ${trimmed.slice(0, 120)}`);
      return;
    }
    try {
      dispatch(msg);
    } catch (err) {
      log(`ERROR in dispatch: ${err.message}`);
    }
  });

  // stdin EOF means Claude Code exited.
  rl.on('close', () => {
    log('stdin closed — Claude Code exited, shutting down');
    process.exit(0);
  });
}

// ---------------------------------------------------------------------------
// HTTP server — inbound event receiver.
// Bound to 127.0.0.1 only (never 0.0.0.0).
// ---------------------------------------------------------------------------

function startHttpServer(port) {
  const server = createServer((req, res) => {
    const { method, url } = req;

    // -----------------------------------------------------------------------
    // GET /health — liveness probe for the watcher and smoke tests.
    // No channel emission; no token required.
    // -----------------------------------------------------------------------
    if (method === 'GET' && url === '/health') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('ok');
      return;
    }

    // -----------------------------------------------------------------------
    // POST (any path) — inbound event from the watcher's --on-message hook.
    // -----------------------------------------------------------------------
    if (method === 'POST') {
      // 1. Token gate.
      if (!checkToken(req)) {
        res.writeHead(403, { 'Content-Type': 'text/plain' });
        res.end('forbidden');
        log('rejected POST: bad or missing x-beams-token');
        return;
      }

      // 2. Read body with a hard cap of 8192 bytes.
      const MAX_BODY = 8192;
      let body = Buffer.alloc(0);
      let tooLarge = false;

      req.on('data', (chunk) => {
        if (tooLarge) return;
        const next = Buffer.concat([body, chunk]);
        if (next.length > MAX_BODY) {
          tooLarge = true;
          res.writeHead(413, { 'Content-Type': 'text/plain' });
          log('rejected POST: body exceeded 8192 bytes');
          // Destroy AFTER the 413 has flushed, so the caller gets a clean
          // response instead of a TCP reset.
          res.end('payload too large', () => req.destroy());
          return;
        }
        body = next;
      });

      req.on('end', () => {
        if (tooLarge) return;

        // 3. Sanitize content.
        const rawContent = body.toString('utf8');
        const content = sanitizeContent(rawContent);

        // 4. Build meta from headers.
        const meta = {};
        const rawBeam  = req.headers['x-beams-beam']  || '';
        const rawFrom = req.headers['x-beams-from'] || '';
        const safeB = sanitizeMetaValue(rawBeam);
        const safeF = sanitizeMetaValue(rawFrom);
        if (safeB)  meta.beam  = safeB;
        if (safeF)  meta.from = safeF;

        // 5. Emit the channel notification to stdout.
        emit({
          jsonrpc: '2.0',
          method:  'notifications/claude/channel',
          params:  { content, meta },
        });

        // 6. Acknowledge.
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end('ok');
        log(`dispatched channel event beam=${safeB || '(none)'} from=${safeF || '(none)'}`);
      });

      req.on('error', (err) => {
        log(`request error: ${err.message}`);
      });

      return;
    }

    // -----------------------------------------------------------------------
    // All other methods → 405 Method Not Allowed.
    // -----------------------------------------------------------------------
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    res.end('method not allowed');
  });

  // Defense-in-depth limits — don't rely on Node-version-specific defaults
  // (e.g. Node 16's requestTimeout is 0 = unlimited). The doorbell only ever
  // serves a same-host watcher, so these can be tight.
  server.requestTimeout = 10000; // 10s for the whole request
  server.headersTimeout = 8000;  // 8s to send headers
  server.maxConnections = 32;    // a localhost doorbell needs very few

  server.listen(port, '127.0.0.1', () => {
    log(`HTTP listener ready on 127.0.0.1:${port}`);
  });

  server.on('error', (err) => {
    log(`HTTP server error: ${err.message}`);
    // If the port is already in use, exit so Claude Code can surface the error.
    if (err.code === 'EADDRINUSE') {
      log(`port ${port} is already in use — is another beams-channel running?`);
      process.exit(1);
    }
  });

  return server;
}

// ---------------------------------------------------------------------------
// Lifecycle — graceful shutdown on SIGTERM/SIGINT, log uncaught exceptions.
// ---------------------------------------------------------------------------

process.on('SIGTERM', () => { log('SIGTERM received, exiting'); process.exit(0); });
process.on('SIGINT',  () => { log('SIGINT received, exiting');  process.exit(0); });

process.on('uncaughtException', (err) => {
  log(`uncaughtException: ${err.stack || err.message}`);
  // Keep running where safe — a single bad message must not kill the bridge.
});

process.on('unhandledRejection', (reason) => {
  log(`unhandledRejection: ${reason instanceof Error ? reason.stack : String(reason)}`);
});

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

loadToken();
const PORT = resolvePort();

startStdinReader();
startHttpServer(PORT);

log(`beams-channel ready (MCP/stdio + HTTP :${PORT}) — experimental, opt-in`);
