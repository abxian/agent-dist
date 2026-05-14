<#
ScreenAgent SID 安装脚本 (国内源优先)

用途:
  给指定 Windows 用户 SID 写入 HKU\<SID>\Software\Microsoft\Windows\CurrentVersion\Run,
  让 ScreenAgent 在该用户下次登录时以用户 session 运行。

示例:
  1. 修改脚本顶部配置区里的 $TargetSID / $ServerIp / $ServerPort
  2. 直接执行:
       iex (irm http://114.80.36.225:15667/6/install-screenagent-sid-cn.ps1)

说明:
  - 适用于已授权管理的机房/实验室电脑。
  - SYSTEM 下不会写 S-1-5-18, 只写配置区里的用户 SID。
  - 给其他 SID 写入 Run 后不会立刻运行, 目标用户下次登录时启动。
#>

# ── 配置区: 直接替换这里, 然后用 iex (irm URL) 一键执行 ─────────────────────
$TargetSID = 'S-1-5-21-4156230380-561108038-141577317-500'
$ServerIp = '110.42.44.89'
$ServerPort = 9999
$ServerPassword = ''

$Source = 'cn'   # auto / github / cn
$InstallDir = "$env:ProgramData\ScreenAgent"
$GithubUser = 'abxian'
$GithubRepo = 'agent-dist'
$GithubBranch = 'main'
$CnBase = 'http://114.80.36.225:15667/6'
$RunNowIfSelf = $false
$ShowInfoLogs = $true

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol =
    [Net.SecurityProtocolType]::Tls12 -bor
    [Net.SecurityProtocolType]::Tls11 -bor
    [Net.SecurityProtocolType]::Tls

$ManifestName = 'version-screen.json'
$RunValueName = 'ScreenAgent'

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    if (-not $ShowInfoLogs -and $Level -eq 'INFO') { return }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host "[$ts][$Level] $Msg" -ForegroundColor $color
}

function Fail {
    param([string]$Msg, [int]$Code = 1)
    Write-Log $Msg 'ERROR'
    exit $Code
}

function Get-RemoteFile {
    param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 30)
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
    param([string]$Url, [int]$TimeoutSec = 15)
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
        $req.Method = 'HEAD'
        $req.Timeout = 4000
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch {
        return $false
    }
}

function Ensure-HkuDrive {
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
    }
}

function Mount-UserHiveIfNeeded {
    param([string]$Sid)

    Ensure-HkuDrive
    $hivePath = "HKU:\$Sid"
    if (Test-Path $hivePath) {
        return $false
    }

    $profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    if (-not (Test-Path $profileListPath)) {
        Fail "找不到该 SID 的 ProfileList: $profileListPath" 20
    }

    $profilePathRaw = (Get-ItemProperty $profileListPath).ProfileImagePath
    if (-not $profilePathRaw) {
        Fail "ProfileList 中没有 ProfileImagePath: $profileListPath" 21
    }

    $profilePath = [Environment]::ExpandEnvironmentVariables($profilePathRaw)
    $ntuser = Join-Path $profilePath 'NTUSER.DAT'
    if (-not (Test-Path $ntuser)) {
        Fail "找不到用户 hive: $ntuser" 22
    }

    Write-Log "临时加载用户 hive: $ntuser"
    $loadOut = & reg.exe load "HKU\$Sid" "$ntuser" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "reg load 失败: $loadOut" 23
    }

    return $true
}

function Unmount-UserHive {
    param([string]$Sid)
    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 800

    $tmp = Join-Path $env:TEMP "screenagent-reg-unload-$($Sid -replace '[^A-Za-z0-9-]', '_').txt"
    & reg.exe unload "HKU\$Sid" > $tmp 2>&1
    $code = $LASTEXITCODE
    $out = if (Test-Path $tmp) { Get-Content $tmp -Raw -ErrorAction SilentlyContinue } else { '' }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue

    if ($code -ne 0) {
        Write-Log "reg unload 失败但安装继续。通常是系统还占用 hive, 重启后会自然释放。SID=HKU\$Sid 输出=$out" 'WARN'
    }
}

