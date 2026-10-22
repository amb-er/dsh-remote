<#
   隧道管理界面

   作用：图形化管理 cloudflared 的 ingress 分流规则，并启停隧道。

   设计要点：
     1. 规则的真身是 ~/.cloudflared/config.yml 里的 ingress 段。这个界面只是它的
        编辑器，不引入任何私有格式。
     2. 「备注」写成一行的 YAML 注释（# ...）——配置文件里仍然合法，
        人肉打开也看得懂。
     3. 「停用」不是注释掉那几行，而是把条目移到旁挂文件 disabled-routes.json。
        原因：注释形式在重新读取时无法可靠区分「被停用的规则」和「普通说明注释」，
        而且 ingress 里多出 cloudflared 不认识的字段会让整份配置失效。
     4. 写盘前先跑一次 cloudflared ingress validate，不通过就不写——
        坏配置永远没机会把隧道搞挂。

   用法：
     powershell -STA -File tunnel-gui.ps1              正常打开
     powershell -STA -File tunnel-gui.ps1 -Selftest    只跑逻辑自检（不弹窗）
#>
param(
    [switch]$Selftest
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- DPI 适配
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Dpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@ -ErrorAction Stop
    [void][Dpi]::SetProcessDPIAware()
} catch { }

$script:Scale = 1.0
try {
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:Scale = $g.DpiX / 96.0
    $g.Dispose()
} catch { }

function S([double]$v) { [int][Math]::Round($v * $script:Scale) }

$script:Root = $PSScriptRoot

# ---------------------------------------------------------------- 读取项目配置
function Load-ProjectConfig {
    $candidates = @(
        (Join-Path $script:Root 'config.json'),
        (Join-Path (Split-Path $script:Root -Parent) 'config.json'),
        (Join-Path (Split-Path (Split-Path $script:Root -Parent) -Parent) 'config.json')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $raw = [System.IO.File]::ReadAllText($c, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
            try { return ($raw | ConvertFrom-Json) } catch { }
        }
    }
    return $null
}

