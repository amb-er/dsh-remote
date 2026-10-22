# dsh-remote

**把桌面版 DeepSeek Harness 变成手机上随处可用的服务。**

用 Cloudflare 隧道 + 本地反向代理 + 原生 Android 壳，在任何地方打开手机就能接管你电脑上的 DSH 会话——
不用装 VPN、不用开公网端口、不用配置 DDNS。

> **English summary**: Expose the desktop DeepSeek Harness on a fixed HTTPS domain through a
> Cloudflare named tunnel, with a self-hosted reverse proxy that handles the harness's
> trusted-request check, an optional Cloudflare Worker for Basic Auth, an Android WebView shell,
> plus a health-checking supervisor that diagnoses and heals common failures.
> Requires a local install of DeepSeek Harness and a Cloudflare-managed domain.

---

## 它解决什么问题

DeepSeek Harness 桌面端有三层限制，让它天然"出不了这台机器"：

| 限制 | 表现 |
|---|---|
| 只监听 `127.0.0.1` | 局域网里别的设备也访问不到 |
| 会话令牌只在内存里 | 进程重启，所有会话失效 |
| 校验请求来源（Host / Origin 必须是本机） | 外部流量即便能连到端口，也会被判定为不可信 |

这个项目把这三件事逐个解决，最终效果是：**手机上一个图标，点开就是你的 DSH**。

---

## 架构

```
   手机 / 平板
       │  https://your-domain.example
       ▼
 ┌─────────────────────────────┐
 │  Cloudflare 边缘             │
 │  · DNS + TLS                │
 │  · Worker（可选）Basic Auth  │
 └─────────────┬───────────────┘
               │  命名隧道（无需公网 IP）
               ▼
 ┌─────────────────────────────┐
 │  cloudflared                │
 │  · 出站连接，穿透 NAT        │
 └─────────────┬───────────────┘
               │  127.0.0.1:3080
               ▼
 ┌─────────────────────────────┐
 │  本地反向代理（本项目）        │
 │  · 重写 Host / Origin        │  ← 让上游认为是本机请求
 │  · 签发会话 cookie           │  ← 让上游认为已登录
 │  · 登录路由 / PWA / APK 分发  │
 └─────────────┬───────────────┘
               │  127.0.0.1:<动态端口>
               ▼
 ┌─────────────────────────────┐
 │  DeepSeek Harness 桌面端      │
 └─────────────────────────────┘
        ▲
        │  健康探活 + 自诊断 + 自愈
 ┌──────┴──────────────────────┐
 │  隧道守护（supervisor + duty）│
 └─────────────────────────────┘
```

---

## 特性

**访问层**
- 固定域名，不再有"重启后地址变了"的问题
- 多子域分流：一个隧道同时转发多个本地端口
- 登录链接：一次性点击换取约 29 天的会话

**可靠性**
- 探活 + 自动重建隧道
- **故障自诊断**：先判断是源站、代理还是隧道坏了，再决定动不动手
  （源站没开时重建隧道毫无意义，只会白断一次线）
- 崩了自动拉起，连续失败才告警

**移动端**
- PWA：Chrome 里"安装应用"即可，无需 APK
- Android APK：WebView 壳，可内嵌登录链接，点开即用

**运维**
- WinForms 管理界面：增删转发规则、启停隧道、看状态
- 写配置前用 `cloudflared ingress validate` 校验，坏配置永远写不进去
- 可选的钉钉推送：地址、告警、恢复、日报

---

## 快速开始

> 不提供一键安装脚本。这个工具会签发认证凭据，请按步骤理解后再部署。

### 0. 前置条件

- Windows 10/11
- 已安装 **DeepSeek Harness** 桌面版，并能正常运行
- 一个托管在 **Cloudflare** 的域名（NS 已指向 Cloudflare）
- Node.js 22+（项目里的脚本用 `zlib.zstdDecompress`，低版本没有）

### 1. 安装 cloudflared

```powershell
winget install --id Cloudflare.cloudflared
```

**不要在项目目录里运行它**——详见 [docs/pitfalls.md](docs/pitfalls.md) 第 1 条。

### 2. 创建命名隧道

```powershell
cloudflared tunnel login          # 浏览器授权
cloudflared tunnel create dsh     # 记下输出的隧道 ID
```

### 3. 配置

```powershell
copy config.example.json config.json
```

编辑 `config.json`，至少填 `domain`、`tunnel.name`、`origin.port`。

### 4. 启动代理

```powershell
node src/proxy/server.js
```

打开 `http://127.0.0.1:3080`，看到应用界面就说明代理通了。

首次启动会自动生成 `proxy-login-key.txt`（登录密钥）。手机端的入口是：

