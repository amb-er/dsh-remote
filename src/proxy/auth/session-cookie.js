'use strict';
/**
 * 会话 cookie 的构造。
 *
 * 这是整个项目最关键的一块——也是唯一"绕开"上游校验的地方，所以要讲清楚原理。
 *
 * 背景
 * ----
 * DSH 桌面端只信任来自本机的请求：它检查请求的 Host / Origin 是不是回环地址。
 * 外部请求经过隧道打进来时，Host 是公网域名、Origin 也是公网地址，于是被判定不可信，
 * 直接拒绝。这就是"端口通了但还是打不开"的原因。
 *
 * 两道门
 * ------
 *   1. 来源校验（trusted-request.js 负责）：把 Host / Origin 改写成回环地址。
 *   2. 会话校验（本文件负责）：上游要求一个合法的浏览器会话 cookie，
 *      而它用的是自己签发、自己校验的 HMAC。
 *
 * 为什么能自己签？
 * ----------------
 * 因为"签名密钥"本来就存在这台机器上（DSH 用它自己签发 cookie）。
 * 我们不是在破解什么，只是用同一个密钥、按同样的格式签一个。
 * 前提是：你和 DSH 跑在同一台机器上，且你有权读它的配置目录。
 *
 * 格式（v1）
 * ---------
 *   cookie 值 = "v1." + b64url(payload 的 JSON) + "." + b64url(HMAC-SHA256(key, b64url(payload)))
 *
 *   payload = { version: 1, authority, issuedAt, expiresAt }
 *
 *   cookie 名 = "dsh-auth-" + b64url(sha256(authority))
 *
 * 两个实测出来的关键细节，照抄错的会全都不生效：
 *
 *   1. **密钥要 base64url 解码成 32 个原始字节再参与 HMAC**。
 *      配置里存的是 base64url 字符串，直接拿字符串当 key 算出来的签名永远不对，
 *      而且报错信息只会说"未认证"，极难定位。
 *
 *   2. **TTL 上限正好是 30 天**。31 天会被拒（二分定位过）。这里默认取 29 天留余量，
 *      别指望"写长一点更省事"。
 */
const fs = require('fs');
const crypto = require('crypto');
const cfg = require('../../lib/config');

const b64url = (buf) => Buffer.from(buf).toString('base64')
  .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/**
 * Host 改写值，同时也是 cookie 的 authority。
 *
 * 注意这里是**代理自己的监听地址**，不是上游那个动态端口。
 * 上游只校验"是不是回环地址"，端口具体是多少无所谓；
 * 但 Host 和 cookie 里的 authority 必须一致，否则 cookie 名对不上、校验失败。
 */
function authority() {
  return cfg.get('proxy.host', '127.0.0.1') + ':' + cfg.get('proxy.listenPort', 3080);
}

/**
 * 从 DSH 的凭据文件里读出 browser-session 记录下的 secret。
 *
 * 文件是 YAML，但我们只需要其中一个字段，所以按行扫描而不引 yaml 依赖。
 * 结构大致是：
 *
 *   records:
 *     client-connection/browser-session:
 *       kind: grant
 *       payload:
 *         secret: <base64url>
 */
