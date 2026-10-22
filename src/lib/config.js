'use strict';
/**
 * 配置加载。
 *
 * 整个项目只有一个配置文件（config.json），放在仓库根目录，不进 git。
 * 所有硬编码的域名、路径、端口都从这里读，代码里不再出现具体值。
 *
 * 为什么用 JSON 而不是 YAML：这个项目同时有 Node 脚本和 PowerShell 脚本，
 * JSON 两边都能原生解析，YAML 在 PowerShell 里得额外装模块。
 */
const fs = require('fs');
const path = require('path');
const os = require('os');

const ROOT = path.resolve(__dirname, '..', '..');
const CONFIG_PATH = process.env.DSH_REMOTE_CONFIG || path.join(ROOT, 'config.json');

/** 把开头的 ~ 换成用户目录。 */
function expandHome(p) {
  if (!p) return p;
  if (p === '~') return os.homedir();
  if (p.startsWith('~/') || p.startsWith('~\\')) return path.join(os.homedir(), p.slice(2));
  return p;
}

let cached = null;

function load() {
  if (cached) return cached;

  if (!fs.existsSync(CONFIG_PATH)) {
    console.error('找不到配置文件：' + CONFIG_PATH);
    console.error('请先复制 config.example.json 为 config.json 并填写。');
    process.exit(1);
  }

  let raw;
  try {
    // 去掉可能的 BOM：PowerShell 的 Set-Content/Out-File 默认会写 UTF-8 BOM，
    // 而 JSON.parse 遇到 BOM 会直接报 "Unexpected token"，报错位置还很误导。
    const text = fs.readFileSync(CONFIG_PATH, 'utf8').replace(/^\uFEFF/, '');
    raw = JSON.parse(text);
  } catch (e) {
    console.error('config.json 解析失败：' + e.message);
    process.exit(1);
  }

  // 展开所有 _ 开头的键是注释，直接跳过；只对已知路径字段做 ~ 展开
  const cfg = JSON.parse(JSON.stringify(raw));
  if (cfg.tunnel) {
    cfg.tunnel.configPath = expandHome(cfg.tunnel.configPath);
    cfg.tunnel.cloudflaredPath = expandHome(cfg.tunnel.cloudflaredPath);
  }
  if (cfg.auth) cfg.auth.secretFile = expandHome(cfg.auth.secretFile);
  if (cfg.origin) cfg.origin.launcher = expandHome(cfg.origin.launcher);
  if (cfg.reports) {
    cfg.reports.outputDir = expandHome(cfg.reports.outputDir);
    cfg.reports.workRoot = expandHome(cfg.reports.workRoot);
    cfg.reports.sessionDir = expandHome(cfg.reports.sessionDir);
  }

  cfg.root = ROOT;
  cached = cfg;
  return cfg;
}

/** 取配置项，支持 'auth.cookieTtlDays' 这种点路径，带默认值。 */
function get(dotted, fallback) {
  const cfg = load();
  const parts = String(dotted).split('.');
  let cur = cfg;
  for (const k of parts) {
    if (cur == null || typeof cur !== 'object' || !(k in cur)) return fallback;
    cur = cur[k];
  }
  return cur === undefined ? fallback : cur;
}

/** 公共 URL（https://<domain>），不带宽尾斜杠。 */
function publicUrl() {
  const d = get('domain', '');
  return d ? 'https://' + d : '';
}

module.exports = { load, get, publicUrl, expandHome, ROOT, CONFIG_PATH };
