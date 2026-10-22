'use strict';
/**
 * 钉钉自定义机器人推送。
 *
 * 两个必须知道的坑（都踩过）：
 *
 *   1. **签名要放在 URL query 上，不是 JSON body**。网上大量示例把 sign 放进
 *      body，实测会一直返回 `errcode 310000`（签名不匹配），即使 HMAC 本身算对了。
 *
 *   2. **失败也返回 HTTP 200**。关键词不对、签名错误、token 失效，钉钉统统回
 *      200，结论放在响应的 `errcode` 字段里。只看状态码会把每一次失败都当成成功。
 *
 * 签名算法：
 *   sign = base64(HMAC-SHA256(key=secret, msg=timestamp + "\n" + secret))
 */
const https = require('https');
const crypto = require('crypto');
const cfg = require('../lib/config');

function post(url, body) {
  return new Promise((resolve) => {
    const u = new URL(url);
    const req = https.request({
      hostname: u.hostname,
      path: u.pathname + u.search,
      method: 'POST',
      timeout: 15000,
      headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) },
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', (e) => resolve({ status: 0, error: e.code || e.message }));
    req.on('timeout', () => { req.destroy(); resolve({ status: 0, error: 'timeout' }); });
    req.write(body);
    req.end();
  });
}

/** 给 errcode 配一句人话，不然只看到一个数字不知道怎么办。 */
function hint(errcode) {
  const map = {
    310000: '签名或关键词校验失败——检查 sign 是否放在 URL query 上、以及机器人安全设置',
    300001: 'token 无效——webhook 地址可能已重置',
    130101: '发送过于频繁，触发限流',
  };
  return map[errcode] || '';
}

/**
 * 推送一条消息。
 *
 * kind:
 *   alert / recovered / reminder / daily / weekly  → 正文直接发出
 *   url                                            → 只发一个可点击的地址
 *
 * 日记与周报用 markdown 类型：它们天然是多段落带标题的长文，
 * 用纯文本发出去满屏都是裸的 # 和 *，手机上很难读。
 */
async function send(kind, content) {
  const enabled = cfg.get('notify.enabled', false);
  const hook = cfg.get('notify.dingtalkWebhook', '');
  if (!enabled || !hook) return { ok: false, skipped: true, reason: '未启用或未配置 webhook' };

  const titles = {
    alert: '⚠️ 远程访问告警',
    recovered: '✅ 已恢复',
    reminder: '📌 提醒',
    daily: '📓 每日记录',
    weekly: '📊 每周复盘',
    url: '🔗 远程访问地址',
    info: 'ℹ️ 通知',
  };
  const title = titles[kind] || titles.info;

  // 地址类只发内容本身，方便一点就开、复制。
  const body = (kind === 'url') ? String(content) : (title + '\n\n' + content);

  let target = hook;
  const secret = cfg.get('notify.dingtalkSecret', '');
  if (secret) {
    const stamp = String(Date.now());
    const sign = crypto.createHmac('sha256', secret)
      .update(stamp + '\n' + secret)
      .digest('base64');
    const u = new URL(hook);
    u.searchParams.set('timestamp', stamp);
    u.searchParams.set('sign', sign);
    target = u.href;
  }

  const isLongForm = kind === 'daily' || kind === 'weekly';
  const payload = isLongForm
    ? { msgtype: 'markdown', markdown: { title, text: body } }
    : { msgtype: 'text', text: { content: body } };

  const r = await post(target, JSON.stringify(payload));
  if (!r.ok && r.error) return { ok: false, error: r.error };

  let parsed;
  try { parsed = JSON.parse(r.body); } catch (e) {
    return { ok: false, status: r.status, body: String(r.body).slice(0, 200) };
  }
  if (parsed.errcode === 0) return { ok: true, status: r.status };
  return {
    ok: false,
    status: r.status,
    errcode: parsed.errcode,
    errmsg: parsed.errmsg,
    hint: hint(parsed.errcode),
  };
}

module.exports = { send };
