// Integration-test probe, run inside a project container: drive `claude` the
// way the IDE extension does (stream-json, permission prompts over stdio)
// against a fake Messages API on 127.0.0.1, answer every permission prompt
// with "allow" plus an "always allow" rule saved to DEST (what the panel's
// "always allow" button sends), and print a JSON report of what happened.
// The fake model asks for the same Bash command twice, so the report shows
// whether the rule took effect in the running session.
// Usage: node permission-probe.js [DEST]   (default localSettings)
'use strict';
const http = require('http');
const { spawn } = require('child_process');
const fs = require('fs');

const dest = process.argv[2] || 'localSettings';
const command = 'touch permission-probe.txt';
let calls = 0;

function sse(res, events) {
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  for (const [type, data] of events) res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`);
  res.end();
}

function message(content, stop) {
  return { id: 'msg_probe_' + (++calls), type: 'message', role: 'assistant', model: 'claude-probe',
    content, stop_reason: stop, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } };
}

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    if (!req.url.startsWith('/v1/messages') || req.url.includes('count_tokens')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(req.url.includes('count_tokens') ? '{"input_tokens":1}' : '{}');
      return;
    }
    let j = {};
    try { j = JSON.parse(body); } catch (e) { /* ignore */ }
    const msgs = j.messages || [];
    // Ask for the same command twice: the second call shows whether the
    // "always allow" rule took effect in the running session.
    const results = msgs.reduce((n, m) => n + (Array.isArray(m.content) ? m.content.filter((b) => b.type === 'tool_result').length : 0), 0);
    const wantsTool = Array.isArray(j.tools) && j.tools.some((t) => t.name === 'Bash') && results < 2;
    const blocks = wantsTool
      ? [{ type: 'tool_use', id: 'toolu_probe_' + calls, name: 'Bash', input: { command, description: 'probe' } }]
      : [{ type: 'text', text: 'probe done' }];
    const stop = wantsTool ? 'tool_use' : 'end_turn';
    if (!j.stream) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(message(blocks, stop)));
      return;
    }
    const m = message([], null);
    const ev = [['message_start', { message: m }]];
    blocks.forEach((b, i) => {
      if (b.type === 'text') {
        ev.push(['content_block_start', { index: i, content_block: { type: 'text', text: '' } }]);
        ev.push(['content_block_delta', { index: i, delta: { type: 'text_delta', text: b.text } }]);
      } else {
        ev.push(['content_block_start', { index: i, content_block: { type: 'tool_use', id: b.id, name: b.name, input: {} } }]);
        ev.push(['content_block_delta', { index: i, delta: { type: 'input_json_delta', partial_json: JSON.stringify(b.input) } }]);
      }
      ev.push(['content_block_stop', { index: i }]);
    });
    ev.push(['message_delta', { delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 1 } }]);
    ev.push(['message_stop', {}]);
    sse(res, ev);
  });
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  const env = Object.assign({}, process.env, {
    ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}`,
    ANTHROPIC_API_KEY: 'sk-ant-api03-probe',
  });
  delete env.CLAUDE_CODE_OAUTH_TOKEN;
  const child = spawn('claude', ['--output-format', 'stream-json', '--verbose', '--input-format', 'stream-json',
    '--permission-prompt-tool', 'stdio', '--setting-sources=user,project,local', '--permission-mode', 'default'],
  { env, stdio: ['pipe', 'pipe', 'pipe'] });
  const report = { dest, prompts: 0, permissionResponseSent: false, results: [], stderr: '', errors: [], exit: null };
  let buf = '';
  const timer = setTimeout(() => { report.errors.push('timeout'); child.kill('SIGKILL'); }, 60000);
  child.stderr.on('data', (d) => { report.stderr += d; });
  child.stdout.on('data', (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      let m;
      try { m = JSON.parse(line); } catch (e) { report.errors.push('non-json: ' + line.slice(0, 200)); continue; }
      if (m.type === 'control_request' && m.request && m.request.subtype === 'can_use_tool') {
        report.prompts++;
        const response = { behavior: 'allow', updatedInput: m.request.input,
          updatedPermissions: [{ type: 'addRules', rules: [{ toolName: 'Bash', ruleContent: command }],
            behavior: 'allow', destination: dest }] };
        child.stdin.write(JSON.stringify({ type: 'control_response',
          response: { subtype: 'success', request_id: m.request_id, response } }) + '\n');
        report.permissionResponseSent = true;
      } else if (m.type === 'control_request') {
        child.stdin.write(JSON.stringify({ type: 'control_response',
          response: { subtype: 'success', request_id: m.request_id, response: {} } }) + '\n');
      } else if (m.type === 'user' && m.message && Array.isArray(m.message.content)) {
        for (const b of m.message.content) {
          if (b.type === 'tool_result') report.results.push({ is_error: !!b.is_error, content: JSON.stringify(b.content).slice(0, 300) });
        }
      } else if (m.type === 'result') {
        report.final = { subtype: m.subtype, is_error: m.is_error, result: m.result };
        child.stdin.end();
      } else if (m.type === 'system' && m.subtype !== 'init') {
        report.errors.push('system: ' + JSON.stringify(m).slice(0, 300));
      }
    }
  });
  child.on('exit', (code, signal) => {
    clearTimeout(timer);
    report.exit = signal || code;
    report.ranTimes = report.results.filter((r) => !r.is_error).length; report.probeFileWritten = fs.existsSync('permission-probe.txt');
    report.settingsLocalExists = fs.existsSync('.claude/settings.local.json');
    report.stderr = report.stderr.slice(0, 2000);
    process.stdout.write(JSON.stringify(report) + '\n');
    server.close();
  });
  child.stdin.write(JSON.stringify({ type: 'user', message: { role: 'user', content: 'run the probe' } }) + '\n');
});
