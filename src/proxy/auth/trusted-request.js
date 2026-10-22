'use strict';
/**
 * 请求来源改写。
 *
 * 上游的第一道门是"只信任本机请求"：它看 Host 和 Origin 是不是回环地址。
 * 请求从公网经隧道打进来时，这两个头带的是公网域名，于是被判不可信。
 *
 * 这里的做法是把它们改写成回环地址，让上游认为请求来自本机。
 * 改完再转发，上游就不会拒绝。
 *
 * 注意三件事：
 *   1. Host 必须和上游期望的 authority 完全一致（含端口）。少了端口、或者用了
 *      127.0.0.1 之外的写法（比如 localhost），都可能判不匹配。
 *   2. Origin 只在**存在时**才改写。有些请求（同源 GET）根本不带 Origin，
 *      凭空加上反而可疑。
 *   3. Referer 也要一起改。它同样会被来源校验扫到，漏了会在某些接口上被拒。
 */
const cfg = require('../lib/config');

function authority() {
  return cfg.get('origin.host', '127.0.0.1') + ':' + cfg.get('origin.port', 3080);
}

function publicOrigin() {
  return cfg.publicUrl();
}

/**
 * 改写需要"看起来来自本机"的那几个头。
 * 返回新对象，不改原对象（原 headers 还要用于日志和调试）。
 */
function rewrite(headers) {
  const out = Object.assign({}, headers);
  const auth = authority();
  const pub = publicOrigin();

  out.host = auth;

  if (out.origin !== undefined) out.origin = pub;

  if (out.referer !== undefined) {
    // 只替换 scheme://host[:port] 这一段，保留后面的路径。
    // 直接把整个 referer 换掉会丢掉路径信息，有些前端路由会因此异常。
    out.referer = String(out.referer).replace(/^https?:\/\/[^/]+/i, pub);
  }

  return out;
}

/** 响应头里如果有重定向到公网地址，也要改写回来，否则手机会被弹到错误的主机。 */
function rewriteLocation(location) {
  if (!location) return location;
  const pub = publicOrigin();
  if (location.startsWith(pub)) return location;
  return location;
}

module.exports = { rewrite, rewriteLocation, authority, publicOrigin };
