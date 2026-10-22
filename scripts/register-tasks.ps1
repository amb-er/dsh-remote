<#
    注册 / 注销 / 查看计划任务。

    为什么需要脚本而不是手点任务计划程序：
    一个任务有十几项设置（触发器、会话类型、多实例策略、电池策略、执行时限），
    手点很容易漏。而且漏掉的方式很隐蔽——比如以为配了「失败后重启」就万事大吉，
    实际上那个策略对正常退出的进程根本不生效，不报错，只是某天不工作了。

    **重要限制（脚本解决不了）**：
    这两个任务必须是「登录时触发 + 交互式会话」，因为源站（Electron 桌面应用）
    需要交互式桌面会话才能运行。所以：
        重启电脑后，如果没人登录桌面，隧道不会自己起来。
    这是架构决定的，不是配置错误。

    用法：
        powershell -File scripts/register-tasks.ps1              注册（会先确认）
        powershell -File scripts/register-tasks.ps1 -Status      查看
        powershell -File scripts/register-tasks.ps1 -Unregister  注销
        powershell -File scripts/register-tasks.ps1 -Yes         跳过确认
#>
param(
    [switch]$Unregister,
    [switch]$Status,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$cfg = Get-ProjectConfig
if (-not $cfg) {
    Write-Step 'FAIL' '找不到 config.json，先跑 scripts/install.ps1'
    exit 1
}

# 任务名优先取配置，没配就用中性默认值
$taskTunnel = if ($cfg.tasks -and $cfg.tasks.tunnel) { $cfg.tasks.tunnel } else { 'tunnel-supervisor' }
$taskProxy  = if ($cfg.tasks -and $cfg.tasks.proxy)  { $cfg.tasks.proxy }  else { 'tunnel-proxy' }

$loopScript = Join-Path $PSScriptRoot 'run-loop.ps1'

function Get-TaskSpec($name, $target) {
    [pscustomobject]@{
        Name   = $name
        Target = $target
        Args   = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$loopScript`" -Script `"$target`""
    }
}

$specs = @(
    (Get-TaskSpec $taskProxy  'src/proxy/server.js'),
    (Get-TaskSpec $taskTunnel 'src/tunnel/supervisor.js')
)

# ------------------------------------------------------------------ 查看状态
if ($Status) {
    Write-Host ''
    Write-Host '=== 计划任务状态 ===' -ForegroundColor Cyan
    Write-Host ''
    foreach ($s in $specs) {
        $t = Get-ScheduledTask -TaskName $s.Name -ErrorAction SilentlyContinue
        if (-not $t) {
            Write-Step 'WARN' "$($s.Name)：未注册"
            continue
        }
        $info = Get-ScheduledTaskInfo -TaskName $s.Name -ErrorAction SilentlyContinue
        Write-Step 'OK' "$($s.Name)：$($t.State)"
        Write-Host "        目标  : $($s.Target)" -ForegroundColor DarkGray
        if ($info) {
            Write-Host "        上次运行: $($info.LastRunTime)  结果: $($info.LastTaskResult)" -ForegroundColor DarkGray
        }
        $trig = $t.Triggers | Select-Object -First 1
        if ($trig) {
            Write-Host "        触发器  : $($trig.CimClass.CimClassName)" -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host '提醒：任务已注册 ≠ 正在运行。' -ForegroundColor Yellow
    Write-Host '      它们只在「用户登录」时触发；重启后没人登录桌面就不会启动。' -ForegroundColor Yellow
    exit 0
}

# ------------------------------------------------------------------ 注销
if ($Unregister) {
    Write-Host ''
    foreach ($s in $specs) {
        $t = Get-ScheduledTask -TaskName $s.Name -ErrorAction SilentlyContinue
        if (-not $t) { Write-Step 'INFO' "$($s.Name)：本来就不存在"; continue }
        Unregister-ScheduledTask -TaskName $s.Name -Confirm:$false
        Write-Step 'OK' "已注销 $($s.Name)"
    }
    Write-Host ''
    Write-Host '注意：注销任务不会停止已经在跑的后台进程。' -ForegroundColor Yellow
    Write-Host '      需要一并停掉的话，结束对应的 node 进程。' -ForegroundColor Yellow
    exit 0
}

# ------------------------------------------------------------------ 注册
Write-Host ''
Write-Host '=== 将注册以下计划任务 ===' -ForegroundColor Cyan
Write-Host ''
foreach ($s in $specs) {
    Write-Host "  任务名  : $($s.Name)" -ForegroundColor White
    Write-Host "  运行    : $($s.Target)" -ForegroundColor DarkGray
    Write-Host ''
}
Write-Host '触发器：用户登录时' -ForegroundColor DarkGray
Write-Host '会话  ：交互式（源站需要桌面会话，这是硬性要求）' -ForegroundColor DarkGray
Write-Host ''
Write-Host '⚠️  限制：重启后如果没人登录桌面，这些任务不会启动。' -ForegroundColor Yellow
Write-Host '    这是 Electron 桌面应用的固有限制，不是本脚本能绕过的。' -ForegroundColor Yellow
Write-Host ''

if (-not $Yes) {
    $ans = Read-Host '确认注册？输入 y 继续，其它任意键取消'
    if ($ans -notmatch '^[yY]') {
        Write-Host '已取消。'
        exit 0
    }
}

Write-Host ''
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)   # 0 = 不限时；守护进程本来就该一直跑

foreach ($s in $specs) {
    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $s.Args -WorkingDirectory $script:ProjectRoot
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        Register-ScheduledTask -TaskName $s.Name -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Write-Step 'OK' "已注册 $($s.Name)"
    } catch {
        Write-Step 'FAIL' "注册 $($s.Name) 失败：$($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host '完成。现在是「登录时自动启动」。' -ForegroundColor Green
Write-Host ''
Write-Host '可以立即手动触发一次验证：' -ForegroundColor Gray
Write-Host "  Start-ScheduledTask -TaskName '$taskProxy'" -ForegroundColor Gray
Write-Host "  Start-ScheduledTask -TaskName '$taskTunnel'" -ForegroundColor Gray
Write-Host '  powershell -File scripts/register-tasks.ps1 -Status' -ForegroundColor Gray
