#!/usr/bin/env node
// bridge-client.js — thin HTTP client from gateway to openclaw-bridge.
// Usage: bridge-client.js <endpoint> [value]
//   endpoint ∈ { run-codex, deploy-staging, query-readonly }
//
// Writes the bridge's stdout/stderr through to our stdout/stderr, and exits
// with the underlying script's exit code.

const http = require('http');

const FIELD   = { 'run-codex': 'prompt', 'query-readonly': 'query', 'deploy-staging': null };
const TIMEOUT = { 'run-codex': 620000,   'query-readonly': 40000,   'deploy-staging': 920000 };

const endpoint = process.argv[2];
const value    = process.argv[3] || '';

if (!(endpoint in FIELD)) {
  process.stderr.write(`bridge-client: unknown endpoint '${endpoint}'\n`);
  process.exit(2);
}

const token = process.env.BRIDGE_TOKEN;
if (!token) {
  process.stderr.write('bridge-client: BRIDGE_TOKEN not set\n');
  process.exit(2);
}

const field = FIELD[endpoint];
const payload = field ? { [field]: value } : {};
const body = Buffer.from(JSON.stringify(payload));

const req = http.request({
  host: 'openclaw-bridge',
  port: 8005,
  path: '/' + endpoint,
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'Content-Length': body.length,
    'Authorization': 'Bearer ' + token,
  },
  timeout: TIMEOUT[endpoint] || 60000,
}, (res) => {
  const chunks = [];
  res.on('data', (c) => chunks.push(c));
  res.on('end', () => {
    const text = Buffer.concat(chunks).toString('utf8');
    let j;
    try { j = JSON.parse(text); }
    catch {
      process.stderr.write(`bridge-client: non-JSON response (HTTP ${res.statusCode}): ${text}\n`);
      process.exit(1);
    }
    if (j.stdout) process.stdout.write(j.stdout);
    if (j.stderr) process.stderr.write(j.stderr);
    if (typeof j.exit_code === 'number') process.exit(j.exit_code);
    if (j.error) {
      process.stderr.write(`bridge-client: ${j.error} (HTTP ${res.statusCode})\n`);
      process.exit(1);
    }
    process.exit(j.ok ? 0 : 1);
  });
});

req.on('timeout', () => { req.destroy(new Error('client timeout')); });
req.on('error', (e) => {
  process.stderr.write(`bridge-client: request failed: ${e.message}\n`);
  process.exit(1);
});

req.write(body);
req.end();
