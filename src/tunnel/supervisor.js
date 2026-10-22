'use strict';
/**
 * 隧道守护。
 *
 * 职责：
 *   1. 拉起 cloudflared 并确认它真的注册上了边缘
 *   2. 定期探活公网地址，确认端到端可用
 *   3. 失败时先诊断哪一环坏了（duty），只有隧道层才重建
 *   4. 出事推一条通知，恢复再推一条，不刷屏
 *
 * 一个反直觉的点：**计划任务的"失败后重启"对这里没用。**
 * 进程正常退出（哪怕退出码非 0）在计划任务看来不算失败，重启策略不会触发。
 * 所以重启逻辑必须写在进程内（就是 restart 及其退避重试）。
 *
 * 用法：
 *   node src/tunnel/supervisor.js            正常守护
 *   node src/tunnel/supervisor.js --diagnose 只诊断，无副作用
 *   node src/tunnel/supervisor.js --remedy proxy-down   只测自动处理
 */
const fs = require('fs');
const path = require('path');
const https = require('https');
const { spawn } = require('child_process');

const cfg = require('../lib/config');
const duty = require('./duty');
const notify = require('../notify/dingtalk');

const ROOT = cfg.ROOT;
const LOG = path.join(ROOT, 'supervisor.log');
const STATE = path.join(ROOT, 'state-supervisor.json');

const CF = cfg.get('tunnel.cloudflaredPath', '');
const CONFIG = cfg.get('tunnel.configPath', '');
const TUNNEL = cfg.get('tunnel.name', 'dsh');
const PUBLIC = cfg.publicUrl();
const HEALTH_MS = Number(cfg.get('tunnel.healthMs', 45000));

function log(msg) {
  const line = new Date().toISOString() + '  ' + msg;
  process.stdout.write(line + '\n');
  try { fs.appendFileSync(LOG, line + '\n'); } catch (e) { /* 日志失败不影响守护 */ }
}

function writeState(s) {
  try { fs.writeFileSync(STATE, JSON.stringify(s, null, 2)); } catch (e) {}
}

let child = null;
let healthTimer = null;
let startFailures = 0;        // 连续"起不来"的次数
let restarting = false;
let startedAt = 0;
let consecutiveFailures = 0;  // 连续探活失败次数
let alerted = false;          // 已经发过告警还没恢复
let unverifiableLogged = false;
let lastDiagnosis = null;
let lastRemedy = null;

function stopChild() {
  if (healthTimer) { clearInterval(healthTimer); healthTimer = null; }
  if (child) {
    try { child.kill(); log('隧道已停止'); } catch (e) {}
    child = null;
  }
}

/**
 * 探活用的 Basic Auth 凭据。
 *
 * 从文件读而不是环境变量：环境变量会出现在计划任务的命令行里，
 * 任何人打开任务计划程序就能看到明文密码。
 */
function basicCredential() {
  if (process.env.DSH_BASIC_AUTH) return process.env.DSH_BASIC_AUTH;
  const file = cfg.get('tunnel.basicAuthFile', '');
  if (!file) return null;
  try {
    const v = fs.readFileSync(file, 'utf8').trim();
    return v || null;
  } catch (e) { return null; }
}

function readLoginKey() {
  try { return fs.readFileSync(path.join(ROOT, 'proxy-login-key.txt'), 'utf8').trim(); } catch (e) { return ''; }
}

/** 探公网地址，判断端到端是否可用。 */
function probe() {
  const cred = basicCredential();
  const headers = { 'User-Agent': 'tunnel-supervisor' };
  if (cred) headers.Authorization = 'Basic ' + Buffer.from(cred).toString('base64');

  return new Promise((resolve) => {
    const req = https.get(PUBLIC + '/', { timeout: 15000, headers }, (res) => {
      let body = '';
      res.on('data', (c) => { body += c; if (body.length > 600) req.destroy(); });
      res.on('end', () => {
        const wwwAuth = String(res.headers['www-authenticate'] || '');
        const isBasicChallenge = res.statusCode === 401 && /basic/i.test(wwwAuth);

        // 401 + Basic challenge 说明请求根本没到源站——要么没带凭据，要么凭据被拒。
        // 后者是"密码错了"，绝不能算健康。
        if (isBasicChallenge) {
          return resolve({
            ok: false,
            unverifiable: !cred,
            status: res.statusCode,
            error: cred
              ? 'Basic Auth 被拒绝（凭据可能已更换），请求未到达源站'
              : '前面有 Basic Auth，未提供凭据，无法判断隧道状态',
          });
        }

        // 注意：不能用 `server: cloudflare` 头判断——每个响应都带它。
        // 只能看状态码。
        if (res.statusCode === 401 || res.statusCode === 200 || res.statusCode === 303) {
          return resolve({ ok: true, status: res.statusCode });
        }
        resolve({ ok: false, status: res.statusCode, body: body.slice(0, 200), error: 'HTTP ' + res.statusCode });
      });
    });
    req.on('error', (e) => resolve({ ok: false, error: e.code || e.message }));
    req.on('timeout', () => { req.destroy(); resolve({ ok: false, error: 'timeout' }); });
  });
}