function Expand-Home([string]$p) {
    if (-not $p) { return $p }
    if ($p -eq '~') { return $env:USERPROFILE }
    if ($p.StartsWith('~/') -or $p.StartsWith('~\')) { return (Join-Path $env:USERPROFILE $p.Substring(2)) }
    return $p
}

$script:ProjectCfg = Load-ProjectConfig
if (-not $script:ProjectCfg) {
    [System.Windows.Forms.MessageBox]::Show("找不到 config.json。`n`n请在项目根目录复制 config.example.json 为 config.json 并填写。", '缺少配置') | Out-Null
    exit 1
}

$script:CfExe = Expand-Home $script:ProjectCfg.tunnel.cloudflaredPath
$script:CfgPath = Expand-Home $script:ProjectCfg.tunnel.configPath
$script:TunnelName = $script:ProjectCfg.tunnel.name
$script:Zone = $script:ProjectCfg.domain
$script:PrimaryHost = $script:ProjectCfg.domain
$script:ProxyPort = $script:ProjectCfg.proxy.listenPort
$script:LogPath = Join-Path $script:Root 'supervisor.log'
$script:DisabledPath = Join-Path $script:Root 'disabled-routes.json'

# cloudflared 和配置文件都必须存在，否则界面做不了任何事
if (-not (Test-Path $script:CfExe)) {
    [System.Windows.Forms.MessageBox]::Show("找不到 cloudflared：$($script:CfExe)`n`n检查 config.json 的 tunnel.cloudflaredPath。", '缺少依赖') | Out-Null
    exit 1
}
if (-not (Test-Path $script:CfgPath)) {
    [System.Windows.Forms.MessageBox]::Show("找不到隧道配置：$($script:CfgPath)`n`n先按 README 创建隧道并写 ingress。", '缺少依赖') | Out-Null
    exit 1
}

# ---------------------------------------------------------------- 停用规则旁挂
# 停用 = 从 config.yml 移除、条目转存到本文件。
function Read-Disabled {
    if (-not (Test-Path $script:DisabledPath)) { return @() }
    try {
        $raw = [System.IO.File]::ReadAllText($script:DisabledPath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
        if (-not $raw -or $raw.Trim() -eq '') { return @() }
        return @($raw | ConvertFrom-Json)
    } catch { return @() }
}

function Write-Disabled($list) {
    $arr = @($list)
    if ($arr.Count -eq 0) {
        if (Test-Path $script:DisabledPath) { Remove-Item $script:DisabledPath -Force -ErrorAction SilentlyContinue }
        return
    }
    # 手写 JSON：Windows PowerShell 5.1 的 ConvertTo-Json 对单元素数组会退化成对象，
    # 读回来就不是数组了。值只有域名、URL、备注，需要转义的只有反斜杠和引号。
    $items = foreach ($d in $arr) {
        $note = [string]$d.Note
        $note = $note.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
        '{"hostname":"' + $d.Hostname + '","service":"' + $d.Service + '","note":"' + $note + '"}'
    }
    [System.IO.File]::WriteAllText($script:DisabledPath, '[' + ($items -join ',') + ']', (New-Object System.Text.UTF8Encoding $false))
}

# ------------------------------------------------------------------ ingress 读写
function Read-Ingress([string]$Path) {
    if (-not (Test-Path $Path)) { throw "找不到配置文件: $Path" }
    $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)

    $head = New-Object System.Collections.Generic.List[string]
    $entries = New-Object System.Collections.Generic.List[object]
    $inIngress = $false
    $pendingComment = New-Object System.Collections.Generic.List[string]
    $current = $null

    foreach ($raw in $lines) {
        $line = $raw.TrimEnd()
        if (-not $inIngress) {
            if ($line -match '^\s*ingress:\s*$') { $inIngress = $true; continue }
            $head.Add($line)
            continue
        }

        $trimmed = $line.Trim()
        if ($trimmed -eq '') { continue }
        if ($trimmed.StartsWith('#')) {
            # 注释就是这条规则的备注，存成纯文本（不含 #），写回时再加前缀。
            $pendingComment.Add(($trimmed -replace '^#\s?', ''))
            continue
        }

        if ($trimmed -match '^-\s*hostname:\s*(\S+)\s*$') {
            $current = [pscustomobject]@{
                Hostname = $Matches[1]
                Service  = ''
                Note     = ($pendingComment -join "`n")
            }
            $entries.Add($current)
            $pendingComment.Clear()
            continue
        }
        # 兜底规则写作 "- service: http_status:404"（带短横线、没有 hostname）。
        # 必须单独匹配：早期版本只认 "service:" 开头的行，漏读了兜底规则，
        # 而写回时又只写已知条目——等于点任何按钮都会把兜底规则删掉。
        if ($trimmed -match '^-\s*service:\s*(\S+)\s*$') {
            $current = [pscustomobject]@{
                Hostname = ''
                Service  = $Matches[1]
                Note     = ($pendingComment -join "`n")
            }
            $entries.Add($current)
            $pendingComment.Clear()
            continue
        }
        if ($trimmed -match '^service:\s*(\S+)\s*$') {
            if ($current -and -not $current.Service) { $current.Service = $Matches[1] }
            continue
        }
    }

    [pscustomobject]@{ Head = $head; Entries = $entries }
}

function Write-Ingress($cfg, [string]$Path) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($h in $cfg.Head) { [void]$sb.AppendLine($h) }
    [void]$sb.AppendLine('ingress:')
    foreach ($e in $cfg.Entries) {
        if ($e.Note) {
            foreach ($c in ($e.Note -split "`n")) {
                if ($c.Trim() -ne '') { [void]$sb.AppendLine('  # ' + $c.Trim()) }
            }
        }
        if ($e.Hostname) {
            [void]$sb.AppendLine('  - hostname: ' + $e.Hostname)
            [void]$sb.AppendLine('    service: ' + $e.Service)
        } else {
            [void]$sb.AppendLine('  - service: ' + $e.Service)
        }
    }
    if (Test-Path $Path) { Copy-Item $Path "$Path.bak" -Force }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
}

# ------------------------------------------------------------------ 输入校验
# cloudflared 的 ingress validate 几乎不设防：example.com、单标签、下划线、
# 带空格的域名它都放行，真正会失败的只有 YAML 解析错误。所以必须自己把关。
function Test-Hostname([string]$Name) {
    $n = ([string]$Name).Trim().ToLowerInvariant().TrimEnd('.')
    if ($n -eq '') { return @{ Ok = $false; Message = '域名不能为空' } }
    if ($n.Length -gt 253) { return @{ Ok = $false; Message = '域名总长不能超过 253 个字符' } }
    if ($n -notmatch '^[a-z0-9.-]+$') {
        return @{ Ok = $false; Message = "只能用字母、数字、连字符和点。不能有空格、下划线、冒号或 *（输入的是：$n）" }
    }
    if ($n -notmatch '\.') { return @{ Ok = $false; Message = "至少要有一个点，并且必须是 $($script:Zone) 或其子域" } }
    $zone = $script:Zone
    if ($n -ne $zone -and -not $n.EndsWith('.' + $zone)) {
        return @{ Ok = $false; Message = "必须是 $zone 或其子域（例如 dev.$zone）。写别的域名建不了 DNS 记录。" }
    }
    foreach ($label in $n.Split('.')) {
        if ($label -eq '') { return @{ Ok = $false; Message = '域名里有空的段（连续的点，或开头/结尾有点）' } }
        if ($label.Length -gt 63) { return @{ Ok = $false; Message = '每一段最多 63 个字符' } }
        if ($label.StartsWith('-') -or $label.EndsWith('-')) { return @{ Ok = $false; Message = '每一段不能以连字符开头或结尾' } }
    }
    return @{ Ok = $true; Normalized = $n; Message = '' }
}

function Test-PortNumber([string]$Text) {
    $t = ([string]$Text).Trim()
    if ($t -notmatch '^\d+$') { return @{ Ok = $false; Message = '端口必须是数字' } }
    $n = [int]$t
    if ($n -lt 1 -or $n -gt 65535) { return @{ Ok = $false; Message = '端口必须在 1 到 65535 之间' } }
    return @{ Ok = $true; Value = $n; Message = '' }
}

# 先写临时文件、用 cloudflared 校验通过，才落盘到真实配置。
# 这是最后一道保险：即便输入校验有漏网之鱼，坏配置也没机会把隧道搞挂。
function Save-IngressSafe($cfg, [string]$TargetPath) {
    $tmp = Join-Path $env:TEMP ('ingress-candidate-' + [guid]::NewGuid().ToString('N') + '.yml')
    try {
        Write-Ingress $cfg -Path $tmp
        $out = & $script:CfExe tunnel --config $tmp ingress validate 2>&1 | Out-String
        if ($out -notmatch 'OK') {
            return @{ Ok = $false; Message = $out.Trim() }
        }
        Write-Ingress $cfg -Path $TargetPath
        return @{ Ok = $true; Message = '' }
    } catch {
        return @{ Ok = $false; Message = $_.Exception.Message }
    } finally {
        Remove-Item $tmp, "$tmp.bak" -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------ 运行状态
function Get-PortOf($service) {
    if (-not $service) { return 0 }
    $m = [regex]::Match([string]$service, ':(\d+)\s*$')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

function Test-Port([int]$port) {
    if ($port -le 0) { return $false }
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $r = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        $ok = $r.AsyncWaitHandle.WaitOne(400)
        $c.Close()
        return $ok
    } catch { return $false }
}

function Get-CfProcess {
    Get-Process cloudflared -ErrorAction SilentlyContinue
}

function Get-SupervisorAlive {
    Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*supervisor.js*' -and $_.CommandLine -notlike '*runner.js*' } |
        Select-Object -First 1
}

# --------------------------------------------------------------- 自检模式
if ($Selftest) {
    $fail = 0
    $tmp = Join-Path $env:TEMP ('ingress-selftest-' + [guid]::NewGuid().ToString('N') + '.yml')
    $realHash = (Get-FileHash $script:CfgPath -Algorithm SHA256).Hash

    try {
        # 1) 用真实配置做一次读写往返，确认备注和兜底规则都不丢
        $cfg = Read-Ingress $script:CfgPath
        Write-Host "读取: $($cfg.Entries.Count) 条规则"
        foreach ($e in $cfg.Entries) {
            $h = if ($e.Hostname) { $e.Hostname } else { '(兜底)' }
            Write-Host "  [$h] -> $($e.Service)"
        }
        $withNote = @($cfg.Entries | Where-Object { $_.Note }).Count
        Write-Host "含备注的规则: $withNote 条"

        Write-Ingress $cfg -Path $tmp
        $back = Read-Ingress $tmp
        if ($back.Entries.Count -ne $cfg.Entries.Count) { Write-Host "❌ 往返后条数不一致"; $fail++ }
        else { Write-Host "✅ 读写往返一致" }

        $tail = $back.Entries[$back.Entries.Count - 1]
        if ($tail.Hostname -eq '' -and $tail.Service -like 'http_status*') { Write-Host "✅ 兜底规则仍在最后" }
        else { Write-Host "❌ 兜底规则丢失或被移动"; $fail++ }

        foreach ($orig in $cfg.Entries) {
            $match = $back.Entries | Where-Object { $_.Hostname -eq $orig.Hostname -and $_.Service -eq $orig.Service }
            if (-not $match) { Write-Host "❌ 条目丢失: $($orig.Hostname)"; $fail++ }
            elseif ($match.Note -ne $orig.Note) { Write-Host "❌ 备注不一致: $($orig.Hostname)"; $fail++ }
        }

        # 2) 端口解析
        if ((Get-PortOf 'http://127.0.0.1:5173') -eq 5173) { Write-Host "✅ 端口解析正确" }
        else { Write-Host "❌ 端口解析错误"; $fail++ }

        # 3) 域名校验
        $valid = @("dev.$($script:Zone)", $script:Zone, "A-B.$($script:Zone)")
        $invalid = @('', 'example.com', 'foo', 'my_domain.com', '*.x.com', 'bad host.com', 'a..b.com', '-bad.com', 'bad-.com')
        foreach ($h in $valid) {
            if (-not (Test-Hostname $h).Ok) { Write-Host "❌ 合法域名被判非法: $h"; $fail++ }
        }
        foreach ($h in $invalid) {
            if ((Test-Hostname $h).Ok) { Write-Host "❌ 非法域名被放行: [$h]"; $fail++ }
        }
        Write-Host "✅ 域名校验（合法 $($valid.Count) / 非法 $($invalid.Count)）"

        # 4) 端口范围
        foreach ($p in @(1, 80, 8080, 65535)) { if (-not (Test-PortNumber $p).Ok) { Write-Host "❌ 合法端口被拒: $p"; $fail++ } }
        foreach ($p in @(0, 65536, -1, 'abc', '')) { if ((Test-PortNumber $p).Ok) { Write-Host "❌ 非法端口被放行: [$p]"; $fail++ } }
        Write-Host "✅ 端口范围校验（1–65535）"

        # 5) 安全写入兜底：构造一条会让 cloudflared 解析失败的规则（* 在 YAML 里是别名）
        $guardTarget = $tmp + '.guard.yml'
        Remove-Item $guardTarget -Force -ErrorAction SilentlyContinue
        $bad = Read-Ingress $script:CfgPath
        $bad.Entries.Insert(0, [pscustomobject]@{ Hostname = '*.invalid'; Service = 'http://127.0.0.1:1'; Note = '' })
        $res = Save-IngressSafe $bad -TargetPath $guardTarget
        if ($res.Ok) { Write-Host "❌ 非法配置被安全写入放行了"; $fail++ }
        elseif (Test-Path $guardTarget) { Write-Host "❌ 校验失败却仍写入了目标文件"; $fail++ }
        else { Write-Host "✅ 安全写入：非法配置被拦下，目标文件未生成" }
        Remove-Item $guardTarget, "$guardTarget.bak" -Force -ErrorAction SilentlyContinue

        # 6) 真实配置必须一个字节都没动
        if ((Get-FileHash $script:CfgPath -Algorithm SHA256).Hash -eq $realHash) { Write-Host "✅ 真实配置未被改动（哈希一致）" }
        else { Write-Host "❌ 真实配置被改动了！"; $fail++ }

        Write-Host ''
        if ($fail -eq 0) { Write-Host '自检全部通过'; exit 0 }
        Write-Host "自检失败 $fail 项"; exit 1
    } finally {
        Remove-Item $tmp, "$tmp.bak" -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------ 主窗口
$form = New-Object System.Windows.Forms.Form
$form.Text = '隧道管理'
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(11, 18, 32)
$form.ForeColor = [System.Drawing.Color]::FromArgb(231, 238, 252)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', [single](9 * $script:Scale))
$form.MinimumSize = New-Object System.Drawing.Size((S 640), (S 520))

function New-Label($text, $x, $y, $w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, (S 20))
    $l.AutoSize = $false
    return $l
}

# 状态区
$script:StatusRows = @()
$statusSpec = @(
    @{ Key = 'tunnel'; Text = '隧道守护' },
    @{ Key = 'cf';     Text = 'cloudflared' },
    @{ Key = 'proxy';  Text = '本地代理' },
    @{ Key = 'origin'; Text = '源站进程' }
)
$rowY = S 12
foreach ($spec in $statusSpec) {
    $l = New-Label $spec.Text (S 20) $rowY (S 110)
    $l.ForeColor = [System.Drawing.Color]::FromArgb(147, 164, 191)
    $form.Controls.Add($l)
    $v = New-Label '—' (S 130) $rowY (S 400)
    $form.Controls.Add($v)
    $script:StatusRows += [pscustomobject]@{ Key = $spec.Key; Label = $l; Value = $v }
    $rowY += S 22
}

# 规则列表
$list = New-Object System.Windows.Forms.ListView
$list.View = 'Details'
$list.FullRowSelect = $true
$list.HideSelection = $false
$list.MultiSelect = $false
[void]$list.Columns.Add('域名', (S 220))
[void]$list.Columns.Add('转发到', (S 170))
[void]$list.Columns.Add('备注', (S 260))
$form.Controls.Add($list)

# 输出区
$output = New-Object System.Windows.Forms.TextBox
$output.Multiline = $true
$output.ScrollBars = 'Vertical'
$output.BackColor = [System.Drawing.Color]::FromArgb(16, 24, 40)
$output.ForeColor = [System.Drawing.Color]::FromArgb(200, 214, 236)
$output.BorderStyle = 'FixedSingle'
$form.Controls.Add($output)

# 按钮：两行。第一行规则操作，第二行隧道操作
function New-Btn($text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.FlatStyle = 'Flat'
    $b.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $b.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $form.Controls.Add($b)
    return $b
}
$btnAdd = New-Btn '添加'
$btnEdit = New-Btn '修改'
$btnDel = New-Btn '删除'
$btnToggle = New-Btn '停用 / 启用'
$btnLink = New-Btn '登录链接'
$btnStart = New-Btn '启动隧道'
$btnStop = New-Btn '停止隧道'
$btnRestart = New-Btn '重启隧道'
$btnValidate = New-Btn '验证配置'
$btnLog = New-Btn '查看日志'

$script:Row1 = @(
    @{ B = $btnAdd; W = 90 }, @{ B = $btnEdit; W = 90 }, @{ B = $btnDel; W = 90 },
    @{ B = $btnToggle; W = 120 }, @{ B = $btnLink; W = 100 }
)
$script:Row2 = @(
    @{ B = $btnStart; W = 95 }, @{ B = $btnStop; W = 95 }, @{ B = $btnRestart; W = 95 },
    @{ B = $btnValidate; W = 95 }, @{ B = $btnLog; W = 95 }
)
foreach ($item in ($script:Row1 + $script:Row2)) {
    $item.B.Size = New-Object System.Drawing.Size((S $item.W), (S 34))
}

$script:Cfg = $null
$script:Disabled = @()

function Say($text) { $output.Text = $text }

# ------------------------------------------------------------------ 自适应排版
function Layout-Form {
    $pad = S 20
    $contentW = $form.ClientSize.Width - $pad * 2
    $y = S 12

    foreach ($row in $script:StatusRows) {
        $row.Label.Location = New-Object System.Drawing.Point($pad, $y)
        $row.Value.Location = New-Object System.Drawing.Point(($pad + (S 110)), $y)
        $row.Value.Width = $contentW - (S 110)
        $y += S 22
    }
    $y += S 8
    $listY = $y

    $btnRow1Y = $form.ClientSize.Height - $pad - (S 34) * 2 - (S 8) - (S 96) - (S 10)
    $btnRow2Y = $btnRow1Y + (S 34) + (S 8)
    $outputY = $btnRow2Y + (S 34) + (S 12)
    $outputH = [Math]::Max((S 70), ($form.ClientSize.Height - $pad - $outputY))
    $listH = [Math]::Max((S 60), $btnRow1Y - $listY - (S 12))

    $list.Location = New-Object System.Drawing.Point($pad, $listY)
    $list.Size = New-Object System.Drawing.Size($contentW, $listH)
    $lw = $contentW - (S 240)
    if ($lw -gt (S 260)) {
        $list.Columns[0].Width = [int]($lw * 0.40)
        $list.Columns[1].Width = [int]($lw * 0.28)
        $list.Columns[2].Width = [int]($lw * 0.32)
    }

    $gap = S 6
    $bx = $pad
    foreach ($item in $script:Row1) {
        $item.B.Location = New-Object System.Drawing.Point($bx, $btnRow1Y)
        $bx += $item.B.Width + $gap
    }
    $bx = $pad
    foreach ($item in $script:Row2) {
        $item.B.Location = New-Object System.Drawing.Point($bx, $btnRow2Y)
        $bx += $item.B.Width + $gap
    }

    $output.Location = New-Object System.Drawing.Point($pad, $outputY)
    $output.Size = New-Object System.Drawing.Size($contentW, $outputH)
    $output.Font = New-Object System.Drawing.Font('Consolas', [single](8.5 * $script:Scale))
}

# ------------------------------------------------------------------ 刷新
function Refresh-Status {
    foreach ($row in $script:StatusRows) {
        switch ($row.Key) {
            'tunnel' {
                if (Get-SupervisorAlive) { $row.Value.Text = '● 守护在运行'; $row.Value.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 150) }
                else { $row.Value.Text = '○ 守护未运行'; $row.Value.ForeColor = [System.Drawing.Color]::FromArgb(230, 150, 120) }
            }
            'cf' {
                $p = Get-CfProcess
                if ($p) { $row.Value.Text = "● 运行中 (pid $($p[0].Id))"; $row.Value.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 150) }
                else { $row.Value.Text = '○ 未运行'; $row.Value.ForeColor = [System.Drawing.Color]::FromArgb(230, 150, 120) }
            }
            'proxy' {
                if (Test-Port $script:ProxyPort) { $row.Value.Text = "● $($script:ProxyPort) 正常"; $row.Value.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 150) }
                else { $row.Value.Text = "○ $($script:ProxyPort) 未监听"; $row.Value.ForeColor = [System.Drawing.Color]::FromArgb(230, 150, 120) }
            }
            'origin' {
                $o = $null
                if ($script:ProjectCfg.origin.desktopProcess) {
                    $o = Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($script:ProjectCfg.origin.desktopProcess)) -ErrorAction SilentlyContinue | Select-Object -First 1
                }
                if ($o) { $row.Value.Text = "● 运行中 (pid $($o.Id))"; $row.Value.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 150) }
                else { $row.Value.Text = '○ 未运行 ← 手机连不上通常是这个原因'; $row.Value.ForeColor = [System.Drawing.Color]::FromArgb(230, 150, 120) }
            }
        }
    }
}

