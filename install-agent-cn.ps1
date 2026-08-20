#Requires -Version 5.1
<#
Agent 安装 / 自动更新脚本 (国内源版本, 默认 -Source cn)
用法:
    powershell -ExecutionPolicy Bypass -File .\install-agent-cn.ps1
    powershell -ExecutionPolicy Bypass -File .\install-agent-cn.ps1 -InstallDir "C:\Agent"
    iex (irm http://114.80.36.225:15667/6/install-agent-cn.ps1)
全程无交互: 自动检测更新 -> 下载 -> 安装/替换。
默认从国内 dufs 下载, 失败时自动回退 GitHub。
#>

[CmdletBinding()]
param(
    [ValidateSet('auto','github','cn')]
    [string]$Source = 'cn',

    [string]$InstallDir = $(if ($env:CAM_INSTALL_DIR) { $env:CAM_INSTALL_DIR } else { "$env:ProgramData\CamAgents\camera" }),

    [string]$ServerIp = 'sx1.jc116.com',
    [int]$ServerPort = 9999,
    [string]$ServerPassword = '',
    [ValidateSet('tcp','tls')]
    [string]$ServerProtocol = $(if ($env:CAM_SERVER_PROTOCOL) { $env:CAM_SERVER_PROTOCOL } else { 'tcp' }),
    [string]$CertificateFingerprint = $(if ($env:CAM_SERVER_FINGERPRINT) { $env:CAM_SERVER_FINGERPRINT } else { '' }),

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
    if (-not $Verbose -and $Level -ne 'ERROR') { return }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
    Write-Host "[$ts][$Level] $Msg" -ForegroundColor $color
}

function Get-RemoteFile {
    # 默认 600s: 64MB 的 opencv_world4100.dll 在慢网络上常常超过 30s
    param([string]$Url,[string]$OutFile,[int]$TimeoutSec = 600)
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
        $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec).Content
        if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
        return [string]$content
    } catch {
        return $null
    }
}

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower()
}

# Update one INI key without replacing the file. This preserves InstanceId,
# migration rollback state and media settings while applying an endpoint
# explicitly supplied by the delivery website.
function Set-IniValuePreserve {
    param([string]$Path,[string]$Section,[string]$Key,[string]$Value)
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in (Get-Content -LiteralPath $Path)) { [void]$lines.Add([string]$line) }
    }
    $sectionStart = -1
    $sectionEnd = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[([^]]+)\]\s*$') {
            if ($sectionStart -ge 0) { $sectionEnd = $i; break }
            if ($Matches[1] -ieq $Section) { $sectionStart = $i }
        }
    }
    if ($sectionStart -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') { [void]$lines.Add('') }
        [void]$lines.Add("[$Section]")
        [void]$lines.Add("$Key=$Value")
    } else {
        $keyIndex = -1
        for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
            if ($lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) { $keyIndex = $i; break }
        }
        if ($keyIndex -ge 0) { $lines[$keyIndex] = "$Key=$Value" }
        else { $lines.Insert($sectionEnd, "$Key=$Value") }
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
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

# ---------- 蓝绿升级目标 ----------
$agentExe = Join-Path $InstallDir 'Agent.exe'
$installedMarker = Join-Path $InstallDir '.installed'
$svcName = 'RemoteCameraAgent'
$existingService = Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
$isFirstInstall = -not $existingService
$safeVersion = ([string]$manifest.version -replace '[^0-9A-Za-z._-]', '_')
$candidateExe = if ($isFirstInstall) { $agentExe } else { Join-Path $InstallDir "Agent-$safeVersion.exe" }
$oldServicePath = if ($existingService) { [string]$existingService.PathName } else { '' }
$needsHandover = (-not $isFirstInstall) -and ($localVersion -ne [string]$manifest.version -or
    $oldServicePath -notlike "*$candidateExe*")