```
https://<你的域名>/__dsh_login?key=<密钥>
```

点一次换取约 29 天的会话。密钥可以随时替换文件内容来轮换，不用重启代理。

> 可选：把 192/512 的 PNG 图标放进 `assets/pwa/`，代理会提供可安装的 PWA。
> 目录不存在时该功能自动关闭，代理退化成纯转发。

### 5. 起隧道

编辑 `~/.cloudflared/config.yml`：

```yaml
tunnel: <你的隧道ID>
credentials-file: C:/Users/<你>/.cloudflared/<隧道ID>.json
ingress:
  - hostname: your-domain.example
    service: http://127.0.0.1:3080
  - service: http_status:404
```

```powershell
cloudflared tunnel route dns dsh your-domain.example
cloudflared tunnel run dsh
```

现在手机访问 `https://your-domain.example` 应该能打开了。

### 6. 让它常驻（可选）

```powershell
.\scripts\register-tasks.ps1
```

注册计划任务：隧道守护、代理守护。**默认没有开机自启**，需要的话见脚本内注释。

---

## 管理界面

```powershell
powershell -STA -File src/gui/tunnel-gui.ps1
```

图形化管理 ingress 分流规则，不用手改 YAML。

| 能做 | 说明 |
|---|---|
| 查看状态 | 守护 / cloudflared / 代理 / 源站，四行分开，一眼看出哪一环坏了 |
| 增删改规则 | 域名 + 端口 + 备注 |
| 停用 / 启用 | 从 ingress 移除但保留域名与备注，随时恢复 |
| 启停隧道 | 直接操作计划任务（界面里的「重启」只是让守护重拉进程） |
| 登录链接 | 显示并复制 `https://<域名>/<loginPath>?key=...` |
| 查看日志 | 最近 50 行 |

几个设计决定：

- **备注**写成 YAML 注释（`# ...`），配置文件仍然合法，人肉打开也看得懂
- **停用**不是注释掉那几行，而是移到旁挂文件 `disabled-routes.json`。
  注释形式在重新读取时无法可靠区分「被停用的规则」和「普通说明注释」
- **写盘前先校验**：先写临时文件、跑 `cloudflared ingress validate`，通过才落盘。
  坏配置永远没机会把隧道搞挂
- **入口域名不能停用**：它是守护探活的目标，停掉会触发误判和反复重建

自检（不弹窗，只跑逻辑）：

```powershell
powershell -STA -File src/gui/tunnel-gui.ps1 -Selftest
```

会验证 YAML 读写往返、备注保留、兜底规则位置、域名/端口校验、安全写入兜底，
并断言**真实配置一个字节都没动**。

## 配置说明

全部配置在 `config.json`，字段含义见 [config.example.json](config.example.json)。

几个容易踩的点：

| 字段 | 说明 |
|---|---|
| `auth.cookieTtlDays` | 服务端硬上限 **30 天**，写 31 会被拒绝。默认 29 留余量 |
| `tunnel.cloudflaredPath` | 必须指向项目目录**之外**的可执行文件 |
| `origin.port` | 代理自己监听 3080，DSH 的真实端口是动态的，代理会自动发现 |

---

## 它是怎么工作的

三份文档，按需读：

- **[docs/architecture.md](docs/architecture.md)** — 整体设计、数据流、为什么这样分层
- **[docs/auth-internals.md](docs/auth-internals.md)** — 会话 cookie 的构造、TTL 上限、来源校验细节
- **[docs/pitfalls.md](docs/pitfalls.md)** — 开发过程中踩过的每一个坑，含复现方式和修法

---

## 已知限制

- **只支持 Windows**。代理本身是跨平台的，但守护、计划任务、GUI 都是 Windows 专用
- **依赖 DSH 的内部实现**：密钥文件位置、cookie 格式、进程名都可能随版本变化。
  升级 DSH 后如果连不上，先看 [docs/auth-internals.md](docs/auth-internals.md) 的"版本兼容"
- **不做多用户**。这是给单机单用户设计的
- 隧道守护的"自动拉起源站"依赖 Electron 的单实例锁，行为可能因版本而异

---

## 免责声明

- 这个项目用于**在你自己的机器上、访问你自己的安装**。请勿用它访问任何你不拥有的实例
- 它会读取本机密钥并签发会话凭据。请确保 `config.json` 和密钥文件**不进版本库**
- 依赖的是第三方产品的内部实现，不保证长期有效，也不代表该产品官方的任何立场
- 生产环境暴露到公网前，请自行评估风险；建议至少加一层 Worker Basic Auth（`worker/`）

---

## License

[MIT](LICENSE)
