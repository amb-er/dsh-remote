<#
    进程内循环包装器。

    为什么需要它：**计划任务的「失败后重启」对这类进程无效。**
    node 正常退出（哪怕退出码非 0）在计划任务看来不算失败，重启策略不会触发。
    实测过：任务挂了之后 LastTaskResult 一直是 0、State 一直是 Ready，
    重启策略从来没生效过。所以重启必须写在进程里。

    用法（由计划任务调用）：
        powershell -File scripts/run-loop.ps1 -Script src/proxy/server.js
        powershell -File scripts/run-loop.ps1 -Script src/tunnel/supervisor.js

    退出方式：Ctrl+C 或结束进程。
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Script,

    [int]$RestartDelaySeconds = 15,

    # 进程活过这么久才算"正常运行过"；否则视为启动即失败，退避加长。
    [int]$HealthyRunSeconds = 20,

    [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$cfg = Get-ProjectConfig
if (-not $cfg) {
    Write-Step 'FAIL' '找不到 config.json，先跑 scripts/install.ps1'
    exit 1
}

$node = Resolve-Node $cfg
if (-not $node) {
    Write-Step 'FAIL' '找不到 node。如果 node 不在 PATH 里，在 config.json 的 runtime.nodePath 指定绝对路径。'
    exit 1
}

$target = Join-Path $script:ProjectRoot $Script
if (-not (Test-Path $target)) {
    Write-Step 'FAIL' "找不到目标脚本：$target"
    exit 1
}

if (-not $LogFile) {
    $LogFile = Join-Path $script:ProjectRoot ('run-' + [System.IO.Path]::GetFileNameWithoutExtension($Script) + '.log')
}

Write-Step 'INFO' "循环守护启动：$Script"
Write-Step 'INFO' "node    : $node"
Write-Step 'INFO' "日志    : $LogFile"
Write-Step 'INFO' '按 Ctrl+C 退出'
Write-Host ''

$child = $null
$consecutiveFastExits = 0
$targetName = [System.IO.Path]::GetFileName($target)

function Stop-Child {
    if ($child -and -not $child.HasExited) {
        try { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# 只清理"目标脚本与本次相同"的孤儿，避免误杀别的 node 进程
function Find-OrphanNode {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$targetName*" }
}

$exitCode = 0

while ($true) {
    Add-LogLine $LogFile "启动 $Script"
    $startedAt = Get-Date

    # 必须用 -Wait：只用 WaitForExit() 在 -NoNewWindow 场景下会提前返回，
    # 循环误以为进程退出了就重复拉起——实测 7 秒内起了 3 个进程，
    # 而端口被第一个占着，后面两个立刻退出，日志开始疯狂滚动。
    try {
        $child = Start-Process -FilePath $node -ArgumentList "`"$target`"" -PassThru -NoNewWindow -Wait
        $exitCode = $child.ExitCode
    } catch {
        $exitCode = -1
        Add-LogLine $LogFile "启动失败：$($_.Exception.Message)"
    }

    $ranSeconds = [int]((Get-Date) - $startedAt).TotalSeconds

    # 跑得久说明是正常退出或偶发崩溃；跑得短说明大概率是配置/端口问题，
    # 这时候快速重试只会刷日志，不如退避。
    if ($ranSeconds -lt $HealthyRunSeconds) { $consecutiveFastExits++ } else { $consecutiveFastExits = 0 }

    $delay = $RestartDelaySeconds
    if ($consecutiveFastExits -gt 1) {
        $delay = [int][Math]::Min(300, $RestartDelaySeconds * [Math]::Pow(2, [Math]::Min($consecutiveFastExits - 1, 4)))
    }

    Add-LogLine $LogFile "$Script 退出 code=$exitCode（运行 ${ranSeconds}s，连续短命 $consecutiveFastExits 次），${delay} 秒后重启"

    if ($consecutiveFastExits -ge 3) {
        $orphans = @(Find-OrphanNode)
        if ($orphans.Count -gt 0) {
            Add-LogLine $LogFile "清理同目标孤儿进程 $($orphans.Count) 个"
            foreach ($o in $orphans) { Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue }
        }
    }

    Start-Sleep -Seconds $delay
}

Stop-Child
exit $exitCode
