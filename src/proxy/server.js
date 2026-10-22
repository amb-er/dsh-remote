'use strict';
/**
 * 本地反向代理。
 *
 *   phone → Cloudflare → 隧道 → 本进程(127.0.0.1:3080) → 桌面端的 Web 端口
 *
 * 为什么需要代理：
 *   1. 桌面端监听的是一个**动态端口**（每次启动都不同），隧道配置无法写死
 *   2. 桌面端的来源校验会拒绝外部请求，必须由代理改写请求头
 *   3. 桌面端要求会话 cookie，必须由代理签发
 *
 * 为什么必须转发到桌面端自己的监听，而不是另起一个 DSH 实例：
 *   DSH 用内核级锁（Windows 上是命名信号量）串行化同一会话的写入，且该锁**跨进程**。
 *   另起实例会让手机和桌面端争抢同一个对话。转发到桌面端自己的监听，
 *   两边共享同一个写入者，冲突消失。
 *
 * 日志里的登录密钥会被打码——它等同于进入这台机器的凭据，不该出现在日志里。
 */
const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');

const cfg = require('../lib/config');
const cookie = require('./auth/session-cookie');
const trusted = require('./auth/trusted-request');

const ROOT = cfg.ROOT;
const LOG = path.join(ROOT, 'proxy.log');
const STATE = path.join(ROOT, 'state-proxy.json');
const KEY_FILE = path.join(ROOT, 'proxy-login-key.txt');

const LISTEN_HOST = cfg.get('proxy.host', '127.0.0.1');
const LISTEN_PORT = Number(cfg.get('proxy.listenPort', 3080));
const LOGIN_SUFFIX = cfg.get('auth.loginPathSuffix', '__dsh_login');
const PORT_TTL_MS = Number(cfg.get('proxy.portCacheMs', 300000));

// ------------------------------------------------------------------- logging

/**
 * 日志脱敏：把 URL 里的 key 换成 ***。
 *
 * 登录密钥等价于"能进这台机器"的凭据。早期版本把它原样打进日志，
 * 结果日志文件里躺着明文凭据——只要有人拿到日志就拿到了入口。
 */
function scrub(text) {
  // 第三个分组用负向断言跳过已经打过码的 ***，否则会把后面的说明文字一起吃进去。
  return String(text)
    .replace(new RegExp('(' + LOGIN_SUFFIX + '[^\\s]*?[?&]key=)((?!\\*\\*\\*)[^&\\s]+)', 'g'), '$1***')
    .replace(/(key=)((?!\*\*\*)[A-Za-z0-9_-]{8,})/g, '$1***');
}

function log(msg) {
  const line = new Date().toISOString() + '  ' + scrub(msg);
  try { fs.appendFileSync(LOG, line + '\n'); } catch (e) { /* 日志失败不影响服务 */ }
  if (process.env.DSH_PROXY_VERBOSE) process.stdout.write(line + '\n');
}

function writeState(s) {
  try { fs.writeFileSync(STATE, JSON.stringify(s, null, 2)); } catch (e) {}
}

// --------------------------------------------------------------- 登录密钥

/** 读登录密钥，没有就生成一个并落盘。每次调用都重读，方便轮换后立即生效。 */
function loginKey() {
  try {
    const existing = fs.readFileSync(KEY_FILE, 'utf8').trim();
    if (existing) return existing;
  } catch (e) { /* 还没创建 */ }
  const k = crypto.randomBytes(18).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  try { fs.writeFileSync(KEY_FILE, k); } catch (e) { log('无法保存登录密钥: ' + e.message); }
  return k;
}

// ------------------------------------------------------------ 端口发现

let cachedPort = null;
let cachedAt = 0;
let inflight = null;

/**
 * 找到桌面端 Web UI 的端口。
 *
 * 做法：先按进程名找到桌面端主进程，再看这个 PID 监听了哪个回环端口。
 *
 * 三个必须注意的点：
 *   1. **必须异步**。早先用 execFileSync，实测每次阻塞 2–12 秒，把事件循环卡死，
 *      所有在途请求一起卡住。
 *   2. **单飞**。并发请求共享同一次探测，否则缓存过期的瞬间会同时拉起多个 PowerShell。
 *   3. 失败时保留上次的端口作为"最佳猜测"，而不是返回空——上游可能只是忙，
 *      一个过期的端口会给出明确的上游错误，比一个误导性的 503 好。
 */