function Get-NoteFirstLine($note) {
    if (-not $note) { return '' }
    return (($note -split "`n")[0])
}

function Refresh-Rules {
    $list.Items.Clear()
    $script:Disabled = Read-Disabled
    foreach ($e in $script:Cfg.Entries) {
        $h = if ($e.Hostname) { $e.Hostname } else { '(兜底)' }
        $it = New-Object System.Windows.Forms.ListViewItem($h)
        [void]$it.SubItems.Add($e.Service)
        [void]$it.SubItems.Add((Get-NoteFirstLine $e.Note))
        $it.Tag = $e
        [void]$list.Items.Add($it)
    }
    foreach ($d in $script:Disabled) {
        $it = New-Object System.Windows.Forms.ListViewItem("$($d.Hostname)  [已停用]")
        [void]$it.SubItems.Add($d.Service)
        [void]$it.SubItems.Add((Get-NoteFirstLine $d.Note))
        $it.Tag = $d
        $it.ForeColor = [System.Drawing.Color]::FromArgb(140, 150, 170)
        [void]$list.Items.Add($it)
    }
}

function Load-Ingress {
    $script:Cfg = Read-Ingress $script:CfgPath
    Refresh-Rules
}

# ------------------------------------------------------------------ 规则编辑窗
function Show-EditDialog($title, $hostname, $port, $note) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $title
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size((S 460), (S 240))
    $dlg.BackColor = $form.BackColor
    $dlg.ForeColor = $form.ForeColor
    $dlg.Font = $form.Font

    $dlg.Controls.Add((New-Label '域名' (S 20) (S 22) (S 80)))
    $tbH = New-Object System.Windows.Forms.TextBox
    $tbH.Location = New-Object System.Drawing.Point((S 110), (S 20))
    $tbH.Size = New-Object System.Drawing.Size((S 330), (S 24))
    $tbH.Text = $hostname
    $dlg.Controls.Add($tbH)

    $hint = New-Label "必须是 $($script:Zone) 或其子域" (S 110) (S 46) (S 330)
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(140, 150, 170)
    $dlg.Controls.Add($hint)

    $dlg.Controls.Add((New-Label '端口' (S 20) (S 78) (S 80)))
    $tbP = New-Object System.Windows.Forms.TextBox
    $tbP.Location = New-Object System.Drawing.Point((S 110), (S 76))
    $tbP.Size = New-Object System.Drawing.Size((S 100), (S 24))
    $tbP.Text = $port
    $dlg.Controls.Add($tbP)

    $dlg.Controls.Add((New-Label '备注' (S 20) (S 114) (S 80)))
    $tbN = New-Object System.Windows.Forms.TextBox
    $tbN.Location = New-Object System.Drawing.Point((S 110), (S 112))
    $tbN.Size = New-Object System.Drawing.Size((S 330), (S 24))
    $tbN.Text = $note
    $dlg.Controls.Add($tbN)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '确定'
    $ok.DialogResult = 'OK'
    $ok.Location = New-Object System.Drawing.Point((S 250), (S 180))
    $ok.Size = New-Object System.Drawing.Size((S 90), (S 32))
    $dlg.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.DialogResult = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point((S 350), (S 180))
    $cancel.Size = New-Object System.Drawing.Size((S 90), (S 32))
    $dlg.Controls.Add($cancel)

    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    $ok.Add_Click({
        $hostResult = Test-Hostname $tbH.Text
        if (-not $hostResult.Ok) {
            [System.Windows.Forms.MessageBox]::Show($hostResult.Message, '域名不合规', 'OK', 'Warning') | Out-Null
            $dlg.DialogResult = 'None'
            return
        }
        $portResult = Test-PortNumber $tbP.Text
        if (-not $portResult.Ok) {
            [System.Windows.Forms.MessageBox]::Show($portResult.Message, '端口不合规', 'OK', 'Warning') | Out-Null
            $dlg.DialogResult = 'None'
            return
        }
    })

    if ($dlg.ShowDialog($form) -ne 'OK') { return $null }
    return [pscustomobject]@{
        Hostname = (Test-Hostname $tbH.Text).Normalized
        Port     = (Test-PortNumber $tbP.Text).Value
        Note     = $tbN.Text.Trim()
    }
}

