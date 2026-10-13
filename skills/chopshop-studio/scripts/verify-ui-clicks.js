#!/usr/bin/env node
// HOST-SPECIFIC — this dev harness defaults to a local dev server on
// 127.0.0.1:3999 and reads the password from ~/.chopshop-studio.env.
// Those defaults are THIS deployment; pass --base/--env-file to point
// it anywhere else. Subject to change.
//
// The shebang must stay on line 1: below a comment it is not a shebang, it is a
// stray `#!` token, and node refuses the whole file with a SyntaxError.
// verify-ui-clicks.js -- drive Chopshop Studio (or any local app) in a REAL browser
// over CDP and answer the only question that matters for a UI change: does a click
// at this coordinate actually land on the element I think it does?
//
// Why not .click() / elementFromPoint alone: those report what the DOM says. A real
// Input.dispatchMouseEvent goes through the browser's hit-testing, the same way a
// user's mouse does -- which is where whole-frame hit areas, overlay z-index
// mistakes, and "the control sits behind its own content" bugs actually surface.
//
// No npm install needed: playwright's chromium is already on the box
// (~/.cache/ms-playwright/chromium-*/chrome-linux64/chrome) and node has a global
// WebSocket.
//
// Usage (start a DEV server first -- production force_ssl breaks plain-http CSRF):
//   RAILS_ENV=development bin/rails server -b 127.0.0.1 -p 3999   # background=true
//   node scripts/verify-ui-clicks.js \
//        --base http://127.0.0.1:3999 --path /json \
//        --click '#pal_presets_btn' \
//        --probe '#csModal .pal-preset' \
//        --click-probe '#csModal .pal-preset' \
//        --eval "document.getElementById('f_palette').value"
//
//   --probe SEL        geometry + the top-most element at the centre (no click)
//   --click-probe SEL  click the centre, then print every --eval result
//   --click SEL        click the centre (use to expand a modal / open a menu)
//   --eval JS          evaluated after the probes; repeatable
//   --password-env     env var holding the login password (default CHOPSHOP_PASSWORD)
//   --env-file         file to source for that password (default ~/.chopshop-studio.env)
//   --no-login         skip the login gate
//   --ignore-cert      pass --ignore-certificate-errors to chromium (needed for
//                      https://127.0.0.1, where the origin cert is for the public
//                      hostname: https keeps force_ssl + the CSRF Origin check
//                      happy, so production can be driven directly)
//   --profile-dir DIR  reuse a chromium profile at DIR. Default: a fresh temp dir
//                      per run. A REUSED profile keeps a cached /login page and a
//                      session cookie from the previous run; the first run after a
//                      server restart then POSTs a stale token and dies with
//                      "login was refused — wrong password?" (a 422
//                      InvalidAuthenticityToken, nothing to do with the password).
//                      Only pass this when you want the cookie to persist.
//
// Exit 1 if any selector matched nothing.

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const CHROME_GLOB = path.join(os.homedir(), '.cache/ms-playwright');

function findChrome() {
  if (process.env.CHROME_BIN) return process.env.CHROME_BIN;
  if (!fs.existsSync(CHROME_GLOB)) return null;
  for (const dir of fs.readdirSync(CHROME_GLOB).filter((d) => d.startsWith('chromium-'))) {
    for (const rel of ['chrome-linux64/chrome', 'chrome-linux/chrome']) {
      const p = path.join(CHROME_GLOB, dir, rel);
      if (fs.existsSync(p)) return p;
    }
  }
  return null;
}

function parseArgs(argv) {
  const out = { base: 'http://127.0.0.1:3999', path: '/', clicks: [], probes: [], clickProbes: [], evals: [],
                passwordEnv: 'CHOPSHOP_PASSWORD', envFile: path.join(os.homedir(), '.chopshop-studio.env'),
                login: true, port: 9223, width: 1440, height: 1200, ignoreCert: false,
                profileDir: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    if (a === '--base') out.base = next();
    else if (a === '--path') out.path = next();
    else if (a === '--click') out.clicks.push(next());
    else if (a === '--probe') out.probes.push(next());
    else if (a === '--click-probe') out.clickProbes.push(next());
    else if (a === '--eval') out.evals.push(next());
    else if (a === '--password-env') out.passwordEnv = next();
    else if (a === '--env-file') out.envFile = next();
    else if (a === '--port') out.port = Number(next());
    else if (a === '--no-login') out.login = false;
    else if (a === '--ignore-cert') out.ignoreCert = true;
    else if (a === '--profile-dir') out.profileDir = next();
    else if (a === '-h' || a === '--help') { console.log(fs.readFileSync(__filename, 'utf8').split('\n').slice(2, 32).join('\n')); process.exit(0); }
    else { console.error('unknown argument: ' + a); process.exit(2); }
  }
  return out;
}