function readSecretRaw() {
  const file = cfg.get('auth.secretFile');
  const record = cfg.get('auth.secretRecord', 'client-connection/browser-session');

  if (!file || !fs.existsSync(file)) {
    throw new Error('找不到凭据文件：' + file + '（检查 config.json 的 auth.secretFile）');
  }

  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  const recordRe = new RegExp('^\\s*' + record.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ':\\s*$');
  let inRecord = false;

  for (const line of lines) {
    if (recordRe.test(line)) { inRecord = true; continue; }
    if (!inRecord) continue;

    // 遇到下一个同级记录就说明这个块结束了
    if (/^\s{0,2}[\w@./-]+:\s*$/.test(line) && !/payload|kind|version|secret/.test(line)) break;

    const m = line.match(/^\s*secret:\s*(\S+)\s*$/);
    if (m) return m[1].replace(/^["']|["']$/g, '');
  }

  throw new Error('在 ' + file + ' 里没找到 records.' + record + '.payload.secret');
}

/** 把 base64url 字符串还原成 32 字节原始密钥。 */
function secretKey() {
  const raw = readSecretRaw();
  const decoded = Buffer.from(raw.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
  if (decoded.length !== 32) {
    throw new Error('密钥长度不对：期望 32 字节，实际 ' + decoded.length + ' 字节。' +
      '注意要把 base64url 解码后再当 HMAC key 用。');
  }
  return decoded;
}

/** cookie 名由 authority 决定，所以换端口/主机名后名字会变。 */
function cookieName() {
  return 'dsh-auth-' + b64url(crypto.createHash('sha256').update(authority()).digest());
}

/**
 * 签一个会话 cookie。
 *
 * 除非显式 wantTtlDays，否则用配置里的 auth.cookieTtlDays（默认 29）。
 * 超过 30 天会抛错，不让调用方在运行时才发现。
 */
function mint(opts) {
  const o = opts || {};
  const ttlDays = Number(o.ttlDays || cfg.get('auth.cookieTtlDays', 29));
  if (ttlDays > 30) throw new Error('TTL 不能超过 30 天（上游硬上限，31 天会被拒）');

  const key = o.secretKey || secretKey();
  const issuedAt = o.issuedAt || Date.now();
  const expiresAt = issuedAt + Math.round(ttlDays * 86400 * 1000);

  const payload = { version: 1, authority: authority(), issuedAt, expiresAt };
  const body = b64url(Buffer.from(JSON.stringify(payload), 'utf8'));
  const sig = b64url(crypto.createHmac('sha256', key).update(body).digest());
  const value = 'v1.' + body + '.' + sig;

  return {
    name: cookieName(),
    value,
    payload,
    /** 可直接塞进 Set-Cookie 的完整属性串 */
    setCookie: (function () {
      const name = cookieName();
      // Secure 无条件加：手机永远是通过 Cloudflare 的 HTTPS 进来的，
      // 明文请求在代理层会 308 跳转。不加 Secure 的话浏览器会把
      // 这个 29 天的凭据也通过 http:// 发出去，等于白送。
      return name + '=' + value +
        '; Max-Age=' + Math.floor(ttlDays * 86400) +
        '; Path=/' +
        '; Expires=' + new Date(expiresAt).toUTCString() +
        '; HttpOnly; SameSite=Strict; Secure';
    })(),
  };
}

/** 从 Cookie 头里挑出我们那个 cookie 的值（用于验证/调试）。 */
function extractFromHeader(cookieHeader) {
  if (!cookieHeader) return null;
  const name = cookieName();
  for (const part of String(cookieHeader).split(';')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    if (part.slice(0, i).trim() === name) return part.slice(i + 1).trim();
  }
  return null;
}

/** 自校验：用同一把密钥重算签名，用于本地验证 CLI。 */
function verify(cookieValue) {
  const m = /^v1\.([^.]+)\.([^.]+)$/.exec(String(cookieValue || ''));
  if (!m) return { ok: false, reason: '格式不是 v1.<payload>.<sig>' };
  const expected = b64url(crypto.createHmac('sha256', secretKey()).update(m[1]).digest());
  if (expected !== m[2]) return { ok: false, reason: '签名不匹配' };
  let payload;
  try {
    payload = JSON.parse(Buffer.from(m[1].replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8'));
  } catch (e) { return { ok: false, reason: 'payload 不是合法 JSON' }; }
  if (payload.expiresAt && Date.now() > payload.expiresAt) return { ok: false, reason: '已过期', payload };
  return { ok: true, payload };
}

module.exports = {
  authority, cookieName,
  readSecretRaw, secretKey,
  mint, extractFromHeader, verify,
};
