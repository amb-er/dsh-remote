# 踩过的坑

每条都是真实遇到过的，附**现象**、**原因**、**修法**。按"排查时最想先看到哪条"排序。

---

## 1. cloudflared 不能放在项目目录里

**现象**：`cloudflared tunnel login` 反复失败，报 `Access is denied`，换目录就好了。

**原因**：DSH 的文件沙箱会限制"二进制文件位于会话工作区内"的子进程。cloudflared 去读
`~/.cloudflared/cert.pem` 时被拦下。

**修法**：把可执行文件放到工作区之外，比如 `%LOCALAPPDATA%\cloudflared\`。

---

## 2. 判断 Cloudflare 错误不能看 `server` 头

**现象**：想区分"隧道没起来（Cloudflare 返回 1033）"和"隧道通了但源站出错"，
用 `server: cloudflare` 判断，结果**所有**响应都带这个头，等于没判断。

**修法**：只看状态码。

| 状态码 | 含义 |
|---|---|
| 502 / 503 / 504 | 边缘到了，但隧道没接上源站 |
| 1033（页面内容） | 隧道本身没运行 |
| 401 / 200 / 303 | 请求已经到达源站 |

---

## 3. 改写 HTML 后必须删两个头

**现象**：页面偶尔 `HPE_INVALID_CONTENT_LENGTH` 或直接乱码。

**原因**：注入 PWA 清单时改了 HTML，`content-length` 跟着改新值，但上游响应里还有
`transfer-encoding: chunked`。两个头同时存在时，Node 按 chunked 发送，而头里写的是固定长度。

**修法**：**两个都删**。只删 `content-length` 不够，只删 `transfer-encoding` 也不够。

---

## 4. 钉钉机器人的签名必须放 URL query

**现象**：钉钉一直返回 `errcode 310000`，提示签名不对。网上抄的示例是把 `sign` 放进 JSON body。

**原因**：那个写法是错的（或过时了）。签名要拼在 webhook URL 的查询参数上。

**修法**：

```
sign = base64(HMAC-SHA256(key=secret, msg=timestamp + "\n" + secret))
URL  = webhook + "?timestamp=<ts>&sign=<urlencoded sign>"
```

**另一个坑**：钉钉失败时也返回 **HTTP 200**，结果放在 JSON 的 `errcode` 里。
只看状态码会把每一次失败都当成成功。必须解析 `errcode === 0`。

---

## 5. 会话 cookie 的两个隐性前提

详见 [auth-internals.md](auth-internals.md)，这里只列最坑的：

**① 密钥要解码后再用**

配置里存的是 base64url 字符串。**直接拿字符串当 HMAC key 永远签不对**，
而且失败表现和"密钥读错了"完全一样，只说"未认证"。

**② TTL 上限正好 30 天**

30 天接受，31 天拒绝（二分定位）。写长一点不会更省事，只会更晚发现问题。

---

## 6. 计划任务失败不会自动重启

**现象**：给计划任务配了"失败后重启"，但任务挂了之后 `LastTaskResult` 一直是 0，
`State` 一直是 `Ready`，重启策略从来没触发过。

**原因**：进程正常退出（哪怕退出码非 0）在计划任务看来不算"失败"，重启策略不适用。

**修法**：不要依赖任务级重启。用**进程内的 while 循环**做守护：

```powershell
while ($true) {
  # 跑目标程序
  # 退出后等一会儿再拉起来
}
```

---

## 7. `& $exe` 对 GUI 子系统程序不阻塞

**现象**：脚本里 `& "C:\...\App.exe" --args`，下一行立刻执行了，程序还没跑完。

**原因**：PowerShell 对 GUI 子系统的可执行文件不等待（控制台程序才等）。

**修法**：用 `Start-Process -Wait`。

同类问题：**Electron 应用有单实例锁**，重复启动会静默转发给已有实例然后立刻退出。
如果要用 Electron 跑脚本，得设 `ELECTRON_RUN_AS_NODE=1`，否则启动的是 GUI。

---

## 8. PowerShell 5.1 读非 ASCII 脚本要 BOM

**现象**：`.ps1` 里有中文，双击运行报语法错误，但编辑器里看着完全正常。

**原因**：PowerShell 5.1 对无 BOM 的 UTF-8 文件按 ANSI 解码，中文变乱码，字符串引号被吃掉。

**修法**：保存为 **UTF-8 with BOM**。

**同类问题**：调用子进程时，子进程输出是 UTF-8，但控制台按 GBK 解码，日志全是乱码。
调用前要设：

```powershell
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
```

---

## 9. `git log` 统计产出必须按作者过滤

**现象**：自动生成的周报里出现了根本不是自己做的功能。

**原因**：`git log --all` 没有 `--author`，把**同一仓库里所有同事的提交**都算进来了。

**修法**：

```js
const email = execSync(`git -C ${repo} config user.email`).toString().trim();
execSync(`git -C ${repo} log --author="${email}" ...`);
```

**这条最危险**，因为结果听起来很合理——数字具体、措辞专业，不核对根本发现不了。

---

## 10. git 的裸日期会少算一整天

**现象**：`git log --since=2026-10-22 --until="2026-10-22 23:59"` 返回 0 条，
但当天明明有提交。

**原因**：git 对裸日期（只有 `YYYY-MM-DD`）用的是近似解析，和带时刻的解析结果不同，
窗口会整体偏移。

**修法**：裸日期补全时刻：

```js
since → since + ' 00:00:00'
until → until + ' 23:59:59'
```

---

## 11. PowerShell 里生成代码，双引号会提前求值

**现象**：用脚本生成要插入文件的代码，插进去的 `$foo.Text = 'x'` 变成了 `.Text = 'x'`。

**原因**：生成代码时用了双引号字符串，`$foo` 在自己这层就被求值成空串了。

**修法**：写"生成代码的代码"时用单引号，或转义 `$`。

---

## 12. 清理进程时别把自己杀了

**现象**：脚本执行到一半突然退出，退出码 `4294967295`。

**原因**：

```powershell
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*my-script*' } | Stop-Process
```

**执行这条命令的进程，自己的命令行里也含 `my-script`**，于是被一起杀了。

**修法**：加排除条件：

```powershell
Where-Object { $_.ProcessId -ne $PID -and ... }
```

---

## 13. .NET 的 `String.Replace` 替换全部匹配

**现象**：往文档里插一段说明，结果同时出现了 3 处。

**原因**：`String.Replace(old, new)` 替换的是**所有**出现，不是第一个。锚点在文档里有多处时就会重复插入。

**修法**：按行定位 + `RemoveRange`/`InsertRange` 精确操作，改完用标题列表核对有没有重复区块。