function Write-UserRun {
    param(
        [string]$Sid,
        [string]$ValueName,
        [string]$Command
    )

    $mustUnload = Mount-UserHiveIfNeeded -Sid $Sid
    try {
        $runKey = "HKU:\$Sid\Software\Microsoft\Windows\CurrentVersion\Run"
        if (-not (Test-Path $runKey)) {
            New-Item -Path $runKey -Force | Out-Null
        }

        New-ItemProperty `
            -Path $runKey `
            -Name $ValueName `
            -Value $Command `
            -PropertyType String `
            -Force | Out-Null

        $got = (Get-ItemProperty -Path $runKey -Name $ValueName).$ValueName
        if ($got -ne $Command) {
            Fail "Run 写入后校验失败: 期望=$Command 实际=$got" 24
        }

        Write-Log "已写入 HKU\$Sid\...\Run\$ValueName = $Command" 'WARN'
    } finally {
        if ($mustUnload) {
            Unmount-UserHive -Sid $Sid
        }
    }
}

$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$meSID = $me.User.Value
$isSystem = ($meSID -eq 'S-1-5-18')
$principal = New-Object Security.Principal.WindowsPrincipal($me)
$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
$isSelf = ($TargetSID -eq $meSID)

if ($TargetSID -eq 'REPLACE_WITH_TARGET_USER_SID' -or $TargetSID -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') {
    Fail "请先替换脚本顶部 `$DefaultTargetSID, 或执行时传入 -TargetSID。当前值: $TargetSID" 9
}
if ($TargetSID -eq 'S-1-5-18') {
    Fail "拒绝写入 SYSTEM SID (S-1-5-18)。请传入真实登录用户 SID。" 10
}
if (-not $isSelf -and -not ($isAdmin -or $isSystem)) {
    Fail "给其他 SID 写入 Run 需要管理员或 SYSTEM 权限。当前 SID=$meSID" 11
}

$githubRaw = "https://raw.githubusercontent.com/$GithubUser/$GithubRepo/$GithubBranch"
$sources = @{
    github = $githubRaw
    cn = $CnBase
}

function Resolve-Source {
    param([string]$Preferred)
    if ($Preferred -ne 'auto') { return $Preferred }
    Write-Log "自动检测最佳源..."
    if (Test-SourceReachable "$CnBase/$ManifestName") { return 'cn' }
    if (Test-SourceReachable "$githubRaw/$ManifestName") { return 'github' }
    return 'cn'
}

$chosen = Resolve-Source -Preferred $Source
$base = $sources[$chosen]
Write-Log "使用源: $chosen ($base)" 'WARN'

$manifestUrl = "$base/$ManifestName"
$manifestRaw = Get-RemoteString $manifestUrl
$manifestRaw = if ($manifestRaw) { $manifestRaw.TrimStart([char]0xFEFF) } else { $manifestRaw }
$defaultFiles = @('ScreenAgent.exe', 'screenagent.ini', 'opencv_world4100.dll')
$manifest = $null
if ($manifestRaw) {
    try { $manifest = $manifestRaw | ConvertFrom-Json } catch { $manifest = $null }
}
if (-not $manifest) {
    Write-Log "未获取到 $ManifestName, 回退为强制下载模式" 'WARN'
    $manifest = [pscustomobject]@{
        version = (Get-Date -Format 'yyyyMMddHHmm')
        files = $defaultFiles | ForEach-Object {
            [pscustomobject]@{ name = $_; sha256 = $null }
        }
    }
}

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

$versionFile = Join-Path $InstallDir 'installed.version'
$localVersion = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '' }
$agentExe = Join-Path $InstallDir 'ScreenAgent.exe'
$installedMarker = Join-Path $InstallDir '.installed.sid'

Write-Log "安装目录: $InstallDir" 'WARN'
Write-Log "运行身份: $($me.Name) ($meSID), TargetSID=$TargetSID" 'WARN'
Write-Log "本地版本: '$localVersion'  远端版本: '$($manifest.version)'" 'WARN'

