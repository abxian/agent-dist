#Requires -Version 5.1
<#
ScreenAgent 安装 / 自动更新脚本 (国内源版本, 默认 -Source cn)
用法:
    powershell -ExecutionPolicy Bypass -File .\install-screenagent-cn.ps1
    powershell -ExecutionPolicy Bypass -File .\install-screenagent-cn.ps1 -InstallDir "C:\ScreenAgent"
    powershell -ExecutionPolicy Bypass -File .\install-screenagent-cn.ps1 -ServerIp 192.168.1.100 -ServerPort 9999
    iex (irm http://114.80.36.225:15667/6/install-screenagent-cn.ps1)
全程无交互: 自动检测更新 -> 下载 -> 安装/替换。
默认从国内 dufs 下载, 失败时自动回退 GitHub。
与 install-agent-cn.ps1 独立,装在单独的目录、单独的服务,与混合版 Agent 互不干扰。
#>

[CmdletBinding()]
param(
    [ValidateSet('auto','github','cn')]
    [string]$Source = 'cn',

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
    if (-not $Verbose -and $Level -ne 'ERROR') { return }
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
    if (Test-SourceReachable "$CnBase/$ManifestName")    { return 'cn' }
    if (Test-SourceReachable "$githubRaw/$ManifestName") { return 'github' }
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
# 注意: ScreenAgent 必须以登录用户身份跑在 user session (抓屏 GDI 需要桌面),
# 所以这里用计划任务 ONLOGON 而不是 Windows 服务 (服务在 Session 0 抓不到屏).
$agentExe = Join-Path $InstallDir 'ScreenAgent.exe'
$installedMarker = Join-Path $InstallDir '.installed'
$isFirstInstall = -not (Test-Path $installedMarker)
$TaskName = 'ScreenAgent'

# 清理老的服务安装(如果存在,从旧版脚本迁移过来)
$svc = Get-Service -Name 'RemoteScreenAgent' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Log "发现旧的 Windows 服务, 正在清理 (迁移到计划任务模式)"
    try { sc.exe stop   RemoteScreenAgent | Out-Null } catch {}
    Start-Sleep -Seconds 1
    try { sc.exe delete RemoteScreenAgent | Out-Null } catch {}
}

# 停掉计划任务 + 强杀进程(升级时需要释放 exe 占用)
try { schtasks /End /TN $TaskName 2>$null | Out-Null } catch {}
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
# 保留本地 screenagent.ini (用户可能改过 Server 地址)
$hasLocalIni = Test-Path (Join-Path $InstallDir 'screenagent.ini')

$changed = $false
foreach ($f in $manifest.files) {
    $name = $f.name
    $remoteHash = if ($f.PSObject.Properties.Name -contains 'sha256') { $f.sha256 } else { $null }
    $dst = Join-Path $InstallDir $name
    $localHash = Get-FileSha256 $dst

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

# ---------- 若带了 Server 参数: 写入 screenagent.ini (首次安装 OR ini 不存在才覆盖) ──
$iniPath = Join-Path $InstallDir 'screenagent.ini'
if (($isFirstInstall -or -not $hasLocalIni) -and ($ServerIp -or $ServerPort -gt 0 -or $ServerPassword)) {
    $h = if ($ServerIp)            { $ServerIp }      else { '110.42.44.89' }
    $p = if ($ServerPort -gt 0)    { $ServerPort }    else { 9999 }
    $w = if ($ServerPassword)      { $ServerPassword} else { '' }
    $iniContent = @"
[Server]
Host=$h
Port=$p
Password=$w
ReconnectSeconds=10

[Screen]
; JPEG quality 1-100 (higher = clearer but more bandwidth)
Quality=70
"@
    Set-Content -Path $iniPath -Value $iniContent -Encoding ASCII
    Write-Log "写入 screenagent.ini: Host=$h Port=$p"
}

# ---------- 注册/更新计划任务 (ONLOGON, 以登录用户身份运行) ────────────────
# 要求: 需要管理员权限调 schtasks
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Log "需要管理员权限 (schtasks 注册任务). 请以管理员身份运行 PowerShell 后重试." 'ERROR'
    exit 4
}

# /F 覆盖已有同名任务; /RU INTERACTIVE = 以当前登录用户身份跑; /RL LIMITED = 普通权限
$tr = "`"$agentExe`" -run"
$schOut = schtasks /Create /F /TN $TaskName /SC ONLOGON /RU INTERACTIVE /RL LIMITED /TR $tr 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "schtasks 注册失败: $schOut" 'ERROR'
    exit 4
}

if ($isFirstInstall) {
    Set-Content -Path $installedMarker -Value (Get-Date -Format 'o') -Encoding ASCII
}

# ---------- 启动 ----------
# 当前脚本跑在管理员 PowerShell 里, 也就是用户 session, 直接 Start-Process 即可.
# 这样就不用等下次登录, 本次立即可用.
try {
    Start-Process -FilePath $agentExe -ArgumentList '-run' -WorkingDirectory $InstallDir -WindowStyle Hidden
} catch {
    Write-Log "ScreenAgent.exe -run 启动失败: $($_.Exception.Message)" 'ERROR'
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