# ---------- 下载 / 校验 ----------
$changed = $false
foreach ($f in $manifest.files) {
    $name = $f.name
    $remoteHash = if ($f.PSObject.Properties.Name -contains 'sha256') { $f.sha256 } else { $null }
    # Never overwrite a loaded image. Upgrades are staged side-by-side and
    # become active only after the candidate has authenticated successfully.
    $dst = if ($name -ieq 'Agent.exe') { $candidateExe } else { Join-Path $InstallDir $name }
    $localHash = Get-FileSha256 $dst

    # Only Agent.exe is release-critical. Keep local agent.ini and OpenCV DLL
    # as-is when present, and do not let line-ending/runtime-DLL hash drift
    # block installing/updating the service executable.
    $skipHash = (($name -ieq 'agent.ini') -or ($name -ieq 'opencv_world4100.dll'))
    if ($skipHash -and (Test-Path $dst)) {
        Write-Log "跳过配置/运行时文件 (本地已存在, 不校验): $name" 'WARN'
        continue
    }

    $needDownload = $false
    if (-not (Test-Path $dst)) {
        $needDownload = $true
    } elseif ($remoteHash -and -not $skipHash) {
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

    if ($remoteHash -and -not $skipHash) {
        $newHash = Get-FileSha256 $dst
        if ($newHash -ne $remoteHash.ToLower()) {
            Write-Log "$name 校验失败 期望=$remoteHash 实际=$newHash" 'ERROR'
            exit 2
        }
        Write-Log "$name 校验通过"
    } elseif ($skipHash) {
        Write-Log "配置/运行时文件已下载, 跳过 SHA 校验: $name" 'WARN'
    }
    $changed = $true
}

if (-not (Test-Path $candidateExe)) {
    Write-Log "候选 Agent 不存在, 安装失败: $candidateExe" 'ERROR'
    exit 3
}

# ---------- 首次安装 (Agent.exe -install 注册服务) ----------
# ---------- Write/repair Camera Agent server config ----------
$iniPath = Join-Path $InstallDir 'agent.ini'
$explicitServer = $isFirstInstall -or $PSBoundParameters.ContainsKey('ServerIp') -or
    $PSBoundParameters.ContainsKey('ServerPort') -or $PSBoundParameters.ContainsKey('ServerPassword') -or
    $PSBoundParameters.ContainsKey('ServerProtocol') -or $PSBoundParameters.ContainsKey('CertificateFingerprint') -or
    [bool]$env:AGENT_SERVER_IP -or [bool]$env:AGENT_SERVER_PORT -or
    ($null -ne $env:AGENT_SERVER_PASSWORD) -or [bool]$env:CAM_SERVER_PROTOCOL -or
    ($null -ne $env:CAM_SERVER_FINGERPRINT)
if (-not (Test-Path $iniPath)) {
    $h = if ($ServerIp) { $ServerIp } else { 'sx1.jc116.com' }
    $p = if ($ServerPort -gt 0) { $ServerPort } else { 9999 }
    $w = if ($ServerPassword) { $ServerPassword } else { '' }
    $transport = $ServerProtocol.ToLowerInvariant()
    $pin = ($CertificateFingerprint -replace '[^0-9a-fA-F]','').ToLowerInvariant()
    if ($transport -eq 'tls' -and $pin.Length -ne 64) { throw 'TLS requires CAM_SERVER_FINGERPRINT (64 hexadecimal SHA-256 characters)' }
    $iniContent = @"
; ================================================
; Remote Camera Agent - configuration file
; Changes take effect on next reconnect (no restart needed)
; ================================================

[Server]
; Server IP or hostname
Host=$h
; Server port (must match Server.exe setting)
Port=$p
; Connection password (must match Server.exe, leave empty for none)
Password=$w
Protocol=$transport
CertificateFingerprint=$pin
; Reconnect interval in seconds (min 3)
ReconnectSeconds=10

[Camera]
; Camera device index (0 = first/default camera)
Index=0
; JPEG quality 1-100  (100=best, still JPEG-compressed)
Quality=100
; Frames per second 1-120 (30 is the realtime default)
Fps=30
; Capture resolution
Width=1920
Height=1080

[QUIC]
Enabled=1
"@
    Set-Content -Path $iniPath -Value $iniContent -Encoding ASCII
    Write-Log "写入 agent.ini: Host=$h Port=$p" 'WARN'
}
if ($explicitServer) {
    $h = if ($ServerIp) { $ServerIp } else { 'sx1.jc116.com' }
    $p = if ($ServerPort -gt 0) { $ServerPort } else { 9999 }
    $w = if ($null -ne $ServerPassword) { $ServerPassword } else { '' }
    $transport = $ServerProtocol.ToLowerInvariant()
    $pin = ($CertificateFingerprint -replace '[^0-9a-fA-F]','').ToLowerInvariant()
    if ($transport -eq 'tls' -and $pin.Length -ne 64) { throw 'TLS requires CAM_SERVER_FINGERPRINT (64 hexadecimal SHA-256 characters)' }
    Set-IniValuePreserve $iniPath 'Server' 'Host' $h
    Set-IniValuePreserve $iniPath 'Server' 'Port' ([string]$p)
    Set-IniValuePreserve $iniPath 'Server' 'Password' $w
    Set-IniValuePreserve $iniPath 'Server' 'Protocol' $transport
    Set-IniValuePreserve $iniPath 'Server' 'CertificateFingerprint' $pin
    Write-Log "Applied endpoint to existing agent.ini: $transport $h`:$p (identity preserved)" 'WARN'
}
if ($env:CAM_DELIVERY_BASE) {
    Set-IniValuePreserve $iniPath 'Bootstrap' 'ConfigUrl' $env:CAM_DELIVERY_BASE.TrimEnd('/')
}
Set-IniValuePreserve $iniPath 'QUIC' 'Enabled' '1'

if ($isFirstInstall) {
    Write-Log "首次安装, 执行 Agent.exe -install"
    $installExit = -1
    try {
        $p = Start-Process -FilePath $agentExe -ArgumentList '-install' -WorkingDirectory $InstallDir -WindowStyle Hidden -PassThru -Wait
        $installExit = $p.ExitCode
    } catch {
        Write-Log "Agent.exe -install 启动失败: $($_.Exception.Message)" 'ERROR'
        exit 4
    }
    if ($installExit -ne 0) {
        Write-Log "Agent.exe -install 退出码=$installExit, 服务注册失败" 'ERROR'
        Write-Log "排查: 当前 shell 是否管理员/SYSTEM 权限? $InstallDir\opencv_world4100.dll 是否存在(应 64MB)?" 'ERROR'
        exit 4
    }
    # 注册成功才写标记 (失败时不写, 下次重跑可再次尝试 -install)
    Set-Content -Path $installedMarker -Value (Get-Date -Format 'o') -Encoding ASCII
}

# ---------- 新旧进程无感交接 ----------
function Wait-ReadyFile {
    param([string]$Path,[int]$TimeoutSeconds = 20)
    for ($i = 0; $i -lt ($TimeoutSeconds * 10); $i++) {
        if (Test-Path -LiteralPath $Path) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

if ($needsHandover) {
    $token = [Guid]::NewGuid().ToString('N')
    $candidateReady = Join-Path $InstallDir ".handover-candidate-$token.ready"
    $serviceReady = Join-Path $InstallDir ".handover-service-$token.ready"
    Remove-Item -LiteralPath $candidateReady,$serviceReady -Force -ErrorAction SilentlyContinue

    Write-Log "启动候选进程并等待 Server 接管同一 InstanceId" 'WARN'
    $candidate = Start-Process -FilePath $candidateExe `
        -ArgumentList @('-handover-once','-handover-ready',$candidateReady,'-run') `
        -WorkingDirectory $InstallDir -WindowStyle Hidden -PassThru
    if (-not (Wait-ReadyFile -Path $candidateReady)) {
        Stop-Process -Id $candidate.Id -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $candidateReady,$serviceReady -Force -ErrorAction SilentlyContinue
        Write-Log "Candidate did not receive Server handover confirmation. Old service is still running. Check Server >= 1.12, endpoint/protocol/port/password, and TLS fingerprint in $iniPath" 'ERROR'
        exit 5
    }

    $newServicePath = '"{0}" -handover-ready "{1}"' -f $candidateExe,$serviceReady
    & sc.exe config $svcName binPath= $newServicePath start= auto | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-Process -Id $candidate.Id -Force -ErrorAction SilentlyContinue
        Write-Log "无法切换服务路径，旧服务继续运行: $LASTEXITCODE" 'ERROR'
        exit 6
    }

    Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
    Start-Service -Name $svcName
    if (-not (Wait-ReadyFile -Path $serviceReady)) {
        Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        & sc.exe config $svcName binPath= $oldServicePath start= auto | Out-Null
        Start-Service -Name $svcName
        Stop-Process -Id $candidate.Id -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $candidateReady,$serviceReady -Force -ErrorAction SilentlyContinue
        Write-Log "New service did not authenticate; restored the old service path. Check endpoint and Server >= 1.12 in $iniPath" 'ERROR'
        exit 7
    }
    try { $candidate | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue } catch {}
    if (-not $candidate.HasExited) { Stop-Process -Id $candidate.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $candidateReady,$serviceReady -Force -ErrorAction SilentlyContinue
    Write-Log "无感交接完成: $candidateExe" 'WARN'
} elseif ($isFirstInstall) {
    Start-Service -Name $svcName
}

# ---------- 验证服务真在跑 ----------
$svc = $null
for ($i = 0; $i -lt 20; $i++) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { break }
    Start-Sleep -Milliseconds 500
}
if (-not $svc) {
    Write-Log "服务 $svcName 不存在, 注册可能被跳过. 试: Remove-Item '$installedMarker' -Force; 再重跑此脚本" 'ERROR'
    exit 6
}
if ($svc.Status -ne 'Running') {
    Write-Log "服务 $svcName 状态=$($svc.Status), 启动失败" 'ERROR'
    Write-Log "排查: Get-EventLog System -Source 'Service Control Manager' -Newest 10" 'ERROR'
    exit 7
}

# 身份与本地设置存放在原 INI 中；只有交接成功后才提交版本号。
Set-Content -Path $versionFile -Value $manifest.version -Encoding ASCII

if ($changed) {
    Write-Log "完成: 已更新到版本 $($manifest.version)"
} else {
    Write-Log "完成: 无需更新, 当前版本 $($manifest.version)"
}

# ---------- 最终成功提示 ----------
Write-Host ""
Write-Host "  Service $svcName : Running  " -ForegroundColor Green -BackgroundColor Black
Write-Host "  enjoy work  " -ForegroundColor Green -BackgroundColor Black
Write-Host ""
