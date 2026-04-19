#Requires -Version 5.1
<#
Agent 安装 / 自动更新脚本
用法:
    powershell -ExecutionPolicy Bypass -File .\install-agent.ps1
    powershell -ExecutionPolicy Bypass -File .\install-agent.ps1 -Source github
    powershell -ExecutionPolicy Bypass -File .\install-agent.ps1 -Source cn
    powershell -ExecutionPolicy Bypass -File .\install-agent.ps1 -InstallDir "C:\Agent"
全程无交互: 自动检测更新 -> 下载 -> 安装/替换。
#>

[CmdletBinding()]
param(
    [ValidateSet('auto','github','cn')]
    [string]$Source = 'auto',

    [string]$InstallDir = "$env:ProgramData\Agent",

    # GitHub 仓库 (用户需在 GitHub 创建并上传文件到 Releases/raw)
    [string]$GithubUser = 'abxian',
    [string]$GithubRepo = 'agent-dist',
    [string]$GithubBranch = 'main',

    # 国内源
    [string]$CnBase = 'http://114.80.36.225:15667/6',

    # 显示完整过程日志
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

# ---------- 基础工具 ----------
function Write-Log {
    param([string]$Msg,[string]$Level='INFO')
    # 静默模式: 只显示 WARN / ERROR
    if (-not $Verbose -and $Level -eq 'INFO') { return }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
    Write-Host "[$ts][$Level] $Msg" -ForegroundColor $color
}

function Get-RemoteFile {
    param([string]$Url,[string]$OutFile,[int]$TimeoutSec = 30)
    $tmp = "$OutFile.downloading"
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    try {
        Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec $TimeoutSec
        if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
        Move-Item $tmp $OutFile
        return $true
    } catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        Write-Log "下载失败 $Url : $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Get-RemoteString {
    param([string]$Url,[int]$TimeoutSec = 15)
    try {
        return (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec).Content
    } catch {
        return $null
    }
}

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower()
}

function Test-SourceReachable {
    param([string]$Url)
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Method = 'HEAD'; $req.Timeout = 4000
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch { return $false }
}

# ---------- 选择源 ----------
$githubRaw = "https://raw.githubusercontent.com/$GithubUser/$GithubRepo/$GithubBranch"
$sources = @{
    github = $githubRaw
    cn     = $CnBase
}

function Resolve-Source {
    param([string]$Preferred)
    if ($Preferred -ne 'auto') { return $Preferred }
    Write-Log "自动检测最佳源..."
    if (Test-SourceReachable "$githubRaw/version.json") { return 'github' }
    if (Test-SourceReachable "$CnBase/version.json")    { return 'cn' }
    # 都无清单时 fallback 到 cn (原始链接)
    return 'cn'
}

$chosen = Resolve-Source -Preferred $Source
$base = $sources[$chosen]
Write-Log "使用源: $chosen ($base)"

# ---------- 获取版本清单 ----------
# version.json 格式:
# { "version":"1.0.0",
#   "files":[
#     {"name":"Agent.exe","sha256":"..."},
#     {"name":"agent.ini","sha256":"..."},
#     {"name":"opencv_world4100.dll","sha256":"..."}
#   ]
# }
$manifestUrl = "$base/version.json"
$manifestRaw = Get-RemoteString $manifestUrl

$defaultFiles = @('Agent.exe','agent.ini','opencv_world4100.dll')
$manifest = $null
if ($manifestRaw) {
    try { $manifest = $manifestRaw | ConvertFrom-Json } catch { $manifest = $null }
}

if (-not $manifest) {
    Write-Log "未获取到 version.json, 回退为强制下载模式" 'WARN'
    $manifest = [pscustomobject]@{
        version = (Get-Date -Format 'yyyyMMddHHmm')
        files   = $defaultFiles | ForEach-Object { [pscustomobject]@{ name = $_; sha256 = $null } }
    }
}

# ---------- 准备目录 ----------
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
$versionFile = Join-Path $InstallDir 'installed.version'
$localVersion = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '' }

Write-Log "本地版本: '$localVersion'  远端版本: '$($manifest.version)'"

# ---------- 停止正在运行的 Agent (优雅 -stop, 兜底 Stop-Process) ----------
$agentExe = Join-Path $InstallDir 'Agent.exe'
$installedMarker = Join-Path $InstallDir '.installed'
$isFirstInstall = -not (Test-Path $installedMarker)