function pushNotify(kind, content) {
  notify.send(kind, content).then((r) => {
    if (!r.ok && !r.skipped) log('通知失败: ' + JSON.stringify(r));
  }).catch((e) => log('通知异常: ' + e.message));
}

/** 把失败的探活翻译成一句能看懂的话。 */
function describeFailure(r) {
  if (r.status === 503) return '源站没有运行，手机暂时无法访问。';
  if (r.status === 502 || r.status === 530) return '隧道无法连接到本机（可能是网络问题），正在自动重试。';
  if (r.status === 1033) return '隧道进程没有运行。';
  if (r.error === 'timeout') return '访问超时，正在自动重试。';
  if (r.error) return '连接失败：' + r.error + '，正在自动重试。';
  return '远程访问异常（HTTP ' + r.status + '），正在自动重试。';
}

/** 把诊断结论和处理结果拼成一条通知。 */
function buildAlert(r, diag, remedy) {
  if (!diag) return describeFailure(r);
  let msg;
  if (diag.cause === 'desktop-down') msg = '源站进程没有运行，手机无法访问。';
  else if (diag.cause === 'proxy-down') msg = '本地代理没有响应。';
  else if (diag.cause === 'tunnel-down') msg = '隧道或网络异常，本机服务本身正常。';
  else msg = describeFailure(r);

  if (remedy && remedy.action) {
    msg += '\n处理：' + remedy.action;
    msg += remedy.ok ? '，服务已恢复。' : '，需要人工检查。';
  }
  return msg;
}

function start() {
  return new Promise((resolve, reject) => {
    if (!CF) return reject(new Error('配置里没有 tunnel.cloudflaredPath'));
    if (!fs.existsSync(CF)) {
      return reject(new Error('找不到 cloudflared：' + CF + '（放在项目目录之外，见 docs/pitfalls.md 第 1 条）'));
    }
    // 用 config 文件而不是 --url：--url 只会装一条兜底规则，只能转发一个服务；
    // 多主机名分流必须写显式 ingress。
    if (!CONFIG) return reject(new Error('配置里没有 tunnel.configPath'));
    if (!fs.existsSync(CONFIG)) {
      return reject(new Error('找不到隧道配置：' + CONFIG + '（多主机名分流需要显式 ingress）'));
    }

    log('启动: cloudflared tunnel --config ' + CONFIG + ' run ' + TUNNEL);
    const c = spawn(CF, ['tunnel', '--config', CONFIG, 'run', TUNNEL], {
      cwd: ROOT, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
    });
    child = c;
    startedAt = Date.now();

    let registered = false;
    // 边缘的 QUIC 拨号偶发超时，cloudflared 会自己重试。60 秒太紧，
    // 会把正在恢复的隧道拆掉，导致公网入口反复抖动。实测 120 秒合适。
    const timer = setTimeout(() => {
      if (!registered) reject(new Error('120 秒内没有注册上边缘连接'));
    }, 120000);

    const scan = (buf) => {
      for (const raw of buf.toString().split(/\r?\n/)) {
        const line = raw.trim();
        if (!line) continue;
        if (/Registered tunnel connection/.test(line)) {
          registered = true;
          clearTimeout(timer);
          const loc = /location=([a-z0-9]+)/.exec(line);
          log('已注册' + (loc ? ' @ ' + loc[1] : ''));
          resolve(c);
        } else if (/ERR|WRN|error/i.test(line) && !/Retrying connection/.test(line)) {
          log('cf: ' + line.slice(0, 180));
        }
      }
    };
    c.stdout.on('data', scan);
    c.stderr.on('data', scan);

    c.on('exit', (code) => {
      log('cloudflared 退出 code=' + code);
      if (!registered) {
        clearTimeout(timer);
        reject(new Error('注册前就退出了，code=' + code));
        return;
      }
      if (c !== child) { log('忽略已被替换的隧道退出'); return; }
      restart('隧道退出');
    });
  });
}

