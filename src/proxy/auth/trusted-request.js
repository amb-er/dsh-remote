'use strict';
/**
 * 请求来源改写。
 *
 * 上游第一道门是"只信任本机请求"：它把 `Host` 和 `Origin` 对比，
 * 并要求它们指向回环地址。请求从公网经隧道打进来时，这两个头带的是公网域名，
 * 于是被判不可信。
 *
 * 关键点：**Origin 要改成回环地址，不是改回公网域名。**
 *
 * 直觉上会以为"Origin 应该和浏览器发来的一致"，但上游的做法是拿 Origin 跟 Host
 * 比对（同源检查），而 Host 已经被我们改成回环了。所以两边必须一起变成回环，
 * 才构成"同源"。
 *
 * 验证方式：改完这两个头后，上游返回 200 而不是"不可信来源"。
 *
 * 另外三个细节：
 *   1. Host 要带上游端口，只写 IP 可能判不匹配
 *   2. Origin 是**条件改写**——同源 GET 根本不带这个头，凭空补一个反而可疑
 *   3. Referer 也必须改，漏掉它某些接口会以"来源非法"拒绝，且报错不指向它
 */
const cfg = require('../../lib/config');

/**
 * Host 改写值。用的是代理自己的监听地址，不是上游的动态端口——
 * 上游只校验回环特性，不校验端口；但要和 cookie 的 authority 保持一致。
 */
function authority() {
  return cfg.get('proxy.host', '127.0.0.1') + ':' + cfg.get('proxy.listenPort', 3080);
}

/** 本地代理自己的 origin——Origin/Referer 都要改写成它，才能和 Host 同源。 */
function localOrigin() {
  const port = cfg.get('proxy.listenPort', 3080);
  return 'http://' + cfg.get('proxy.host', '127.0.0.1') + ':' + port;
}

/**
 * 改写需要"看起来来自本机"的那几个头。
 * 返回新对象，不改原对象（原 headers 还要用于日志）。
 */
function rewrite(headers) {
  const out = Object.assign({}, headers);
  const auth = authority();
  const origin = localOrigin();

  out.host = auth;

  if (out.origin !== undefined) out.origin = origin;

  if (out.referer !== undefined) {
    // 只替换 scheme://host[:port] 这一段，保留后面的路径。
    // 整个换掉会丢路径信息，有些前端路由会因此异常。
    out.referer = String(out.referer).replace(/^https?:\/\/[^/]+/i, origin);
  }

  return out;
}

module.exports = { rewrite, authority, localOrigin };
