$ScriptFlavor = 'screenagent-cn-task-20260601'
<#
ScreenAgent 安装脚本 (国内源优先, 自动检测用户 + 管理员计划任务版本)

亮点:
  - 自动 elevate 到管理员 (UAC); SYSTEM 自动跳过 UAC 直接装
  - 自动检测当前登录的交互用户 — 不再要求手动查 SID 再贴进脚本
  - 装成 Scheduled Task "At log on" 触发, RunLevel HIGHEST (管理员)
      * 跑在用户 session, 能抓到真实桌面 (不黑屏)
      * 同时是管理员, 能看到 UAC / 提升窗口
  - 无人值守 fallback: 没人登录时改成 "任意用户登录都触发"
    (Principal = BUILTIN\Users), 适合克隆机器/PXE 流水线
  - 立刻 Run 一次 (有用户的话), 当前 session 直接起 agent
  - 清理掉旧的 Windows 服务 + HKU\<SID>\Run + HKLM Run + 旧 task, 防止同时跑多份

用法 (国内源, 一行搞定):
    iex (irm http://114.80.36.225:15667/6/install-screenagent-sid-nocv-cn.ps1)

可选: 改下面 $ServerIp / $ServerPort / $ServerPassword 默认值后保存再执行,
或在执行前 $env:SA_SERVER_IP = 'sx1.jc116.com' 等环境变量临时覆盖。
#>

# ── 配置区 ───────────────────────────────────────────────────────────────────
$InstallDir       = "$env:ProgramData\ScreenAgent"
$ServerIp         = if ($env:SA_SERVER_IP)       { $env:SA_SERVER_IP }       else { 'sx1.jc116.com' }
$ServerPort       = if ($env:SA_SERVER_PORT)     { [int]$env:SA_SERVER_PORT } else { 9999 }
$ServerPassword   = if ($env:SA_SERVER_PASSWORD) { $env:SA_SERVER_PASSWORD } else { '' }
$ServerProtocol   = if ($env:CAM_SERVER_PROTOCOL) { $env:CAM_SERVER_PROTOCOL.ToLowerInvariant() } else { 'tcp' }
$CertificateFingerprint = if ($env:CAM_SERVER_FINGERPRINT) { ($env:CAM_SERVER_FINGERPRINT -replace '[^0-9a-fA-F]','').ToLowerInvariant() } else { '' }
if ($ServerProtocol -notin @('tcp','tls') -or ($ServerProtocol -eq 'tls' -and $CertificateFingerprint.Length -ne 64)) { throw 'Invalid TLS settings: set CAM_SERVER_PROTOCOL=tls and a 64-hex CAM_SERVER_FINGERPRINT' }

$Source           = 'cn'   # auto / github / cn
$GithubUser       = 'abxian'
$GithubRepo       = 'agent-dist'
$GithubBranch     = 'main'
$CnBase           = 'http://114.80.36.225:15667/6'
$ShowInfoLogs     = $true

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol =
    [Net.SecurityProtocolType]::Tls12 -bor
    [Net.SecurityProtocolType]::Tls11 -bor
    [Net.SecurityProtocolType]::Tls

$ManifestName = 'version-screen.json'
$TaskName     = 'ScreenAgent'
$ServiceName  = 'RemoteScreenAgent'
$RunValueName = 'ScreenAgent'

# ── Logging ─────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    if (-not $ShowInfoLogs -and $Level -eq 'INFO') { return }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
    Write-Host "[$ts][$Level] $Msg" -ForegroundColor $color
}
function Fail { param([string]$Msg, [int]$Code = 1) Write-Log $Msg 'ERROR'; exit $Code }

# ── Self-elevate (UAC) ──────────────────────────────────────────────────────
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($me)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSystem = ($me.User.Value -eq 'S-1-5-18')

if (-not $isAdmin -and -not $isSystem) {
    Write-Log "当前不是管理员, 自动 elevate (会弹 UAC)..." 'WARN'
    $cmd = "iex (irm http://114.80.36.225:15667/6/install-screenagent-sid-nocv-cn.ps1)"
    Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
    exit 0
}
if ($isSystem) {
    # SYSTEM is strictly more privileged than Administrator — no UAC needed
    # and none possible (UAC requires an interactive desktop, session 0 has
    # none). Continue directly; everything below works the same as Admin.
    Write-Log "以 SYSTEM 身份运行 — 跳过 UAC, 直接安装" 'WARN'
}

