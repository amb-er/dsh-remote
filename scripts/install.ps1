<#
    环境检查与试跑。

    **这个脚本只检查，不改任何东西。** 唯一会写的动作是：
    当 config.json 不存在时，从 config.example.json 复制一份（并提示你务必修改）。
    隧道创建、ingress 编辑、计划任务注册都留给对应脚本或你自己操作——
    这些影响面大，不该由一个"检查脚本"悄悄做掉。

    用法：
        powershell -File scripts/install.ps1
        powershell -File scripts/install.ps1 -SkipTrialRun
#>
param(
    [switch]$SkipTrialRun
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_common.ps1')

$failures = 0
$warnings = 0

Write-Host ''
Write-Host '=== 环境检查 ===' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- 1. config.json
$cfgPath = Join-Path $script:ProjectRoot 'config.json'
$examplePath = Join-Path $script:ProjectRoot 'config.example.json'

if (-not (Test-Path $cfgPath)) {
    if (Test-Path $examplePath) {
        Copy-Item $examplePath $cfgPath
        Write-Step 'WARN' 'config.json 不存在，已从 config.example.json 复制'
        Write-Host '        请先编辑它，至少填写：' -ForegroundColor Yellow
        Write-Host '          domain / tunnel.name / tunnel.cloudflaredPath / origin.launcher' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '填好后重新运行本脚本。' -ForegroundColor Yellow
        exit 1
    }
    Write-Step 'FAIL' '找不到 config.json 和 config.example.json'
    exit 1
}

$cfg = Get-ProjectConfig
if (-not $cfg) {
    Write-Step 'FAIL' 'config.json 解析失败（检查 JSON 格式）'
    exit 1
}
Write-Step 'OK' 'config.json 可解析'

# ---------------------------------------------------------------- 2. 必填项
$required = @(
    @{ Path = 'domain';                    Desc = '域名' },
    @{ Path = 'tunnel.name';               Desc = '隧道名' },
    @{ Path = 'tunnel.cloudflaredPath';    Desc = 'cloudflared 路径' },
    @{ Path = 'tunnel.configPath';         Desc = '隧道配置文件路径' }
)
foreach ($r in $required) {
    $parts = $r.Path -split '\.'
    $cur = $cfg
    $ok = $true
    foreach ($k in $parts) {
        if ($null -eq $cur -or -not ($cur.PSObject.Properties.Name -contains $k)) { $ok = $false; break }
        $cur = $cur.$k
    }
    if (-not $ok -or [string]::IsNullOrWhiteSpace([string]$cur)) {
        Write-Step 'FAIL' "配置缺少 $($r.Path)（$($r.Desc)）"
        $failures++
    }
}
if ($failures -eq 0) { Write-Step 'OK' '必填项齐全' }

# ---------------------------------------------------------------- 3. Node 版本
$node = Resolve-Node $cfg
if (-not $node) {
    Write-Step 'FAIL' '找不到 node。装 Node.js 22+，或在 config.json 的 runtime.nodePath 指定绝对路径'
    $failures++
} else {
    $ver = Get-NodeVersion $node
    $major = 0
    $m = [regex]::Match($ver, 'v(\d+)\.')
    if ($m.Success) { $major = [int]$m.Groups[1].Value }
    if ($major -ge 22) {
        Write-Step 'OK' "node $ver（$node）"
    } else {
        Write-Step 'FAIL' "node 版本过低：$ver，需要 22+（报表模块用了 zlib.zstdDecompress）"
        $failures++
    }
}

# ---------------------------------------------------------------- 4. cloudflared
$cf = Expand-HomePath $cfg.tunnel.cloudflaredPath
if (-not $cf) {
    $failures++
} elseif (-not (Test-Path $cf)) {
    Write-Step 'FAIL' "找不到 cloudflared：$cf"
    Write-Host '        winget install --id Cloudflare.cloudflared' -ForegroundColor Gray
    $failures++
} else {
    Write-Step 'OK' "cloudflared 存在：$cf"

    # 关键检查：cloudflared 不能放在项目目录里。
    # DSH 的文件沙箱会限制"二进制在工作区内"的子进程，导致登录写证书时报 Access is denied。
    $cfFull = [System.IO.Path]::GetFullPath($cf)
    $rootFull = [System.IO.Path]::GetFullPath($script:ProjectRoot)
    if ($cfFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Step 'FAIL' 'cloudflared 不能放在项目目录里（沙箱会拦住它写凭据，见 docs/pitfalls.md 第 1 条）'
        $failures++
    }
}

# ---------------------------------------------------------------- 5. 隧道配置
$tunCfg = Expand-HomePath $cfg.tunnel.configPath
if (-not $tunCfg) {
    $failures++
} elseif (-not (Test-Path $tunCfg)) {
    Write-Step 'FAIL' "找不到隧道配置：$tunCfg"
    Write-Host '        需要先创建隧道并写好 ingress，见 README「快速开始」第 2、5 步' -ForegroundColor Gray
    $failures++
} else {
    Write-Step 'OK' "隧道配置存在：$tunCfg"
    $ingress = & $cf tunnel --config $tunCfg ingress validate 2>&1 | Out-String
    if ($ingress -match 'OK') {
        Write-Step 'OK' 'ingress 校验通过'
    } else {
        Write-Step 'FAIL' 'ingress 校验未通过：'
        Write-Host ($ingress.Trim() -split "`n" | Select-Object -First 5 | ForEach-Object { '        ' + $_ }) -ForegroundColor Gray
        $failures++
    }
}

# ---------------------------------------------------------------- 6. 会话密钥
$secretFile = Expand-HomePath $cfg.auth.secretFile
if (-not $secretFile) {
    $failures++
} elseif (-not (Test-Path $secretFile)) {
    Write-Step 'WARN' "找不到会话密钥文件：$secretFile（源站首次运行后才会生成）"
    $warnings++
} else {
    $probe = Join-Path $env:TEMP ('secret-probe-' + [guid]::NewGuid().ToString('N') + '.js')
    $js = "try{const m=require(" + [char]34 + (Join-Path $script:ProjectRoot 'src/proxy/auth/session-cookie.js').Replace('\','/') + [char]34 + ");const k=m.secretKey();console.log('LEN='+k.length)}catch(e){console.log('ERR='+e.message)}"
    [System.IO.File]::WriteAllText($probe, $js, (New-Object System.Text.UTF8Encoding $false))
    $out = & $node $probe 2>&1 | Out-String
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
    if ($out -match 'LEN=32') {
        Write-Step 'OK' '会话密钥可读（32 字节）'
    } else {
        Write-Step 'FAIL' '读不出会话密钥：' + $out.Trim()
        Write-Host '        检查 config.json 的 auth.secretFile / auth.secretRecord' -ForegroundColor Gray
        $failures++
    }
}

# ---------------------------------------------------------------- 7. 源站进程
$procName = $cfg.origin.desktopProcess
if ($procName) {
    $p = Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($procName)) -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) {
        Write-Step 'OK' "源站正在运行（pid $($p.Id)）"
    } else {
        Write-Step 'WARN' "没有检测到源站进程 $procName（不致命：代理会转发到它，需要它开着）"
        $warnings++
    }
}

