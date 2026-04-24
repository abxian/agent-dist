#Requires -Version 5.1
<#
ScreenAgent 安装 / 自动更新脚本
用法:
    powershell -ExecutionPolicy Bypass -File .\install-screenagent.ps1
    powershell -ExecutionPolicy Bypass -File .\install-screenagent.ps1 -Source github
    powershell -ExecutionPolicy Bypass -File .\install-screenagent.ps1 -Source cn
    powershell -ExecutionPolicy Bypass -File .\install-screenagent.ps1 -InstallDir "C:\ScreenAgent"
    powershell -ExecutionPolicy Bypass -File .\install-screenagent.ps1 -ServerIp 192.168.1.100 -ServerPort 9999
全程无交互: 自动检测更新 -> 下载 -> 安装/替换。
与 install-agent.ps1 独立,装在单独的目录、单独的服务,与混合版 Agent 互不干扰。
#>

[CmdletBinding()]
param(
    [ValidateSet('auto','github','cn')]
    [string]$Source = 'auto',

    [string]$InstallDir = "$env:ProgramData\ScreenAgent",

    # 首次安装时写入 screenagent.ini 的 Server 地址 (可选, 不填则用仓库里的默认 ini)
    [string]$ServerIp   = '',
    [int]   $ServerPort = 0,
    [string]$ServerPassword = '',

    # GitHub 仓库
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

# ── 下载用的清单文件名 (独立于 Agent 的 version.json) ───────────────────────
$ManifestName = 'version-screen.json'

# ---------- 基础工具 ----------
function Write-Log {
    param([string]$Msg,[string]$Level='INFO')
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
    if (Test-SourceReachable "$githubRaw/$ManifestName") { return 'github' }
    if (Test-SourceReachable "$CnBase/$ManifestName")    { return 'cn' }
    return 'cn'
}

$chosen = Resolve-Source -Preferred $Source
$base = $sources[$chosen]
Write-Log "使用源: $chosen ($base)"

# ---------- 获取版本清单 ----------
$manifestUrl = "$base/$ManifestName"
$manifestRaw = Get-RemoteString $manifestUrl

$defaultFiles = @('ScreenAgent.exe','screenagent.ini','opencv_world4100.dll')
$manifest = $null
if ($manifestRaw) {
    try { $manifest = $manifestRaw | ConvertFrom-Json } catch { $manifest = $null }
}

if (-not $manifest) {
    Write-Log "未获取到 $ManifestName, 回退为强制下载模式" 'WARN'
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

# ---------- 停止正在运行的 ScreenAgent ----------
$agentExe = Join-Path $InstallDir 'ScreenAgent.exe'
$installedMarker = Join-Path $InstallDir '.installed'
$isFirstInstall = -not (Test-Path $installedMarker)

if (Test-Path $agentExe) {
    try {
        Write-Log "执行 ScreenAgent.exe -stop"
        $p = Start-Process -FilePath $agentExe -ArgumentList '-stop' -WorkingDirectory $InstallDir -WindowStyle Hidden -PassThru
        $p | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    } catch {}
}
# 兜底: 强杀残留
Get-Process -Name 'ScreenAgent' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        if ($_.Path -and (Split-Path $_.Path -Parent) -eq $InstallDir) {
            Write-Log "强制结束残留 ScreenAgent.exe (PID=$($_.Id))"
            $_ | Stop-Process -Force
        }
    } catch {}
}
Start-Sleep -Milliseconds 500

# ---------- 下载 / 校验 ----------
# 注意: 如果本地 screenagent.ini 用户已经改过,下载的新 ini 会覆盖它。
# 因此如果已存在 screenagent.ini, 跳过 ini 的下载 (保留本地配置)。
$hasLocalIni = Test-Path (Join-Path $InstallDir 'screenagent.ini')

$changed = $false
foreach ($f in $manifest.files) {
    $name = $f.name
    $remoteHash = if ($f.PSObject.Properties.Name -contains 'sha256') { $f.sha256 } else { $null }
    $dst = Join-Path $InstallDir $name
    $localHash = Get-FileSha256 $dst

    # 保留用户已改的 ini
    if ($name -eq 'screenagent.ini' -and $hasLocalIni) {
        Write-Log "保留本地配置: screenagent.ini"
        continue
    }

    $needDownload = $false
    if (-not (Test-Path $dst)) {
        $needDownload = $true
    } elseif ($remoteHash) {
        if ($localHash -ne $remoteHash.ToLower()) { $needDownload = $true }
    } elseif ($localVersion -ne $manifest.version) {
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
    Write-Log "ScreenAgent.exe 不存在, 安装失败" 'ERROR'
    exit 3
}

# ---------- 首次安装: 注册服务,可带 [ip] [port] [pwd] ────────────────────────
if ($isFirstInstall) {
    $installArgs = @('-install')
    if ($ServerIp)   { $installArgs += $ServerIp }
    if ($ServerPort -gt 0) {
        if (-not $ServerIp) { $installArgs += '192.168.1.100' }  # 占位
        $installArgs += "$ServerPort"
    }
    if ($ServerPassword) {
        if (-not $ServerIp)     { $installArgs += '192.168.1.100' }
        if ($ServerPort -le 0)  { $installArgs += '9999' }
        $installArgs += $ServerPassword
    }

    Write-Log "首次安装, 执行 ScreenAgent.exe $($installArgs -join ' ')"
    try {
        $p = Start-Process -FilePath $agentExe -ArgumentList $installArgs -WorkingDirectory $InstallDir -WindowStyle Hidden -PassThru -Wait
        if ($p.ExitCode -ne 0) {
            Write-Log "ScreenAgent.exe -install 退出码=$($p.ExitCode)" 'WARN'
        }
    } catch {
        Write-Log "ScreenAgent.exe -install 失败: $($_.Exception.Message)" 'ERROR'
        exit 4
    }
    Set-Content -Path $installedMarker -Value (Get-Date -Format 'o') -Encoding ASCII
}

# ---------- 启动 ----------
Write-Log "启动 ScreenAgent.exe -start"
try {
    Start-Process -FilePath $agentExe -ArgumentList '-start' -WorkingDirectory $InstallDir -WindowStyle Hidden
} catch {
    Write-Log "ScreenAgent.exe -start 失败: $($_.Exception.Message)" 'ERROR'
    exit 5
}

if ($changed) {
    Write-Log "完成: 已更新到版本 $($manifest.version)"
} else {
    Write-Log "完成: 无需更新, 当前版本 $($manifest.version)"
}

Write-Host ""
Write-Host "  ScreenAgent ready  " -ForegroundColor Green -BackgroundColor Black
Write-Host ""