# ── HTTP helpers ────────────────────────────────────────────────────────────
function Get-RemoteFile {
    # 默认 600s: 64MB 的 opencv_world4100.dll 在慢网络上常常超过 30s
    param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 600)
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
    try { return (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec).Content }
    catch { return $null }
}
function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower()
}
function Test-SourceReachable {
    param([string]$Url)
    try { $req = [Net.HttpWebRequest]::Create($Url); $req.Method = 'HEAD'; $req.Timeout = 4000; $req.GetResponse().Close(); return $true }
    catch { return $false }
}

# ── Auto-detect the interactive user (the one whose desktop we want to see) ─
function Get-InteractiveUser {
    # explorer.exe is the canonical "this user has an interactive shell"
    # signal. When called from SYSTEM (PsExec -s / remote mgmt tool /
    # service), multiple sessions may be present — prefer the lowest
    # non-zero SessionId, which on a typical box is the local console
    # user (session 1). Skip session 0 (services).
    $best = $null
    $explorers = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $explorers) {
        if ($p.SessionId -le 0) { continue }
        try {
            $owner = $p.GetOwner()
            $sid = $p.GetOwnerSid().Sid
            if (-not $owner -or -not $owner.User) { continue }
            if ($sid -notmatch '^S-1-5-21-') { continue }
            $info = [pscustomobject]@{
                Account   = "$($owner.Domain)\$($owner.User)"
                Sid       = $sid
                SessionId = [int]$p.SessionId
            }
            if (-not $best -or $info.SessionId -lt $best.SessionId) {
                $best = $info
            }
        } catch {}
    }
    return $best
}

$user = Get-InteractiveUser
if ($user) {
    Write-Log "目标交互用户: $($user.Account) (SID=$($user.Sid), Session=$($user.SessionId))" 'WARN'
} else {
    Write-Log "未检测到交互用户 (没有 explorer.exe), 切换到无人值守模式: 任意用户登录都触发" 'WARN'
}

# ── Choose source ──────────────────────────────────────────────────────────
$githubRaw = "https://raw.githubusercontent.com/$GithubUser/$GithubRepo/$GithubBranch"
$sources = @{ github = $githubRaw; cn = $CnBase }
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
Write-Log "使用源: $chosen ($base)" 'WARN'

# ── Manifest ────────────────────────────────────────────────────────────────
$manifestUrl = "$base/$ManifestName"
$manifestRaw = Get-RemoteString $manifestUrl
$manifestRaw = if ($manifestRaw) { $manifestRaw.TrimStart([char]0xFEFF) } else { $manifestRaw }
$defaultFiles = @('ScreenAgent.exe', 'screenagent.ini', 'opencv_world4100.dll')
$manifest = $null
if ($manifestRaw) {
    try { $manifest = $manifestRaw | ConvertFrom-Json } catch { $manifest = $null }
}
if (-not $manifest) {
    Write-Log "未获取到 $ManifestName, 回退为时间戳版本号 + 强制下载" 'WARN'
    $manifest = [pscustomobject]@{
        version = (Get-Date -Format 'yyyyMMddHHmm')
        files = $defaultFiles | ForEach-Object { [pscustomobject]@{ name = $_; sha256 = $null } }
    }
}
# A stale/custom manifest must not be allowed to omit runtime dependencies.
# CAM_OPENCV_URL is still honoured by the generated delivery installer.
$manifestFiles = @($manifest.files)
foreach ($requiredName in $defaultFiles) {
    if (-not ($manifestFiles | Where-Object { $_.name -ieq $requiredName })) {
        Write-Log "版本清单缺少必需文件, 自动补充: $requiredName" 'WARN'
        $manifestFiles += [pscustomobject]@{ name = $requiredName; sha256 = $null }
    }
}
$manifest.files = $manifestFiles

# ── Install dir ─────────────────────────────────────────────────────────────
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
$versionFile  = Join-Path $InstallDir 'installed.version'
$localVersion = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '' }
$agentExe     = Join-Path $InstallDir 'ScreenAgent.exe'

Write-Log "安装目录:  $InstallDir" 'WARN'
Write-Log "Task 名:   $TaskName" 'WARN'
Write-Log "本地版本:  '$localVersion'  远端版本: '$($manifest.version)'" 'WARN'

# ── Clean up legacy footprints — service / Run keys / old tasks ─────────────
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    Write-Log "清理旧 Windows 服务 $ServiceName (避免 session 0 黑屏)" 'WARN'
    try { & sc.exe stop   $ServiceName | Out-Null } catch {}
    Start-Sleep -Seconds 1
    try { & sc.exe delete $ServiceName | Out-Null } catch {}
}