# ------------------------------------------------------------------ 事件
$btnAdd.Add_Click({
    $r = Show-EditDialog "添加转发规则（$($script:Zone) 的子域）" '' '' ''
    if (-not $r) { return }
    if (-not (Test-Port $r.Port)) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "本地端口 $($r.Port) 现在没有服务在监听。`n`n规则可以先建好，等服务起来自然就通了。要继续吗？",
            '端口未监听', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
    }
    try {
        $cfg = Read-Ingress $script:CfgPath
        if ($cfg.Entries | Where-Object { $_.Hostname -eq $r.Hostname }) {
            [System.Windows.Forms.MessageBox]::Show('这个域名已经存在了。', '重复') | Out-Null
            return
        }
        $new = [pscustomobject]@{ Hostname = $r.Hostname; Service = "http://127.0.0.1:$($r.Port)"; Note = $r.Note }
        # 插到兜底规则之前；没有兜底就追加
        $idx = -1
        for ($i = 0; $i -lt $cfg.Entries.Count; $i++) {
            if (-not $cfg.Entries[$i].Hostname) { $idx = $i; break }
        }
        if ($idx -ge 0) { $cfg.Entries.Insert($idx, $new) } else { $cfg.Entries.Add($new) }

        $saved = Save-IngressSafe $cfg -TargetPath $script:CfgPath
        if (-not $saved.Ok) {
            Say ("配置校验未通过，未写入：" + $saved.Message)
            [System.Windows.Forms.MessageBox]::Show("配置校验未通过，已放弃本次修改（原有配置未动）。`n`n" + $saved.Message, '未保存', 'OK', 'Warning') | Out-Null
            return
        }
        Say "正在为 $($r.Hostname) 建立 DNS 记录…"
        $dns = & $script:CfExe tunnel route dns $script:TunnelName $r.Hostname 2>&1 | Out-String
        Say "配置已写入并建立 DNS。正在重启隧道…`n$dns"
        Load-Ingress
        Refresh-Status
        Say "✅ 已添加 $($r.Hostname) → $($r.Port)"
    } catch {
        Say "添加失败: $($_.Exception.Message)"
    }
})

