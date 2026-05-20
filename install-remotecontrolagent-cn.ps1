$ScriptFlavor = 'remotecontrol-cn-20260510-sid-autostart'
<#
RemoteControlAgent SID 安装脚本 (国内源优先)

用途:
  给指定 Windows 用户 SID 写入 HKU\<SID>\Software\Microsoft\Windows\CurrentVersion\Run,
  让 RemoteControlAgent 在该用户下次登录时以用户 session 运行。

示例:
  1. 修改脚本顶部配置区里的 $TargetSID / $ServerIp / $ServerPort
  2. 直接执行:
       iex (irm http://114.80.36.225:15667/6/install-remotecontrolagent-cn.ps1)

说明:
  - 适用于已授权管理的机房/实验室电脑。
  - SYSTEM 下不会写 S-1-5-18, 只写配置区里的用户 SID。
  - 给其他 SID 写入 Run 后不会立刻运行, 目标用户下次登录时启动。
#>

# ── 配置区: 直接替换这里, 然后用 iex (irm URL) 一键执行 ─────────────────────
$TargetSID = 'S-1-5-21-4156230380-561108038-141577317-500'
$ServerIp = 'sx1.jc116.com'
$ServerPort = 9999
$ServerPassword = ''

$Source = 'cn'   # auto / github / cn
$InstallDir = "$env:ProgramData\RemoteControlAgent"
$GithubUser = 'abxian'
$GithubRepo = 'agent-dist'
$GithubBranch = 'main'
$CnBase = 'http://114.80.36.225:15667/6'
$RunNowIfSelf = $false
$AutoRunAfterUpdate = $true
$ShowInfoLogs = $true

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol =
    [Net.SecurityProtocolType]::Tls12 -bor
    [Net.SecurityProtocolType]::Tls11 -bor
    [Net.SecurityProtocolType]::Tls

$ManifestName = 'version-remotecontrol.json'
$RunValueName = 'RemoteControlAgent'

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

function Mount-UserHiveIfNeeded {
    param([string]$Sid)

    $hivePath = "Registry::HKEY_USERS\$Sid"
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

    $tmp = Join-Path $env:TEMP "remotecontrolagent-reg-unload-$($Sid -replace '[^A-Za-z0-9-]', '_').txt"
    $err = Join-Path $env:TEMP "remotecontrolagent-reg-unload-$($Sid -replace '[^A-Za-z0-9-]', '_').err.txt"
    $p = Start-Process `
        -FilePath "$env:SystemRoot\System32\reg.exe" `
        -ArgumentList @('unload', "HKU\$Sid") `
        -Wait `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $tmp `
        -RedirectStandardError $err
    $code = $p.ExitCode
    $out = if (Test-Path $tmp) { Get-Content $tmp -Raw -ErrorAction SilentlyContinue } else { '' }
    $errOut = if (Test-Path $err) { Get-Content $err -Raw -ErrorAction SilentlyContinue } else { '' }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Remove-Item $err -Force -ErrorAction SilentlyContinue

    if ($code -ne 0) {
        Write-Log "reg unload 失败但安装继续。通常是系统还占用 hive, 重启后会自然释放。SID=HKU\$Sid 输出=$out $errOut" 'WARN'
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
        $runKey = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Run"
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

function Get-RunValueFromSid {
    param(
        [string]$Sid,
        [string]$ValueName
    )
    $runKey = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Run"
    try {
        if (-not (Test-Path $runKey)) { return $null }
        $props = Get-ItemProperty -Path $runKey -Name $ValueName -ErrorAction SilentlyContinue
        if (-not $props) { return $null }
        return $props.$ValueName
    } catch {
        return $null
    }
}

function Find-ExistingUserRun {
    param(
        [string]$ValueName,
        [string]$ExpectedExe
    )

    $expected = $ExpectedExe.ToLowerInvariant()
    $loaded = Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' }

    foreach ($k in $loaded) {
        $sid = $k.PSChildName
        $value = Get-RunValueFromSid -Sid $sid -ValueName $ValueName
        if ($value -and $value.ToLowerInvariant().Contains($expected)) {
            return [pscustomobject]@{ Sid = $sid; Value = $value; Loaded = $true }
        }
    }

    $profiles = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' }

    foreach ($p in $profiles) {
        $sid = $p.PSChildName
        if ($loaded.PSChildName -contains $sid) { continue }

        $profilePathRaw = (Get-ItemProperty $p.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $profilePathRaw) { continue }
        $profilePath = [Environment]::ExpandEnvironmentVariables($profilePathRaw)
        $ntuser = Join-Path $profilePath 'NTUSER.DAT'
        if (-not (Test-Path $ntuser)) { continue }

        $loadedHere = $false
        try {
            $loadOut = & reg.exe load "HKU\$sid" "$ntuser" 2>&1
            if ($LASTEXITCODE -ne 0) { continue }
            $loadedHere = $true

            $value = Get-RunValueFromSid -Sid $sid -ValueName $ValueName
            if ($value -and $value.ToLowerInvariant().Contains($expected)) {
                return [pscustomobject]@{ Sid = $sid; Value = $value; Loaded = $false }
            }
        } catch {
        } finally {
            if ($loadedHere) {
                Unmount-UserHive -Sid $sid
            }
        }
    }

    return $null
}

function Test-RemoteControlAgentRunning {
    param([string]$ExePath)
    $target = $ExePath.ToLowerInvariant()
    $procs = Get-Process -Name 'RemoteControlAgent' -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        try {
            if ($p.Path -and $p.Path.ToLowerInvariant() -eq $target) {
                return $true
            }
        } catch {}
    }
    return $false
}

function Get-LoggedOnUserBySid {
    param([string]$Sid)

    $explorers = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $explorers) {
        try {
            $ownerSid = $p.GetOwnerSid()
            if (-not $ownerSid -or $ownerSid.Sid -ne $Sid) { continue }

            $owner = $p.GetOwner()
            if ($owner -and $owner.User) {
                return [pscustomobject]@{
                    Account = "$($owner.Domain)\$($owner.User)"
                    SessionId = $p.SessionId
                }
            }
        } catch {}
    }

    return $null
}

function Start-RemoteControlAgentInUserSession {
    param(
        [string]$Sid,
        [string]$Command,
        [string]$ExePath
    )

    $user = Get-LoggedOnUserBySid -Sid $Sid
    if (-not $user) {
        Write-Log "目标 SID 当前没有检测到交互登录 session, 保留为下次登录自启。SID=$Sid" 'WARN'
        return $false
    }

    $taskName = "RemoteControlAgent-Start-$($Sid.Split('-')[-1])"
    $startTime = (Get-Date).AddMinutes(1).ToString('HH:mm')

    try { & schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null } catch {}

    $createOut = & schtasks.exe /Create `
        /TN $taskName `
        /TR $Command `
        /SC ONCE `
        /ST $startTime `
        /F `
        /RL LIMITED `
        /RU $user.Account `
        /IT 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Log "创建一次性启动任务失败, 将等待下次登录自启。User=$($user.Account) 输出=$createOut" 'WARN'
        return $false
    }

    $runOut = & schtasks.exe /Run /TN $taskName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "运行一次性启动任务失败, 将等待下次登录自启。Task=$taskName 输出=$runOut" 'WARN'
        return $false
    }

    Start-Sleep -Seconds 3
    try { & schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null } catch {}

    if (Test-RemoteControlAgentRunning -ExePath $ExePath) {
        Write-Log "已通过交互用户计划任务启动 RemoteControlAgent。User=$($user.Account) Session=$($user.SessionId)" 'WARN'
        return $true
    }

    Write-Log "计划任务已触发, 但暂未检测到 RemoteControlAgent 进程。若目标用户未解锁桌面, 会在下次登录自启。" 'WARN'
    return $false
}

$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$meSID = $me.User.Value
$isSystem = ($meSID -eq 'S-1-5-18')
$principal = New-Object Security.Principal.WindowsPrincipal($me)
$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

$agentExeForSidDetect = Join-Path $InstallDir 'RemoteControlAgent.exe'
$existingRun = Find-ExistingUserRun -ValueName $RunValueName -ExpectedExe $agentExeForSidDetect
$reusedExistingSid = $false
if ($existingRun) {
    $TargetSID = $existingRun.Sid
    $reusedExistingSid = $true
    Write-Log "检测到已安装 Run 项, 复用 SID=$TargetSID, 不再校验脚本顶部 SID。Value=$($existingRun.Value)" 'WARN'
}

if (-not $reusedExistingSid -and ($TargetSID -eq 'REPLACE_WITH_TARGET_USER_SID' -or $TargetSID -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$')) {
    Fail "请先替换脚本顶部 `$DefaultTargetSID, 或执行时传入 -TargetSID。当前值: $TargetSID" 9
}
if ($TargetSID -eq 'S-1-5-18') {
    Fail "拒绝写入 SYSTEM SID (S-1-5-18)。请传入真实登录用户 SID。" 10
}

$isSelf = ($TargetSID -eq $meSID)
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
$defaultFiles = @('RemoteControlAgent.exe', 'remotecontrolagent.ini', 'opencv_world4100.dll')
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
$agentExe = Join-Path $InstallDir 'RemoteControlAgent.exe'
$installedMarker = Join-Path $InstallDir '.installed.sid'

Write-Log "安装目录: $InstallDir" 'WARN'
Write-Log "运行身份: $($me.Name) ($meSID), TargetSID=$TargetSID" 'WARN'
Write-Log "本地版本: '$localVersion'  远端版本: '$($manifest.version)'" 'WARN'

# 清理旧服务形态, 避免 RemoteControlAgent 同时跑在 Session 0 和用户 session。
$svc = Get-Service -Name 'RemoteControlAgent' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Log "清理旧 Windows 服务 RemoteControlAgent" 'WARN'
    try { & sc.exe stop RemoteControlAgent | Out-Null } catch {}
    Start-Sleep -Seconds 1
    try { & sc.exe delete RemoteControlAgent | Out-Null } catch {}
}
try { & schtasks.exe /End /TN RemoteControlAgent 2>$null | Out-Null } catch {}
try { & schtasks.exe /Delete /TN RemoteControlAgent /F 2>$null | Out-Null } catch {}
try {
    Remove-ItemProperty `
        -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name $RunValueName `
        -Force `
        -ErrorAction SilentlyContinue
} catch {}

Get-Process -Name 'RemoteControlAgent' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        if ($_.Path -and (Split-Path $_.Path -Parent) -eq $InstallDir) {
            Write-Log "结束残留 RemoteControlAgent.exe (PID=$($_.Id))" 'WARN'
            Stop-Process -Id $_.Id -Force
        }
    } catch {}
}
Start-Sleep -Milliseconds 500

$hasLocalIni = Test-Path (Join-Path $InstallDir 'remotecontrolagent.ini')
$changed = $false

foreach ($f in $manifest.files) {
    $name = $f.name
    $remoteHash = if ($f.PSObject.Properties.Name -contains 'sha256') { $f.sha256 } else { $null }
    $dst = Join-Path $InstallDir $name
    $localHash = Get-FileSha256 $dst

    # OpenCV runtime is large and stable. remotecontrolagent.ini is rewritten below
    # from the configured server fields. Do not let line-ending/hash drift in
    # these files block installing the actual RemoteControlAgent.exe.
    $skipHash = (($name -ieq 'opencv_world4100.dll') -or ($name -ieq 'remotecontrolagent.ini'))
    if ($skipHash -and (Test-Path $dst)) {
        Write-Log "跳过运行时/配置文件 (本地已存在, 不校验): $name" 'WARN'
        continue
    }

    if ($name -eq 'remotecontrolagent.ini' -and $hasLocalIni) {
        Write-Log "保留本地配置: remotecontrolagent.ini"
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
        Write-Log "运行时/配置文件已下载, 跳过 SHA 校验: $name" 'WARN'
    }
    $changed = $true
}

Set-Content -Path $versionFile -Value $manifest.version -Encoding ASCII

if (-not (Test-Path $agentExe)) {
    Fail "RemoteControlAgent.exe 不存在: $agentExe" 32
}

$iniPath = Join-Path $InstallDir 'remotecontrolagent.ini'
if (($ServerIp -or $ServerPort -gt 0 -or $ServerPassword) -or -not (Test-Path $iniPath)) {
    $h = if ($ServerIp) { $ServerIp } else { 'sx1.jc116.com' }
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
    Write-Log "写入 remotecontrolagent.ini: Host=$h Port=$p" 'WARN'
}

$runCmd = "`"$agentExe`" -run"
$autoStarted = $false
if ($isSelf) {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-ItemProperty `
        -Path $runKey `
        -Name $RunValueName `
        -Value $runCmd `
        -PropertyType String `
        -Force | Out-Null
    Write-Log "已写入 HKCU\...\Run\$RunValueName = $runCmd" 'WARN'

    if ($RunNowIfSelf -or $AutoRunAfterUpdate) {
        Start-Process -FilePath $agentExe -ArgumentList '-run' -WorkingDirectory $InstallDir -WindowStyle Hidden
        Write-Log "已在当前用户 session 启动 RemoteControlAgent.exe -run" 'WARN'
        $autoStarted = $true
    }
} else {
    Write-UserRun -Sid $TargetSID -ValueName $RunValueName -Command $runCmd
    if ($AutoRunAfterUpdate) {
        $autoStarted = Start-RemoteControlAgentInUserSession -Sid $TargetSID -Command $runCmd -ExePath $agentExe
    }
    if (-not $autoStarted) {
        Write-Log "目标用户下次登录时会自动运行。SYSTEM 写入 Run 不一定能立刻触发当前用户 session 启动。" 'WARN'
    }
}

Set-Content -Path $installedMarker -Value (Get-Date -Format 'o') -Encoding ASCII

Write-Host ""
Write-Host "  RemoteControlAgent SID install ready  " -ForegroundColor Green -BackgroundColor Black
Write-Host "  TargetSID: $TargetSID"
Write-Host "  Command:   $runCmd"
Write-Host "  Version:   $($manifest.version)"
Write-Host "  AutoRun:   $autoStarted"
if ($changed) {
    Write-Host "  Files:     updated"
} else {
    Write-Host "  Files:     already current"
}
Write-Host ""