# Old HKLM Run entry from earlier installers
try {
    Remove-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name $RunValueName -Force -ErrorAction SilentlyContinue
} catch {}

# Old HKU\<SID>\Run entry from the SID-based installer this script replaces.
# 遍历所有 user profile (Win32_UserProfile), 不只是当前已加载 hive 的用户.
# 离线用户的 hive 用 reg load / reg unload 临时挂上, 否则他们下次登录时会从
# Run 键拉起第二份 ScreenAgent (同 RC 之前出现的 2 个实例 bug).
foreach ($prof in (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
                   Where-Object { $_.LocalPath -like 'C:\Users\*' -and -not $_.Special })) {
    $sid = $prof.SID
    $needUnload = $false
    if (-not $prof.Loaded) {
        $ntuser = Join-Path $prof.LocalPath 'NTUSER.DAT'
        if (-not (Test-Path $ntuser)) { continue }
        & reg load "HKU\$sid" "$ntuser" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { continue }  # 多半是用户正在登录, 跳过
        $needUnload = $true
    }
    try {
        $runKey = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Run"
        if (Test-Path $runKey) {
            $cur = (Get-ItemProperty -Path $runKey -Name $RunValueName -ErrorAction SilentlyContinue).$RunValueName
            if ($cur) {
                Remove-ItemProperty -Path $runKey -Name $RunValueName -Force -ErrorAction SilentlyContinue
                Write-Log "清理 HKU\$sid\...\Run\$RunValueName (旧 install 残留)" 'WARN'
            }
        }
    } finally {
        if ($needUnload) {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds 300
            & reg unload "HKU\$sid" 2>&1 | Out-Null
        }
    }
}

# Old scheduled tasks: the fixed name + any legacy "ScreenAgent-Start-..."
# variants left over from the previous one-shot-launch helper.
foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    if ($t.TaskName -eq $TaskName -or $t.TaskName -like 'ScreenAgent-*') {
        Write-Log "删除旧任务: $($t.TaskName)" 'WARN'
        try { Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false } catch {}
    }
}

# Kill any agent process still running from this install dir
Get-Process -Name 'ScreenAgent' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        if ($_.Path -and (Split-Path $_.Path -Parent) -eq $InstallDir) {
            Write-Log "结束残留 ScreenAgent.exe (PID=$($_.Id))" 'WARN'
            Stop-Process -Id $_.Id -Force
        }
    } catch {}
}
Start-Sleep -Milliseconds 500

# ── Download / verify files (skip ini + opencv on hash-drift) ───────────────
$hasLocalIni = Test-Path (Join-Path $InstallDir 'screenagent.ini')
$changed = $false
foreach ($f in $manifest.files) {
    $name = $f.name
    $remoteHash = if ($f.PSObject.Properties.Name -contains 'sha256') { $f.sha256 } else { $null }
    $dst = Join-Path $InstallDir $name
    $localHash = Get-FileSha256 $dst
    $skipHash = (($name -ieq 'opencv_world4100.dll') -or ($name -ieq 'screenagent.ini'))
    $runtimeValid = ($name -ieq 'opencv_world4100.dll') -and (Test-Path $dst) -and
        ((Get-Item -LiteralPath $dst).Length -ge 10MB)
    if (($name -ieq 'screenagent.ini') -and (Test-Path $dst)) {
        Write-Log "跳过运行时/配置文件 (本地已存在): $name"
        continue
    }
    if ($runtimeValid) {
        Write-Log "跳过 OpenCV DLL (本地文件有效): $name"
        continue
    }
    if ($name -eq 'screenagent.ini' -and $hasLocalIni) { continue }
    $needDownload = $false
    if (-not (Test-Path $dst)) { $needDownload = $true }
    elseif ($remoteHash -and -not $skipHash) { if ($localHash -ne $remoteHash.ToLower()) { $needDownload = $true } }
    elseif ($localVersion -ne $manifest.version) { $needDownload = $true }
    if (-not $needDownload) { Write-Log "跳过 (已是最新): $name"; continue }

    $url = "$base/$name"
    Write-Log "下载: $url" 'WARN'
    $ok = Get-RemoteFile -Url $url -OutFile $dst
    if (-not $ok) {
        $other = if ($chosen -eq 'github') { 'cn' } else { 'github' }
        $altUrl = "$($sources[$other])/$name"
        Write-Log "尝试备用源: $altUrl" 'WARN'
        $ok = Get-RemoteFile -Url $altUrl -OutFile $dst
    }
    if (-not $ok) { Fail "无法下载 $name" 30 }
    if (($name -ieq 'opencv_world4100.dll') -and
        ((-not (Test-Path $dst)) -or ((Get-Item -LiteralPath $dst).Length -lt 10MB))) {
        Fail "OpenCV DLL 下载结果无效或文件不完整: $dst" 32
    }
    if ($remoteHash -and -not $skipHash) {
        $newHash = Get-FileSha256 $dst
        if ($newHash -ne $remoteHash.ToLower()) { Fail "$name 校验失败 期望=$remoteHash 实际=$newHash" 31 }
    }
    $changed = $true
}
Set-Content -Path $versionFile -Value $manifest.version -Encoding ASCII

