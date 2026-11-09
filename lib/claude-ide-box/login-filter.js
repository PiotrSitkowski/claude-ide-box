// Output filter for `claude-ide-box login`, run with node inside the login
// container:  script ... claude setup-token | node -e "<this file>" FILE
//
// Everything `claude setup-token` prints is passed through, except tokens
// (sk-ant-...): each one is replaced on screen by a short notice, and the
// first one is written to FILE (mode 600), a directory mounted from the host.
// A token can arrive split across reads, so a trailing piece that could be
// the start of a token is held back until the next read shows how it ends.
//
// The sign-in URL is also written, once, to "url" next to FILE, so the host
// can open it in a browser (WSL: a console window where links cannot be
// clicked). Only URLs of the sign-in hosts, ended by whitespace, count.
"use strict";

const fs = require("fs");
const path = require("path");

const out = process.argv[process.argv.length - 1];
const urlFile = path.join(path.dirname(out), "url");
const URL_RE =
  /https:\/\/(?:claude\.ai|claude\.com|platform\.claude\.com|console\.anthropic\.com)\/[^\s"'<>\\`^\x00-\x1f\x7f]+(?=[\s\x00-\x1f])/;
let seen = "";
let urlSaved = false;

function findUrl(chunk) {
  if (urlSaved) return;
  seen = (seen + chunk).slice(-16384);
  const m = seen.match(URL_RE);
  if (!m) return;
  urlSaved = true;
  try {
    fs.writeFileSync(urlFile, m[0] + "\n", { mode: 0o600 });
  } catch (e) {
    // Opening the browser is a convenience; the URL is on screen anyway.
  }
}
const TOKEN = /sk-ant-[A-Za-z0-9_-]+/g;
const PARTIAL = /s(?:k(?:-(?:a(?:n(?:t(?:-[A-Za-z0-9_-]*)?)?)?)?)?)?$/;
const NOTICE = "[token captured - not shown]";

let buf = "";
let saved = false;
let timer = null;

function save(token) {
  if (saved) return;
  fs.writeFileSync(out, token + "\n", { mode: 0o600 });
  saved = true;
}

function pump(final) {
  let shown = "";
  let last = 0;
  let m;
  TOKEN.lastIndex = 0;
  while ((m = TOKEN.exec(buf)) !== null) {
    // A token that touches the end of what we have may still continue.
    if (!final && m.index + m[0].length === buf.length) break;
    shown += buf.slice(last, m.index) + NOTICE;
    save(m[0]);
    last = m.index + m[0].length;
  }
  const rest = buf.slice(last);
  const hold = final ? null : rest.match(PARTIAL);
  if (hold) {
    shown += rest.slice(0, hold.index);
    buf = rest.slice(hold.index);
  } else {
    shown += rest;
    buf = "";
  }
  if (shown) process.stdout.write(shown);
  // A held "s", "sk-" ... that is not followed by more output (a prompt
  // waiting for input) is shown after a moment; a started token is kept.
  if (timer) clearTimeout(timer);
  timer = null;
  if (buf && !buf.startsWith("sk-ant-")) {
    timer = setTimeout(() => {
      process.stdout.write(buf);
      buf = "";
    }, 150);
  }
}

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  findUrl(chunk);
  buf += chunk;
  pump(false);
});
process.stdin.on("end", () => {
  if (timer) clearTimeout(timer);
  pump(true);
});