// The password lives in the env file, never in this script or on the command line.
function readPassword(envName, envFile) {
  if (process.env[envName]) return process.env[envName];
  if (!fs.existsSync(envFile)) return null;
  for (const line of fs.readFileSync(envFile, 'utf8').split('\n')) {
    const m = line.match(new RegExp('^\\s*(?:export\\s+)?' + envName + '=(.*)$'));
    if (m) return m[1].trim().replace(/^["']|["']$/g, '');
  }
  return null;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class Session {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map();
    ws.onmessage = (m) => { const msg = JSON.parse(m.data);
      if (msg.id && this.pending.has(msg.id)) { this.pending.get(msg.id)(msg); this.pending.delete(msg.id); } }; }
  send(method, params = {}) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((res) => this.pending.set(id, (m) => res(m.result)));
  }
  async evaluate(expr) {
    const r = await this.send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
    if (r && r.exceptionDetails) throw new Error(r.exceptionDetails.exception && r.exceptionDetails.exception.description || 'eval failed');
    return r && r.result ? r.result.value : undefined;
  }
  async goto(url) {
    await this.send('Page.navigate', { url });
    for (let i = 0; i < 80; i++) { await sleep(150); if ((await this.evaluate('document.readyState')) === 'complete') break; }
    await sleep(250);
  }
  // A real mouse event at a real coordinate: this is what exercises hit-testing.
  async clickAt(x, y) {
    const p = { x: Math.round(x), y: Math.round(y), button: 'left', buttons: 1, clickCount: 1 };
    await this.send('Input.dispatchMouseEvent', Object.assign({ type: 'mouseMoved' }, p));
    await this.send('Input.dispatchMouseEvent', Object.assign({ type: 'mousePressed' }, p));
    await this.send('Input.dispatchMouseEvent', Object.assign({ type: 'mouseReleased', buttons: 0 }, p));
    await sleep(220);
  }
  // Synthetic keys need the text payload AND a char event, or the browser never
  // treats it as an activation (Enter/space on a focused button silently no-ops).
  async pressKey(code, key, keyCode, text) {
    const base = { code, key, windowsVirtualKeyCode: keyCode, nativeVirtualKeyCode: keyCode };
    if (text) { base.text = text; base.unmodifiedText = text; }
    await this.send('Input.dispatchKeyEvent', Object.assign({ type: 'keyDown' }, base));
    if (text) await this.send('Input.dispatchKeyEvent', Object.assign({ type: 'char', text }, base));
    await this.send('Input.dispatchKeyEvent', Object.assign({ type: 'keyUp' }, base));
    await sleep(250);
  }
}

async function attach(port) {
  let wsUrl = null;
  for (let i = 0; i < 60 && !wsUrl; i++) {
    await sleep(250);
    try {
      const list = await (await fetch('http://127.0.0.1:' + port + '/json/list')).json();
      const page = list.find((t) => t.type === 'page');
      if (page) wsUrl = page.webSocketDebuggerUrl;
    } catch (_) { /* not listening yet */ }
  }
  if (!wsUrl) throw new Error('chrome never exposed CDP on port ' + port);
  const ws = new WebSocket(wsUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  const s = new Session(ws);
  await s.send('Page.enable');
  await s.send('Runtime.enable');
  return s;
}

async function login(s, base, password) {
  await s.goto(base + '/login');
  if ((await s.evaluate('location.pathname')) !== '/login') { console.log('  (already authed)'); return; }
  // The gate is a scissor orb that opens a modal holding the password form.
  const centre = (sel) => `(() => { const el = document.querySelector(${JSON.stringify(sel)});
    if (!el) return null; const r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`;
  const orb = await s.evaluate(centre('#login-orb-btn'));
  if (orb) { await s.clickAt(orb.x, orb.y); await sleep(450); }
  const field = await s.evaluate(centre('#password'));
  if (!field) throw new Error('no #password field — login flow changed?');
  await s.evaluate(`document.getElementById('password').focus(); 1`);
  await s.send('Input.insertText', { text: password });
  const submit = await s.evaluate(centre('.login-gate-submit'));
  if (submit) { await s.clickAt(submit.x, submit.y); }
  else { await s.evaluate(`document.querySelector('#login-gate-holder form').submit(); 1`); }
  await sleep(1400);
  if ((await s.evaluate('location.pathname')) === '/login') throw new Error('login was refused — wrong password?');
}

const probeExpr = (sel) => `(() => {
  const el = document.querySelector(${JSON.stringify(sel)});
  if (!el) return { missing: true };
  el.scrollIntoView({ block: 'center' });
  const r = el.getBoundingClientRect();
  const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
  const top = document.elementFromPoint(cx, cy);
  const desc = (n) => n ? (n.tagName.toLowerCase() + (n.className ? '.' + String(n.className).trim().split(/\s+/).join('.') : '')) : 'none';
  return { w: Math.round(r.width), h: Math.round(r.height), x: Math.round(r.left), y: Math.round(r.top),
           cx: Math.round(cx), cy: Math.round(cy),
           top: desc(top),
           // does a click at the centre reach the element itself or a descendant of it?
           reachable: !!top && (top === el || el.contains(top)),
           focusable: el.tabIndex >= 0, label: el.getAttribute('aria-label') || el.getAttribute('title') || '' };
})()`;

(async function main() {
  const args = parseArgs(process.argv.slice(2));
  const chrome = findChrome();
  if (!chrome) { console.error('no chromium found; set CHROME_BIN'); process.exit(2); }
  const flags = ['--headless=new', '--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'];
  const profileDir = args.profileDir || fs.mkdtempSync(path.join(os.tmpdir(), 'cdp-verify-'));
  if (args.ignoreCert || args.base.startsWith('https')) flags.push('--ignore-certificate-errors');
  const proc = spawn(chrome, flags.concat([
    '--remote-debugging-port=' + args.port, '--window-size=' + args.width + ',' + args.height,
    '--user-data-dir=' + profileDir, 'about:blank']), { stdio: ['ignore', 'ignore', 'pipe'] });
  let failures = 0;
  try {
    const s = await attach(args.port);
    if (args.login) {
      const pw = readPassword(args.passwordEnv, args.envFile);
      if (!pw) { console.error('no password in $' + args.passwordEnv + ' or ' + args.envFile); process.exit(2); }
      await login(s, args.base, pw);
      console.log('login: ok');
    }
    await s.goto(args.base + args.path);
    console.log('page: ' + (await s.evaluate('location.pathname')) + '  title: ' + (await s.evaluate('document.title')));

    for (const sel of args.clicks) {
      const p = await s.evaluate(probeExpr(sel));
      if (p.missing) { console.log('click  ' + sel + '  MISSING'); failures++; continue; }
      await s.clickAt(p.cx, p.cy);
      console.log('click  ' + sel + '  at ' + p.cx + ',' + p.cy + '  (top element: ' + p.top + ')');
    }
    for (const sel of args.probes.concat(args.clickProbes)) {
      const p = await s.evaluate(probeExpr(sel));
      if (p.missing) { console.log('probe  ' + sel + '  MISSING'); failures++; continue; }
      const flag = p.reachable ? 'reachable' : 'BLOCKED by ' + p.top;
      console.log(`probe  ${sel}\n         ${p.w}x${p.h} at ${p.x},${p.y}  centre ${p.cx},${p.cy}  ${flag}` +
                  (p.label ? '\n         label: ' + p.label : ''));
      if (args.clickProbes.includes(sel)) {
        await s.clickAt(p.cx, p.cy);
        console.log('         clicked');
      }
    }
    for (const expr of args.evals) {
      let v;
      try { v = await s.evaluate(expr); } catch (e) { v = 'ERROR ' + e.message; failures++; }
      console.log('eval   ' + expr + '\n         => ' + JSON.stringify(v));
    }
    console.log('\n' + (failures ? 'PROBLEMS: ' + failures : 'all selectors resolved'));
  } catch (e) {
    console.error('ERROR ' + (e && e.stack || e));
    failures++;
  } finally {
    proc.kill();
  }
  process.exit(failures ? 1 : 0);
})();