async function restart(reason) {
  if (restarting) return;
  restarting = true;
  try {
    stopChild();
    try {
      await start();
    } catch (e) {
      startFailures += 1;
      log('启动失败: ' + e.message + '（第 ' + startFailures + ' 次）');
      writeState({ status: 'down', error: e.message, at: new Date().toISOString() });
      // 连隧道都起不来，值得推一条；但不该每次重试都推。
      if (startFailures === 3 && !alerted) {
        alerted = true;
        pushNotify('alert', '隧道连续 ' + startFailures + ' 次无法建立连接，手机暂时无法访问。正在继续重试。');
      }
      const wait = Math.min(180000, 10000 * Math.pow(2, Math.min(startFailures, 4)));
      setTimeout(() => restart('重试'), wait);
      return;
    }

    startFailures = 0;
    writeState({
      status: 'up',
      tunnel: TUNNEL,
      publicUrl: PUBLIC,
      loginUrl: PUBLIC + '/__dsh_login?key=' + readLoginKey(),
      reason,
      at: new Date().toISOString(),
    });
    log('已就绪: ' + PUBLIC);

    scheduleHealth();
  } finally {
    restarting = false;
  }
}

function scheduleHealth() {
  if (healthTimer) clearInterval(healthTimer);
  healthTimer = setInterval(async () => {
    try {
      const r = await probe();
      const age = Math.round((Date.now() - startedAt) / 1000);

      // 有 Basic Auth 在但没凭据时，边缘会在隧道之前就回答，健康无从判断。
      // 不重建（那是噪音），也不谎称健康，只说一次。
      if (r.unverifiable) {
        if (!unverifiableLogged) {
          unverifiableLogged = true;
          log('探活不可判定: ' + r.error);
          log('  处理: 在 DSH_BASIC_AUTH 或 tunnel.basicAuthFile 里配置凭据，探活才能到达源站');
        }
        return;
      }
      unverifiableLogged = false;

      if (r.ok) {
        log('探活正常 ' + r.status + ' (t+' + age + 's)');
        consecutiveFailures = 0;
        lastDiagnosis = null;
        lastRemedy = null;
        if (alerted) {
          alerted = false;
          pushNotify('recovered', PUBLIC + '/__dsh_login?key=' + readLoginKey());
        }
        return;
      }

      consecutiveFailures += 1;
      log('探活失败 #' + consecutiveFailures + ' (' + (r.error || r.status) + ')');

      // 一次抖动是噪声，连续两次才动手。动手前先判断哪一环坏了。
      if (consecutiveFailures === 2) {
        lastDiagnosis = await duty.diagnose();
        log('值班: 诊断 -> ' + lastDiagnosis.cause + '（' + lastDiagnosis.detail + '）');
        lastRemedy = await duty.remediate(lastDiagnosis, log);
        if (lastRemedy.tried) log('值班: ' + lastRemedy.action + ' ok=' + lastRemedy.ok);

        if (lastDiagnosis.cause === 'tunnel-down') {
          log('值班: 隧道层异常，重建');
          restart('探活恢复');
        } else {
          log('值班: 源头问题，不重建隧道，等下一轮探活');
        }
        return;
      }

      if (consecutiveFailures >= 3 && !alerted) {
        alerted = true;
        pushNotify('alert', buildAlert(r, lastDiagnosis, lastRemedy));
      }
    } catch (e) {
      log('探活异常: ' + e.message);
    }
  }, HEALTH_MS);
}

// ---------------------------------------------------------------------- 入口

if (process.argv.includes('--diagnose')) {
  duty.diagnose().then((d) => {
    log('诊断: ' + JSON.stringify(d));
    let plan;
    if (d.cause === 'desktop-down') plan = duty.options().autoStartDesktop ? '会尝试拉起源站' : '源站没运行，但配置关闭了自动拉起';
    else if (d.cause === 'proxy-down') plan = duty.options().autoRestartProxy ? '会尝试启动代理计划任务' : '代理无响应，但配置关闭了自动启动';
    else plan = '隧道层问题，会重建隧道';
    log('计划: ' + plan);
    process.exit(0);
  }).catch((e) => { log('诊断失败: ' + e.message); process.exit(1); });
} else if (process.argv.includes('--remedy')) {
  const which = process.argv[process.argv.indexOf('--remedy') + 1] || 'proxy-down';
  duty.remediate({ cause: which, detail: '手动测试' }, log).then((r) => {
    log('处理结果: ' + JSON.stringify(r));
    process.exit(r.ok ? 0 : 2);
  }).catch((e) => { log('处理失败: ' + e.message); process.exit(1); });
} else {
  process.on('SIGINT', () => { log('SIGINT'); stopChild(); process.exit(0); });
  process.on('SIGTERM', () => { log('SIGTERM'); stopChild(); process.exit(0); });
  process.on('uncaughtException', (e) => log('未捕获异常: ' + (e && e.message)));
  process.on('unhandledRejection', (e) => log('未处理的 Promise 拒绝: ' + (e && e.message)));

  log('=== 隧道守护启动 | tunnel=' + TUNNEL + ' public=' + PUBLIC + ' ===');
  restart('启动');
}