$btnEdit.Add_Click({
    if (-not $list.SelectedItems.Count) { Say '先选中一条规则'; return }
    $e = $list.SelectedItems[0].Tag
    if (-not $e) { return }
    if (-not $e.Hostname) { Say '兜底规则不能修改'; return }

    $r = Show-EditDialog '修改转发规则' $e.Hostname (Get-PortOf $e.Service) (Get-NoteFirstLine $e.Note)
    if (-not $r) { return }
    try {
        $cfg = Read-Ingress $script:CfgPath
        $target = $cfg.Entries | Where-Object { $_.Hostname -eq $e.Hostname } | Select-Object -First 1
        if (-not $target) { Say '这条规则已经不在配置里了'; Load-Ingress; return }
        if ($r.Hostname -ne $e.Hostname -and ($cfg.Entries | Where-Object { $_.Hostname -eq $r.Hostname })) {
            [System.Windows.Forms.MessageBox]::Show('目标域名已存在。', '重复') | Out-Null
            return
        }
        $target.Hostname = $r.Hostname
        $target.Service = "http://127.0.0.1:$($r.Port)"
        $target.Note = $r.Note

        $saved = Save-IngressSafe $cfg -TargetPath $script:CfgPath
        if (-not $saved.Ok) {
            Say ("配置校验未通过，未写入：" + $saved.Message)
            [System.Windows.Forms.MessageBox]::Show("配置校验未通过，已放弃本次修改。`n`n" + $saved.Message, '未保存', 'OK', 'Warning') | Out-Null
            return
        }
        Load-Ingress
        Refresh-Status
        Say "✅ 已修改 $($r.Hostname)"
    } catch {
        Say "修改失败: $($_.Exception.Message)"
    }
})