if (-not (Test-Path $agentExe)) { Fail "ScreenAgent.exe 不存在: $agentExe" 32 }

# ── Write fresh ini (server config only) ────────────────────────────────────
$iniPath = Join-Path $InstallDir 'screenagent.ini'
$h = if ($ServerIp) { $ServerIp } else { 'sx1.jc116.com' }
$p = if ($ServerPort -gt 0) { $ServerPort } else { 9999 }
$w = if ($ServerPassword) { $ServerPassword } else { '' }
$iniContent = @"
[Server]
Host=$h
Port=$p
Password=$w
Protocol=$ServerProtocol
CertificateFingerprint=$CertificateFingerprint
ReconnectSeconds=10

[Screen]
; JPEG quality 1-100 (higher = clearer but more bandwidth)
Quality=100
"@
Set-Content -Path $iniPath -Value $iniContent -Encoding ASCII
Write-Log "写入 screenagent.ini: Host=$h Port=$p" 'WARN'

# ── Create the scheduled task (logon + HIGHEST privilege) ───────────────────
#  Two modes:
#    A) Interactive user detected → trigger at logon of THAT user, principal
#       = that user. The typical "有人在桌面前" 场景.
#    B) No user detected (unattended) → trigger at logon of ANY user, principal
#       = BUILTIN\Users group (SID S-1-5-32-545). 首次有人登录就接管.
#  两种模式都用 RunLevel Highest 拿管理员权限，避免 session 0 黑屏 + UAC
#  看不见 / SendInput 不到提升进程的问题.
$action  = New-ScheduledTaskAction `
            -Execute $agentExe `
            -Argument '-run' `
            -WorkingDirectory $InstallDir
$settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -MultipleInstances IgnoreNew

if ($user) {
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user.Account
    $principal = New-ScheduledTaskPrincipal `
                    -UserId $user.Sid `
                    -LogonType Interactive `
                    -RunLevel Highest
    $modeDesc  = "atLogon[$($user.Account)], RunLevel=Highest"
} else {
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal `
                    -GroupId 'S-1-5-32-545' `
                    -RunLevel Highest
    $modeDesc  = "atLogon[ANY USER], BUILTIN\Users, RunLevel=Highest"
}

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null
Write-Log "已注册 Scheduled Task: $TaskName ($modeDesc)" 'WARN'

# Fire once now ONLY if we have a target user logged in.
if ($user) {
    try {
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 2
    } catch {
        Write-Log "立即触发任务失败, 用户下次登录会自动起。错误: $($_.Exception.Message)" 'WARN'
    }
} else {
    Write-Log "无人值守模式: agent 将在下一个用户登录时自动起动" 'WARN'
}

# ── Sanity check (only meaningful in mode A) ────────────────────────────────
if ($user) {
    $running = Get-Process -Name 'ScreenAgent' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and (Split-Path $_.Path -Parent) -eq $InstallDir }
    if ($running) {
        Write-Log "ScreenAgent 已在用户 session 启动 (PID=$($running.Id))" 'WARN'
    } else {
        Write-Log "未检测到 ScreenAgent 进程, 等几秒再 Get-Process 看看 — 任务可能正在加载 OpenCV DLL" 'WARN'
    }
}

Write-Host ""
Write-Host "  ScreenAgent 已安装  " -ForegroundColor Green -BackgroundColor Black
Write-Host "  Task Name:   $TaskName"
if ($user) {
    Write-Host "  Target User: $($user.Account)  (admin elevated, user session)"
} else {
    Write-Host "  Target User: 任意用户登录时触发 (BUILTIN\Users, 管理员权限)"
}
Write-Host "  Server:      $h`:$p"
Write-Host "  Version:     $($manifest.version)"
if ($changed) { Write-Host "  Files:       updated" } else { Write-Host "  Files:       already current" }
Write-Host ""
Write-Host "  日常更新只需再跑一次同一个 iex 命令; 旧 Task 会被自动覆盖。"
Write-Host ""