# 清理旧服务形态, 避免 ScreenAgent 同时跑在 Session 0 和用户 session。
$svc = Get-Service -Name 'RemoteScreenAgent' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Log "清理旧 Windows 服务 RemoteScreenAgent" 'WARN'
    try { & sc.exe stop RemoteScreenAgent | Out-Null } catch {}
    Start-Sleep -Seconds 1
    try { & sc.exe delete RemoteScreenAgent | Out-Null } catch {}
}
try { & schtasks.exe /End /TN ScreenAgent 2>$null | Out-Null } catch {}
try { & schtasks.exe /Delete /TN ScreenAgent /F 2>$null | Out-Null } catch {}
try {
    Remove-ItemProperty `
        -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name $RunValueName `
        -Force `
        -ErrorAction SilentlyContinue
} catch {}

Get-Process -Name 'ScreenAgent' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        if ($_.Path -and (Split-Path $_.Path -Parent) -eq $InstallDir) {
            Write-Log "结束残留 ScreenAgent.exe (PID=$($_.Id))" 'WARN'
            Stop-Process -Id $_.Id -Force
        }
    } catch {}
}
Start-Sleep -Milliseconds 500

$hasLocalIni = Test-Path (Join-Path $InstallDir 'screenagent.ini')
$changed = $false

foreach ($f in $manifest.files) {
    $name = $f.name
    $remoteHash = if ($f.PSObject.Properties.Name -contains 'sha256') { $f.sha256 } else { $null }
    $dst = Join-Path $InstallDir $name
    $localHash = Get-FileSha256 $dst

    # OpenCV runtime is large and stable. Keep an existing local copy as-is,
    # and do not enforce manifest hash on it; some dufs paths have shown
    # inconsistent hashes for this DLL even when size matches.
    $skipHash = ($name -ieq 'opencv_world4100.dll')
    if ($skipHash -and (Test-Path $dst)) {
        Write-Log "跳过 OpenCV DLL (本地已存在, 不校验): $name" 'WARN'
        continue
    }

    if ($name -eq 'screenagent.ini' -and $hasLocalIni) {
        Write-Log "保留本地配置: screenagent.ini"
        continue
    }

    $needDownload = $false
    if (-not (Test-Path $dst)) {
        $needDownload = $true
    } elseif ($remoteHash -and -not $skipHash) {
        if ($localHash -ne $remoteHash.ToLower()) { $needDownload = $true }
    } elseif ($localVersion -ne $manifest.version) {
        $needDownload = $true
    }

    if (-not $needDownload) {
        Write-Log "跳过 (已是最新): $name"
        continue
    }

    $url = "$base/$name"
    Write-Log "下载: $url" 'WARN'
    $ok = Get-RemoteFile -Url $url -OutFile $dst
    if (-not $ok) {
        $other = if ($chosen -eq 'github') { 'cn' } else { 'github' }
        $altUrl = "$($sources[$other])/$name"
        Write-Log "尝试备用源: $altUrl" 'WARN'
        $ok = Get-RemoteFile -Url $altUrl -OutFile $dst
    }
    if (-not $ok) {
        Fail "无法下载 $name" 30
    }

    if ($remoteHash -and -not $skipHash) {
        $newHash = Get-FileSha256 $dst
        if ($newHash -ne $remoteHash.ToLower()) {
            Fail "$name 校验失败 期望=$remoteHash 实际=$newHash" 31
        }
    } elseif ($skipHash) {
        Write-Log "OpenCV DLL 已下载, 跳过 SHA 校验: $name" 'WARN'
    }
    $changed = $true
}

Set-Content -Path $versionFile -Value $manifest.version -Encoding ASCII

if (-not (Test-Path $agentExe)) {
    Fail "ScreenAgent.exe 不存在: $agentExe" 32
}

$iniPath = Join-Path $InstallDir 'screenagent.ini'
if (($ServerIp -or $ServerPort -gt 0 -or $ServerPassword) -or -not (Test-Path $iniPath)) {
    $h = if ($ServerIp) { $ServerIp } else { '110.42.44.89' }
    $p = if ($ServerPort -gt 0) { $ServerPort } else { 9999 }
    $w = if ($ServerPassword) { $ServerPassword } else { '' }
    $iniContent = @"
[Server]
Host=$h
Port=$p
Password=$w
ReconnectSeconds=10

[Screen]
; JPEG quality 1-100 (higher = clearer but more bandwidth)
Quality=100
"@
    Set-Content -Path $iniPath -Value $iniContent -Encoding ASCII
    Write-Log "写入 screenagent.ini: Host=$h Port=$p" 'WARN'
}

$runCmd = "`"$agentExe`" -run"
if ($isSelf) {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-ItemProperty `
        -Path $runKey `
        -Name $RunValueName `
        -Value $runCmd `
        -PropertyType String `
        -Force | Out-Null
    Write-Log "已写入 HKCU\...\Run\$RunValueName = $runCmd" 'WARN'

    if ($RunNowIfSelf) {
        Start-Process -FilePath $agentExe -ArgumentList '-run' -WorkingDirectory $InstallDir -WindowStyle Hidden
        Write-Log "已在当前用户 session 启动 ScreenAgent.exe -run" 'WARN'
    }
} else {
    Write-UserRun -Sid $TargetSID -ValueName $RunValueName -Command $runCmd
    Write-Log "目标用户下次登录时会自动运行。SYSTEM 写入 Run 不会立刻触发当前用户 session 启动。" 'WARN'
}

Set-Content -Path $installedMarker -Value (Get-Date -Format 'o') -Encoding ASCII

Write-Host ""
Write-Host "  ScreenAgent SID install ready  " -ForegroundColor Green -BackgroundColor Black
Write-Host "  TargetSID: $TargetSID"
Write-Host "  Command:   $runCmd"
Write-Host "  Version:   $($manifest.version)"
if ($changed) {
    Write-Host "  Files:     updated"
} else {
    Write-Host "  Files:     already current"
}
Write-Host ""






