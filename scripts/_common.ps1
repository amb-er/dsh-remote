<#
    公共辅助函数。被 scripts/ 下的其它脚本 dot-source 使用。

    之所以单独抽出来：三个脚本都要读 config.json、展开 ~、定位 node，
    复制三份迟早会不一致。
#>

# 控制台编码必须是 UTF-8：子进程（node）输出是 UTF-8，
# 而中文 Windows 的默认解码是 GBK，不设的话日志全是乱码。
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    $OutputEncoding = New-Object System.Text.UTF8Encoding $false
} catch { }

$script:ProjectRoot = Split-Path $PSScriptRoot -Parent

function Expand-HomePath([string]$p) {
    if (-not $p) { return $p }
    if ($p -eq '~') { return $env:USERPROFILE }
    if ($p.StartsWith('~/') -or $p.StartsWith('~\')) { return (Join-Path $env:USERPROFILE $p.Substring(2)) }
    return $p
}

<#
    读项目配置。
    PowerShell 5.1 的 Get-Content 默认按 ANSI 解码，必须先按 UTF-8 读进来
    再 TrimStart(BOM) —— 直接 ConvertFrom-Json 会因为 BOM 或中文报各种误导性错误。
#>
function Get-ProjectConfig {
    $path = Join-Path $script:ProjectRoot 'config.json'
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-Host "config.json 解析失败：$($_.Exception.Message)"
        return $null
    }
}

<#
    定位 node 可执行文件。
    优先用配置里的 runtime.nodePath，其次 PATH 里的 node。
#>
function Resolve-Node([object]$cfg) {
    if ($cfg -and $cfg.runtime -and $cfg.runtime.nodePath) {
        $p = Expand-HomePath $cfg.runtime.nodePath
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-NodeVersion([string]$nodePath) {
    try {
        $v = & $nodePath --version 2>&1 | Out-String
        return $v.Trim()
    } catch { return '' }
}

function Write-Step($mark, $text) {
    $color = switch ($mark) {
        'OK'   { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        default { 'Gray' }
    }
    $symbol = switch ($mark) {
        'OK'   { '[OK]  ' }
        'FAIL' { '[FAIL]' }
        'WARN' { '[WARN]' }
        default { '[···] ' }
    }
    Write-Host ($symbol + ' ' + $text) -ForegroundColor $color
}

function Add-LogLine([string]$logFile, [string]$text) {
    $line = (Get-Date -Format s) + '  ' + $text
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
}