$btnDel.Add_Click({
    if (-not $list.SelectedItems.Count) { Say '先选中一条规则'; return }
    $e = $list.SelectedItems[0].Tag
    if (-not $e) { return }

    $isDisabled = [bool]($script:Disabled | Where-Object { $_.Hostname -eq $e.Hostname })
    if ($isDisabled) {
        # 已停用的规则：从旁挂文件里删掉
        $rest = @($script:Disabled | Where-Object { $_.Hostname -ne $e.Hostname })
        Write-Disabled $rest
        Refresh-Rules
        Say "🗑 已删除停用规则 $($e.Hostname)"
        return
    }

    if (-not $e.Hostname) { Say '兜底规则不能删除'; return }
    if ($e.Hostname -eq $script:PrimaryHost) {
        [System.Windows.Forms.MessageBox]::Show(
            "不能删除 $($script:PrimaryHost)。`n`n这是入口域名，守护进程靠探活它判断隧道是否健康。",
            '不允许', 'OK', 'Warning') | Out-Null
        return
    }
    $ans = [System.Windows.Forms.MessageBox]::Show("删除 $($e.Hostname) ？", '确认', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    try {
        $cfg = Read-Ingress $script:CfgPath
        $keep = New-Object System.Collections.Generic.List[object]
        foreach ($x in $cfg.Entries) { if ($x.Hostname -ne $e.Hostname) { $keep.Add($x) } }
        $cfg.Entries = $keep
        $saved = Save-IngressSafe $cfg -TargetPath $script:CfgPath
        if (-not $saved.Ok) { Say ("校验未通过，未删除：" + $saved.Message); return }
        Load-Ingress
        Say "🗑 已删除 $($e.Hostname)"
    } catch { Say "删除失败: $($_.Exception.Message)" }
})

$btnToggle.Add_Click({
    if (-not $list.SelectedItems.Count) { Say '先选中一条规则'; return }
    $e = $list.SelectedItems[0].Tag
    if (-not $e) { return }

    $isDisabled = [bool]($script:Disabled | Where-Object { $_.Hostname -eq $e.Hostname })

    if ($isDisabled) {
        # 启用：从旁挂移回 ingress，插到兜底之前
        try {
            $cfg = Read-Ingress $script:CfgPath
            if ($cfg.Entries | Where-Object { $_.Hostname -eq $e.Hostname }) { Say '这个域名已经在配置里了'; return }
            $new = [pscustomobject]@{ Hostname = $e.Hostname; Service = $e.Service; Note = $e.Note }
            $idx = -1
            for ($i = 0; $i -lt $cfg.Entries.Count; $i++) { if (-not $cfg.Entries[$i].Hostname) { $idx = $i; break } }
            if ($idx -ge 0) { $cfg.Entries.Insert($idx, $new) } else { $cfg.Entries.Add($new) }
            $saved = Save-IngressSafe $cfg -TargetPath $script:CfgPath
            if (-not $saved.Ok) { Say ("校验未通过，未启用：" + $saved.Message); return }
            Write-Disabled @($script:Disabled | Where-Object { $_.Hostname -ne $e.Hostname })
            Load-Ingress
            Say "▶ 已启用 $($e.Hostname)"
        } catch { Say "启用失败: $($_.Exception.Message)" }
        return
    }

    if (-not $e.Hostname) { Say '兜底规则不能停用'; return }
    if ($e.Hostname -eq $script:PrimaryHost) {
        [System.Windows.Forms.MessageBox]::Show(
            "不能停用 $($script:PrimaryHost)。`n`n这是入口域名，停用它会让探活失败，守护进程会反复重建并告警。",
            '不允许', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        $cfg = Read-Ingress $script:CfgPath
        $keep = New-Object System.Collections.Generic.List[object]
        foreach ($x in $cfg.Entries) { if ($x.Hostname -ne $e.Hostname) { $keep.Add($x) } }
        $cfg.Entries = $keep
        $saved = Save-IngressSafe $cfg -TargetPath $script:CfgPath
        if (-not $saved.Ok) { Say ("校验未通过，未停用：" + $saved.Message); return }
        $list2 = @($script:Disabled)
        $list2 += [pscustomobject]@{ Hostname = $e.Hostname; Service = $e.Service; Note = $e.Note }
        Write-Disabled $list2
        Load-Ingress
        Say "⏸ 已停用 $($e.Hostname)（域名与备注保留在 disabled-routes.json）"
    } catch { Say "停用失败: $($_.Exception.Message)" }
})

$btnStart.Add_Click({
    $task = $script:ProjectCfg.tasks.tunnel
    if (-not $task) { Say '配置里没有 tasks.tunnel'; return }
    try {
        Say "正在启动计划任务 $task…"
        Start-ScheduledTask -TaskName $task
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 500
            if (Get-CfProcess) { break }
        }
        Refresh-Status
        Say $(if (Get-CfProcess) { '✅ 隧道已启动' } else { '⚠️ 已触发任务，但 20 秒内没看到 cloudflared' })
    } catch { Say "启动失败: $($_.Exception.Message)" }
})

$btnStop.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "停止隧道会中断外网访问。`n`n继续吗？", '确认停止', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    $task = $script:ProjectCfg.tasks.tunnel
    try {
        Say '正在停止隧道…'
        if ($task) { Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue }
        # 守护循环本身也要停，否则会立刻把 cloudflared 拉回来
        Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*supervisor.js*' -and $_.CommandLine -notlike '*runner.js*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
        Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Refresh-Status
        Say $(if (Get-CfProcess) { '⚠️ cloudflared 仍在运行，可能被其它守护拉起了' } else { '⏹ 隧道已停止' })
    } catch { Say "停止失败: $($_.Exception.Message)" }
})