function discoverDesktopPort() {
  const now = Date.now();
  if (cachedPort && now - cachedAt < PORT_TTL_MS) return Promise.resolve(cachedPort);
  if (inflight) return inflight;

  const procName = cfg.get('origin.desktopProcess', '');
  const cmdMatch = cfg.get('origin.desktopProcessMatch', '');

  // 按配置拼 PowerShell。进程名和命令行特征都从配置来，脚本本身不含具体值。
  const psLines = ["$ErrorActionPreference='SilentlyContinue'"];
  if (procName) {
    psLines.push('$p = Get-CimInstance Win32_Process -Filter "Name=\'' + procName.replace(/'/g, "''") + '\'" |');
    if (cmdMatch) psLines.push("  Where-Object { $_.CommandLine -like '*" + cmdMatch.replace(/'/g, "''") + "*' } |");
    psLines.push('  Select-Object -First 1');
  } else {
    psLines.push('$p = $null');
  }
  psLines.push('if (-not $p) { exit 3 }');
  psLines.push('$c = Get-NetTCPConnection -State Listen -OwningProcess $p.ProcessId -ErrorAction SilentlyContinue |');
  psLines.push("  Where-Object { $_.LocalAddress -in @('127.0.0.1','::1') } |");
  psLines.push('  Select-Object -First 1');
  psLines.push('if (-not $c) { exit 4 }');
  psLines.push('Write-Output $c.LocalPort');
  const script = psLines.join('\n');

  // 先绑定到局部变量。在 executor 里直接引用模块级 inflight 不成立——
  // executor 是同步执行的，那时 inflight 还是 null。
  const p = new Promise((resolve) => {
    execFile('powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
      { encoding: 'utf8', timeout: 25000, windowsHide: true },
      (err, stdout) => {
        if (inflight === p) inflight = null;
        if (err) {
          log('端口发现失败: ' + (err.code || err.message));
          writeState({
            status: 'degraded',
            error: '未找到桌面端进程 (' + (err.code || err.message) + ')',
            stalePort: cachedPort,
            authority: trusted.authority(),
            at: new Date().toISOString(),
          });
          resolve(cachedPort);
          return;
        }
        const port = Number(String(stdout).trim());
        if (!Number.isInteger(port) || port <= 0) {
          log('端口发现没有拿到可用结果');
          resolve(cachedPort);
          return;
        }
        if (port !== cachedPort) log('桌面端 Web 端口 = ' + port);
        cachedPort = port;
        cachedAt = Date.now();
        writeState({ status: 'up', desktopPort: port, authority: trusted.authority(), at: new Date().toISOString() });
        resolve(port);
      });
  });

  inflight = p;
  p.catch(() => { if (inflight === p) inflight = null; });
  return p;
}

// ---------------------------------------------------------------- 转发

function forward(req, res, port) {
  const headers = trusted.rewrite(req.headers);
  // 要求不压缩：HTML 要被改写，gzip 的 body 得先解压。回环带宽够，不值得。
  headers['accept-encoding'] = 'identity';

  const preq = http.request({
    host: '127.0.0.1', port, path: req.url, method: req.method, headers,
  }, (pres) => {
    // 只改写 GET 的 HTML（用于注入 PWA 清单）；其余原样流式转发。
    const ctype = String(pres.headers['content-type'] || '');
    const encoded = pres.headers['content-encoding'] && pres.headers['content-encoding'] !== 'identity';
    const wantsRewrite = req.method === 'GET' && /text\/html/i.test(ctype) && !encoded && injectEnabled();

    if (!wantsRewrite) {
      res.writeHead(pres.statusCode, pres.headers);
      pres.pipe(res);
      return;
    }

    const chunks = [];
    let size = 0;
    pres.on('data', (c) => {
      chunks.push(c);
      size += c.length;
      // 安全阀：body 失控增长时放弃缓冲，直接原样转发。
      if (size > 8 * 1024 * 1024 && !res.headersSent) {
        res.writeHead(pres.statusCode, pres.headers);
        chunks.forEach((b) => res.write(b));
        pres.pipe(res);
        chunks.length = 0;
      }
    });
    pres.on('end', () => {
      if (res.headersSent) return;
      const html = injectPwaHead(Buffer.concat(chunks).toString('utf8'));
      const buf = Buffer.from(html, 'utf8');
      const out = Object.assign({}, pres.headers);
      delete out['content-encoding'];
      delete out['content-length'];
      // 必须连带删掉 transfer-encoding：留着它同时写 content-length，
      // Node 会按 chunked 发送而头里声称定长，客户端直接 HPE_INVALID_CONTENT_LENGTH。
      delete out['transfer-encoding'];
      out['content-length'] = buf.length;
      res.writeHead(pres.statusCode, out);
      res.end(buf);
    });
  });

  preq.on('error', (e) => {
    log('转发错误: ' + e.message);
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('桌面端不可达：' + e.message + '\n');
    } else {
      res.end();
    }
  });

  req.pipe(preq);
}

/** WebSocket / SSE 升级。这里要自己拼请求行，因为 http.request 不处理 upgrade。 */
function forwardUpgrade(req, socket, head, port) {
  const headers = trusted.rewrite(req.headers);
  delete headers['content-length'];
  delete headers['transfer-encoding'];

  const lines = [req.method + ' ' + req.url + ' HTTP/1.1'];
  for (const [k, v] of Object.entries(headers)) {
    if (Array.isArray(v)) v.forEach((one) => lines.push(k + ': ' + one));
    else lines.push(k + ': ' + v);
  }

  const up = net.connect(port, '127.0.0.1', () => {
    up.write(lines.join('\r\n') + '\r\n\r\n');
    if (head && head.length) up.write(head);
    up.pipe(socket);
    socket.pipe(up);
  });
  up.on('error', (e) => {
    log('升级错误: ' + e.message);
    try { socket.destroy(); } catch (err) {}
  });
  socket.on('error', () => { try { up.destroy(); } catch (e) {} });
  up.on('close', () => { try { socket.destroy(); } catch (e) {} });
  socket.on('close', () => { try { up.destroy(); } catch (e) {} });
}

// ------------------------------------------------------------------ PWA

/**
 * PWA 支持（可选）。
 *
 * 上游自带的 manifest 只声明了一个 SVG 图标（sizes: "any"），而 Chrome 的安装条件
 * 要求真实的 192/512 位图图标。所以代理覆盖 manifest 文档、自己提供 PNG 图标。
 *
 * 资源目录由 config.json 的 pwa.assetsDir 指定；目录不存在就整个功能关闭，
 * 代理行为退化成纯转发。
 */
const PWA_PREFIX = '/__dsh/pwa/';
const PWA_ICONS = {
  'icon-192.png': 'image/png',
  'icon-512.png': 'image/png',
  'icon-maskable-512.png': 'image/png',
};

function assetsDir() {
  return cfg.get('pwa.assetsDir', '');
}

function injectEnabled() {
  const d = assetsDir();
  return Boolean(d) && fs.existsSync(d);
}

function pwaManifest() {
  const appName = cfg.get('pwa.name', 'Remote App');
  const shortName = cfg.get('pwa.shortName', 'App');
  const theme = cfg.get('pwa.themeColor', '#0b1220');
  return {
    name: appName,
    short_name: shortName,
    start_url: '/',
    scope: '/',
    // standalone 保留状态栏（时间/电量）；fullscreen 会把它藏起来，手机上更差。
    display: 'standalone',
    orientation: 'any',
    background_color: theme,
    theme_color: theme,
    icons: [
      { src: PWA_PREFIX + 'icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
      { src: PWA_PREFIX + 'icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
      { src: PWA_PREFIX + 'icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
    ],
  };
}

/** 返回 true 表示这个请求已被本函数处理。 */
function servePwa(url, res) {
  if (!injectEnabled()) return false;
  const pathOnly = String(url || '').split('?')[0];

  if (pathOnly === '/manifest.webmanifest') {
    const body = Buffer.from(JSON.stringify(pwaManifest()), 'utf8');
    res.writeHead(200, {
      'content-type': 'application/manifest+json; charset=utf-8',
      'content-length': body.length,
      'cache-control': 'no-store',
    });
    res.end(body);
    return true;
  }

  if (pathOnly.startsWith(PWA_PREFIX)) {
    const name = pathOnly.slice(PWA_PREFIX.length);
    const type = PWA_ICONS[name];
    if (!type) return false;
    const file = path.join(assetsDir(), name);
    if (!fs.existsSync(file)) return false;
    const body = fs.readFileSync(file);
    res.writeHead(200, { 'content-type': type, 'content-length': body.length, 'cache-control': 'public, max-age=86400' });
    res.end(body);
    return true;
  }

  return false;
}

/** 往 app shell 里注入 manifest 链接。上游没链接它，所以浏览器不给"安装"选项。 */
function injectPwaHead(html) {
  if (!injectEnabled()) return html;
  if (html.includes('rel="manifest"')) return html;
  const link = '<link rel="manifest" href="/manifest.webmanifest">';
  if (/<head[^>]*>/i.test(html)) return html.replace(/<head[^>]*>/i, (m) => m + link);
  return link + html;
}

// ------------------------------------------------------------------ 强制 HTTPS

/**
 * 把经 Cloudflare 以明文进来的请求 308 跳到 HTTPS。
 *
 * 公网主机名在 http:// 上也能访问，而一个 29 天的会话 cookie 绝不能走明文。
 * Cloudflare 用 X-Forwarded-Proto 标注进来时的协议，所以这里判断它，
 * 而不是依赖控制台开关。本机直连（没有这个头）不受影响，方便排查。
 */
function enforceHttps(req, res) {
  const proto = req.headers['x-forwarded-proto'];
  if (proto !== 'http') return false;
  const host = req.headers['x-forwarded-host'] || req.headers.host || '';
  if (!host) return false;
  res.writeHead(308, { 'cache-control': 'no-store', location: 'https://' + host + (req.url || '/') });
  res.end();
  return true;
}

// ------------------------------------------------------------------- server

const server = http.createServer((req, res) => {
  const url = req.url || '/';

  if (enforceHttps(req, res)) {
    log('明文请求已跳转 HTTPS: ' + (req.headers['x-forwarded-host'] || req.headers.host));
    return;
  }

  if (servePwa(url, res)) return;

  // 注意：/__dsh 的兜底 404 必须放在登录路由**之后**。
  // 早先它放在前面，因为登录路由也以 /__dsh 开头，被它吞掉直接回 404，
  // 手机上表现为"没有这个地址"，整个入口失效。
  if (url.startsWith('/' + LOGIN_SUFFIX)) {
    const given = new URL(url, 'http://127.0.0.1').searchParams.get('key');
    const expected = loginKey();
    if (!expected || given !== expected) {
      log('登录被拒（密钥错误或已轮换），来源 ' + (req.socket.remoteAddress || '?'));
      res.writeHead(403, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('登录密钥不正确\n');
      return;
    }
    let minted;
    try {
      minted = cookie.mint();
    } catch (e) {
      log('签发 cookie 失败: ' + e.message);
      res.writeHead(503, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('无法签发会话凭据：' + e.message + '\n');
      return;
    }
    log('登录成功：已签发会话凭据');
    res.writeHead(303, {
      'cache-control': 'no-store',
      location: './',
      'set-cookie': minted.setCookie,
    });
    res.end();
    return;
  }

  if (String(url).split('?')[0].startsWith('/__dsh')) {
    log('未知的代理路由: ' + url);
    res.writeHead(404, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    res.end('<!doctype html><meta charset="utf-8"><title>404</title>' +
      '<body style="font:16px system-ui,sans-serif;padding:32px">' +
      '<h3>没有这个地址</h3><p>你访问的是：<code>' +
      String(url).replace(/[<>&]/g, '') + '</code></p></body>');
    return;
  }

  discoverDesktopPort().then((port) => {
    if (!port) {
      res.writeHead(503, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('桌面端没有运行（找不到它的监听端口）。\n' +
        '这个代理是转发给桌面端的，所以需要桌面端开着。\n');
      return;
    }
    forward(req, res, port);
  }).catch((e) => {
    log('分发错误: ' + e.message);
    if (!res.headersSent) {
      res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('代理分发错误\n');
    }
  });
});

server.on('upgrade', (req, socket, head) => {
  discoverDesktopPort().then((port) => {
    if (!port) { try { socket.destroy(); } catch (e) {} return; }
    forwardUpgrade(req, socket, head, port);
  }).catch((e) => {
    log('升级分发错误: ' + e.message);
    try { socket.destroy(); } catch (err) {}
  });
});

server.on('error', (e) => {
  // listen 失败是致命错误。没有这个显式处理器，它会变成 uncaughtException，
  // 被下面的兜底吞掉，留下一个什么都不提供的僵尸进程。
  log('服务错误: ' + (e && e.message));
  if (e && e.code === 'EADDRINUSE') {
    log('端口 ' + LISTEN_PORT + ' 已被占用；可能已有另一个代理在跑。退出。');
  }
  process.exit(1);
});

// 启动前先确认能读到密钥，读不到就别假装能服务。
try {
  cookie.secretKey();
} catch (e) {
  log('致命：' + e.message);
  process.stderr.write('无法读取会话密钥：' + e.message + '\n');
  process.exit(1);
}

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  log('代理已监听 http://' + LISTEN_HOST + ':' + LISTEN_PORT + ' -> 桌面端（动态端口）');
  const key = loginKey();
  log('登录路径: /' + LOGIN_SUFFIX + '  （密钥见 proxy-login-key.txt，日志中已打码）');
  if (process.env.DSH_PROXY_VERBOSE) {
    process.stdout.write('登录地址：http://' + LISTEN_HOST + ':' + LISTEN_PORT +
      '/' + LOGIN_SUFFIX + '?key=' + key + '\n');
  }
  writeState({ status: 'starting', authority: trusted.authority(), at: new Date().toISOString() });
});

process.on('SIGINT', () => { log('SIGINT'); process.exit(0); });
process.on('SIGTERM', () => { log('SIGTERM'); process.exit(0); });
// 一个坏请求不能把手机打下线。
process.on('uncaughtException', (e) => log('未捕获异常: ' + (e && e.message)));
process.on('unhandledRejection', (e) => log('未处理的 Promise 拒绝: ' + (e && e.message)));
