#Requires -Version 5.1
<#
查看 Agent 安装与运行状态
用法:
    iex (irm http://114.80.36.225:15667/6/agent-status.ps1)
    powershell -ExecutionPolicy Bypass -File .\agent-status.ps1 -InstallDir D:\Agent
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramData\Agent",
    [string]$CnBase     = 'http://114.80.36.225:15667/6',
    [string]$GithubRaw  = 'https://raw.githubusercontent.com/abxian/agent-dist/main'
)
$ErrorActionPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Line { param($k,$v) "{0,-22} {1}" -f ($k+':'),$v }

Write-Host "==== Agent Status ====" -ForegroundColor Cyan
Write-Host (Line "安装目录" $InstallDir)
Write-Host (Line "目录存在" (Test-Path $InstallDir))

# 已安装版本
$verFile = Join-Path $InstallDir 'installed.version'
$localVer = if (Test-Path $verFile) { (Get-Content $verFile -Raw).Trim() } else { '<未安装>' }
Write-Host (Line "本地版本" $localVer)

# 远端版本
function Get-RemoteVer($url) {
    try {
        $j = (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json
        return $j.version
    } catch { return '<不可达>' }
}
$cnVer = Get-RemoteVer "$CnBase/version.json"
$ghVer = Get-RemoteVer "$GithubRaw/version.json"
Write-Host (Line "国内源版本" $cnVer)
Write-Host (Line "GitHub源版本" $ghVer)

$latest = @($cnVer,$ghVer) | Where-Object { $_ -ne '<不可达>' } | Select-Object -First 1
if ($latest -and $localVer -ne '<未安装>' -and $localVer -ne $latest) {
    Write-Host (Line "升级状态" "可升级 ($localVer -> $latest)") -ForegroundColor Yellow
} elseif ($localVer -eq '<未安装>') {
    Write-Host (Line "升级状态" "未安装") -ForegroundColor Yellow
} else {
    Write-Host (Line "升级状态" "已是最新") -ForegroundColor Green
}

# 文件清单
Write-Host ""
Write-Host "---- 已安装文件 ----" -ForegroundColor Cyan
$files = @('Agent.exe','agent.ini','opencv_world4100.dll')
foreach ($f in $files) {
    $p = Join-Path $InstallDir $f
    if (Test-Path $p) {
        $size = (Get-Item $p).Length
        $kb = [Math]::Round($size/1KB,1)
        $mtime = (Get-Item $p).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        Write-Host ("  {0,-25} {1,10} KB  {2}" -f $f,$kb,$mtime)
    } else {
        Write-Host ("  {0,-25} <缺失>" -f $f) -ForegroundColor Red
    }
}

# 进程
Write-Host ""
Write-Host "---- 运行状态 ----" -ForegroundColor Cyan
$procs = Get-Process -Name 'Agent' -ErrorAction SilentlyContinue
if ($procs) {
    foreach ($p in $procs) {
        $path = $p.Path
        $startTime = $p.StartTime.ToString('yyyy-MM-dd HH:mm:ss')
        $mem = [Math]::Round($p.WorkingSet64/1MB,1)
        $cpu = [Math]::Round($p.CPU,1)
        $sameDir = if ($path -and (Split-Path $path -Parent) -eq $InstallDir) { '本机安装' } else { '其它路径' }
        Write-Host ("  PID={0}  内存={1}MB  CPU={2}s  启动={3}  [{4}]" -f $p.Id,$mem,$cpu,$startTime,$sameDir) -ForegroundColor Green
        if ($path) { Write-Host ("    路径: {0}" -f $path) }
    }
} else {
    Write-Host "  Agent.exe 未运行" -ForegroundColor Red
}

# 计划任务 (开机自启)
$task = Get-ScheduledTask -TaskName 'AgentAutoUpdate' -ErrorAction SilentlyContinue
if ($task) {
    Write-Host ""
    Write-Host "---- 计划任务 ----" -ForegroundColor Cyan
    Write-Host (Line "AgentAutoUpdate" $task.State)
}