$btnRestart.Add_Click({
    try {
        Say '正在重启 cloudflared（守护会自动拉起）…'
        Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 12
        Refresh-Status
        Say $(if (Get-CfProcess) { '✅ 已重启' } else { '⚠️ 还没起来，看看日志' })
    } catch { Say "重启失败: $($_.Exception.Message)" }
})

$btnValidate.Add_Click({
    try {
        $out = & $script:CfExe tunnel --config $script:CfgPath ingress validate 2>&1 | Out-String
        Say $out
    } catch { Say "校验失败: $($_.Exception.Message)" }
})

$btnLog.Add_Click({
    if (-not (Test-Path $script:LogPath)) { Say "日志不存在：$($script:LogPath)"; return }
    $tail = Get-Content $script:LogPath -Encoding UTF8 -Tail 50 -ErrorAction SilentlyContinue
    Say ($tail -join "`n")
})

$btnLink.Add_Click({
    try {
        $keyFile = Join-Path (Split-Path $script:Root -Parent) 'proxy-login-key.txt'
        if (-not (Test-Path $keyFile)) { Say "找不到登录密钥：$keyFile"; return }
        $key = (Get-Content $keyFile -Raw -Encoding UTF8).Trim()
        $url = "https://$($script:PrimaryHost)/$($script:ProjectCfg.auth.loginPathSuffix)?key=$key"
        try { [System.Windows.Forms.Clipboard]::SetText($url) } catch { }
        Say ("登录链接（已复制到剪贴板）：`n" + $url)
    } catch { Say "读取登录链接失败: $($_.Exception.Message)" }
})

# ------------------------------------------------------------------ 启动
Load-Ingress
Refresh-Status
Layout-Form
$form.Add_Resize({ Layout-Form })

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$initW = [Math]::Min([Math]::Max([int]($wa.Width * 0.50), (S 640)), (S 1150))
$initH = [Math]::Min([Math]::Max([int]($wa.Height * 0.72), (S 520)), (S 900))
$form.Size = New-Object System.Drawing.Size($initW, $initH)
Layout-Form

$form.Add_Shown({
    Refresh-Status
    Say "已加载 $($script:Cfg.Entries.Count) 条规则（另有 $($script:Disabled.Count) 条已停用）`n域名：$($script:Zone)　隧道：$($script:TunnelName)"
})

[void]$form.ShowDialog()
