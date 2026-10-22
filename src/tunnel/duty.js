'use strict';
/**
 * 值班：先诊断，再决定动手。
 *
 * 早期版本只要探活失败就重建隧道。问题在于：
 *
 *   - **源站没开**时，隧道重建一百次也没用，只是每次白断一次线
 *   - **代理挂了**时，重建隧道同样无用
 *
 * 所以连续失败后先判断是哪一环坏了，能自己处理的先处理，处理不了再带着
 * 诊断结论通知——这样收到的消息是"桌面端没开，已自动拉起"，而不是笼统的"连不上"。
 *
 * 只有 tunnel 层异常才重建隧道。
 */
const fs = require('fs');
const path = require('path');
const http = require('http');
const { spawn, execFileSync } = require('child_process');
const cfg = require('../lib/config');

const DEFAULTS = {
  enabled: true,
  autoStartDesktop: true,
  autoRestartProxy: true,
  remediateCooldownMs: 600000,
  desktopWaitSeconds: 25,
  proxyWaitSeconds: 20,
};

function options() {
  return Object.assign({}, DEFAULTS, cfg.get('duty', {}));
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

/** 跑一段 PowerShell，返回 trim 后的 stdout。失败返回空串。 */
function ps(cmd) {
  try {
    return String(execFileSync('powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', cmd],
      { encoding: 'utf8', timeout: 25000, windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] })).trim();
  } catch (e) { return ''; }
}

/**
 * 代理是否在监听。
 *
 * 直接打回环端口而不是查进程表——**进程活着但没监听也算坏**，
 * 查进程会误判成健康。
 */
function isProxyUp(timeoutMs) {
  const port = Number(cfg.get('proxy.listenPort', 3080));
  const host = cfg.get('proxy.host', '127.0.0.1');
  return new Promise((resolve) => {
    const req = http.request(
      { host, port, path: '/', method: 'GET', timeout: timeoutMs || 4000 },
      (res) => { res.resume(); resolve(true); },
    );
    req.on('error', () => resolve(false));
    req.on('timeout', () => { req.destroy(); resolve(false); });
    req.end();
  });
}

/** 源站进程是否在跑；返回 pid 或 null。 */
function desktopPid() {
  const name = cfg.get('origin.desktopProcess', '');
  if (!name) return null;
  const match = cfg.get('origin.desktopProcessMatch', '');
  const safeName = name.replace(/'/g, "''");
  let cmd = '$p = Get-CimInstance Win32_Process -Filter "Name=\'' + safeName + '\'" -ErrorAction SilentlyContinue';
  if (match) {
    const safeMatch = match.replace(/'/g, "''").replace(/"/g, '`"');
    // 排除子进程：有些进程名相同但命令行不同，用特征串区分。
    cmd += ' | Where-Object { $_.CommandLine -like "*' + safeMatch + '*" -and $_.CommandLine -notlike "*runner.js*" }';
  }
  cmd += ' | Select-Object -First 1; if ($p) { $p.ProcessId }';
  const out = ps(cmd);
  const n = Number(out);
  return Number.isInteger(n) && n > 0 ? n : null;
}

/**
 * 判断当前是哪一环坏了。
 * 顺序很重要：源站是第一环，先看它。
 */
async function diagnose() {
  const proxyUp = await isProxyUp();
  const pid = desktopPid();
  let cause;
  let detail;
  if (!pid) {
    cause = 'desktop-down';
    detail = '源站进程没有运行（最常见的原因）';
  } else if (!proxyUp) {
    cause = 'proxy-down';
    detail = '本地代理端口没有响应';
  } else {
    cause = 'tunnel-down';
    detail = '本机代理和源站都正常，问题在隧道或网络一侧';
  }
  return { cause, detail, proxyUp, desktopPid: pid, at: new Date().toISOString() };
}

let lastRemedyKey = '';
let lastRemedyAt = 0;

/**
 * 尝试自助处理。返回 { tried, action, ok }。
 *
 * 同一类问题在冷却期内不重复处理——否则源站真的坏掉时会变成
 * "每 10 秒拉起一次 + 每 10 秒推一条"，比不处理更烦人。
 */
async function remediate(diag, log) {
  const opt = options();
  const say = log || (() => {});
  if (!opt.enabled) return { tried: false, action: '', ok: false };

  const now = Date.now();
  if (lastRemedyKey === diag.cause && now - lastRemedyAt < opt.remediateCooldownMs) {
    const mins = Math.round((opt.remediateCooldownMs - (now - lastRemedyAt)) / 60000);
    say('值班: ' + diag.cause + ' 冷却中（还有 ' + mins + ' 分钟），不重复处理');
    return { tried: false, action: '冷却中，未重复处理', ok: false };
  }

  if (diag.cause === 'desktop-down' && opt.autoStartDesktop) {
    const launcher = cfg.get('origin.launcher', '');
    if (!launcher) {
      say('值班: 源站没运行，但配置里没有 origin.launcher，无法自动拉起');
      return { tried: false, action: '未配置源站启动路径', ok: false };
    }
    lastRemedyKey = diag.cause;
    lastRemedyAt = now;
    say('值班: 尝试拉起源站');
    try {
      const child = spawn(launcher, [], { detached: true, stdio: 'ignore' });
      child.unref();
    } catch (e) {
      return { tried: true, action: '拉起源站失败：' + e.message, ok: false };
    }
    for (let i = 0; i < opt.desktopWaitSeconds; i++) {
      await sleep(1000);
      if (desktopPid()) {
        say('值班: 源站已起来');
        return { tried: true, action: '已自动拉起源站', ok: true };
      }
    }
    return { tried: true, action: '尝试拉起源站，但 ' + opt.desktopWaitSeconds + ' 秒内没检测到', ok: false };
  }

  if (diag.cause === 'proxy-down' && opt.autoRestartProxy) {
    const task = cfg.get('tasks.proxy', '');
    if (!task) {
      say('值班: 代理没响应，但配置里没有 tasks.proxy，无法自动启动');
      return { tried: false, action: '未配置代理计划任务名', ok: false };
    }
    lastRemedyKey = diag.cause;
    lastRemedyAt = now;
    say('值班: 尝试启动代理计划任务 ' + task);
    ps('Start-ScheduledTask -TaskName "' + task.replace(/"/g, '`"') + '"');
    for (let i = 0; i < opt.proxyWaitSeconds; i++) {
      await sleep(1000);
      if (await isProxyUp()) {
        say('值班: 代理已恢复');
        return { tried: true, action: '已自动启动本地代理', ok: true };
      }
    }
    return { tried: true, action: '尝试启动代理，但 ' + opt.proxyWaitSeconds + ' 秒内端口仍无响应', ok: false };
  }

  return { tried: false, action: '', ok: false };
}

module.exports = { diagnose, remediate, isProxyUp, desktopPid, options };