if (Test-Path $agentExe) {
    try {
        Write-Log "执行 Agent.exe -stop"
        $p = Start-Process -FilePath $agentExe -ArgumentList '-stop' -WorkingDirectory $InstallDir -WindowStyle Hidden -PassThru
        $p | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    } catch {}
}
# 兜底: 强杀残留进程, 释放文件占用
Get-Process -Name 'Agent' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        if ($_.Path -and (Split-Path $_.Path -Parent) -eq $InstallDir) {
            Write-Log "强制结束残留 Agent.exe (PID=$($_.Id))"
            $_ | Stop-Process -Force
        }
    } catch {}
}
Start-Sleep -Milliseconds 500

# ---------- 下载 / 校验 ----------
$changed = $false
foreach ($f in $manifest.files) {
    $name = $f.name
    $remoteHash = if ($f.PSObject.Properties.Name -contains 'sha256') { $f.sha256 } else { $null }
    $dst = Join-Path $InstallDir $name
    $localHash = Get-FileSha256 $dst

    $needDownload = $false
    if (-not (Test-Path $dst)) {
        $needDownload = $true
    } elseif ($remoteHash) {
        if ($localHash -ne $remoteHash.ToLower()) { $needDownload = $true }
    } elseif ($localVersion -ne $manifest.version) {
        # 无 hash 信息, 用版本号驱动
        $needDownload = $true
    }

    if (-not $needDownload) {
        Write-Log "跳过 (已是最新): $name"
        continue
    }

    $url = "$base/$name"
    Write-Log "下载: $url"
    $ok = Get-RemoteFile -Url $url -OutFile $dst
    if (-not $ok) {
        # 源切换重试
        $other = if ($chosen -eq 'github') { 'cn' } else { 'github' }
        $otherBase = $sources[$other]
        $altUrl = "$otherBase/$name"
        Write-Log "尝试备用源: $altUrl" 'WARN'
        $ok = Get-RemoteFile -Url $altUrl -OutFile $dst
    }
    if (-not $ok) {
        Write-Log "无法下载 $name" 'ERROR'
        exit 1
    }

    if ($remoteHash) {
        $newHash = Get-FileSha256 $dst
        if ($newHash -ne $remoteHash.ToLower()) {
            Write-Log "$name 校验失败 期望=$remoteHash 实际=$newHash" 'ERROR'
            exit 2
        }
        Write-Log "$name 校验通过"
    }
    $changed = $true
}

# ---------- 写入版本 ----------
Set-Content -Path $versionFile -Value $manifest.version -Encoding ASCII

if (-not (Test-Path $agentExe)) {
    Write-Log "Agent.exe 不存在, 安装失败" 'ERROR'
    exit 3
}

# ---------- 首次安装 (Agent.exe -install 注册服务) ----------
if ($isFirstInstall) {
    Write-Log "首次安装, 执行 Agent.exe -install"
    try {
        $p = Start-Process -FilePath $agentExe -ArgumentList '-install' -WorkingDirectory $InstallDir -WindowStyle Hidden -PassThru -Wait
        if ($p.ExitCode -ne 0) {
            Write-Log "Agent.exe -install 退出码=$($p.ExitCode)" 'WARN'
        }
    } catch {
        Write-Log "Agent.exe -install 失败: $($_.Exception.Message)" 'ERROR'
        exit 4
    }
    Set-Content -Path $installedMarker -Value (Get-Date -Format 'o') -Encoding ASCII
}

# ---------- 启动 (Agent.exe -start) ----------
Write-Log "启动 Agent.exe -start"
try {
    Start-Process -FilePath $agentExe -ArgumentList '-start' -WorkingDirectory $InstallDir -WindowStyle Hidden
} catch {
    Write-Log "Agent.exe -start 失败: $($_.Exception.Message)" 'ERROR'
    exit 5
}

if ($changed) {
    Write-Log "完成: 已更新到版本 $($manifest.version)"
} else {
    Write-Log "完成: 无需更新, 当前版本 $($manifest.version)"
}

# ---------- 最终成功提示 ----------
Write-Host ""
Write-Host "  enjoy work  " -ForegroundColor Green -BackgroundColor Black
Write-Host ""