$launcher = Expand-HomePath $cfg.origin.launcher
if ($launcher -and -not (Test-Path $launcher)) {
    Write-Step 'WARN' "origin.launcher 指向的文件不存在：$launcher（自动拉起会失效）"
    $warnings++
}

# ---------------------------------------------------------------- 汇总
Write-Host ''
if ($failures -gt 0) {
    Write-Host "检查未通过：$failures 项必须修复，$warnings 项警告。" -ForegroundColor Red
    exit 1
}

if ($SkipTrialRun) {
    Write-Host "检查通过（$warnings 项警告）。已跳过试跑。" -ForegroundColor Green
    Write-Host ''
    Write-Host '下一步：powershell -File scripts/register-tasks.ps1' -ForegroundColor Cyan
    exit 0
}

# ---------------------------------------------------------------- 试跑
Write-Host '=== 试跑代理 ===' -ForegroundColor Cyan
Write-Host ''

$port = [int]$cfg.proxy.listenPort
$serverJs = Join-Path $script:ProjectRoot 'src/proxy/server.js'
$outLog = Join-Path $env:TEMP ('trial-' + [guid]::NewGuid().ToString('N') + '.out')
$errLog = Join-Path $env:TEMP ('trial-' + [guid]::NewGuid().ToString('N') + '.err')

$trial = Start-Process -FilePath $node -ArgumentList "`"$serverJs`"" -PassThru -NoNewWindow `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog

Start-Sleep -Seconds 4
try {
    if ($trial.HasExited) {
        Write-Step 'FAIL' "代理启动后立即退出（code=$($trial.ExitCode)）"
        $err = Get-Content $errLog -ErrorAction SilentlyContinue | Select-Object -First 5
        if ($err) { $err | ForEach-Object { Write-Host ('        ' + $_) -ForegroundColor Gray } }
        $failures++
    } else {
        # 打登录路由，期望 303（签发 cookie）
        $keyFile = Join-Path $script:ProjectRoot 'proxy-login-key.txt'
        $key = ''
        if (Test-Path $keyFile) { $key = (Get-Content $keyFile -Raw -Encoding UTF8).Trim() }

        if (-not $key) {
            Write-Step 'WARN' '还没生成登录密钥（首次启动会生成），试跑到此为止'
            $warnings++
        } else {
            $url = "http://127.0.0.1:$port/$($cfg.auth.loginPathSuffix)?key=$key"
            $status = 'n/a'
            try {
                $resp = Invoke-WebRequest -Uri $url -MaximumRedirection 0 -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
                $status = [string]$resp.StatusCode
            } catch {
                $r = $_.Exception.Response
                if ($r) { $status = [string][int]$r.StatusCode }
            }
            if ($status -eq '303' -or $status -eq '200') {
                Write-Step 'OK' "代理响应正常（登录路由 HTTP $status）"
            } else {
                Write-Step 'FAIL' "登录路由返回 $status（期望 303）"
                $failures++
            }
        }
    }
} finally {
    if (-not $trial.HasExited) { Stop-Process -Id $trial.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $outLog, $errLog -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "试跑未通过：$failures 项失败。" -ForegroundColor Red
    exit 1
}

Write-Host "全部通过（$warnings 项警告）。" -ForegroundColor Green
Write-Host ''
Write-Host '下一步：powershell -File scripts/register-tasks.ps1' -ForegroundColor Cyan
Write-Host ''
Write-Host '注意：注册的任务是「登录时触发」，因为源站需要交互式桌面会话。' -ForegroundColor Yellow
Write-Host '      这意味着重启电脑后如果没人登录桌面，隧道不会自己起来。' -ForegroundColor Yellow
exit 0
