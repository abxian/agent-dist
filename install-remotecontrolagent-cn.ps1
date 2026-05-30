$ScriptFlavor = 'remotecontrol-cn-uuid-task-20260601'
<#
RemoteControlAgent 安装脚本 (国内源优先, UUID + 管理员计划任务版本)

亮点:
  - 自动 elevate 到管理员 (UAC), 不用先开 admin shell
  - 自动检测当前登录的交互用户, 不再要求脚本顶部硬编码 SID
  - 每台机器生成一次性 UUID, 保存在 InstallDir\install.uuid, 用于:
      * Scheduled Task 名 (RemoteControlAgent_<uuid>) — 避免多机或重复装时冲突
      * Agent ini 的 ; install-id 注释 — Server UI 编辑配置时看得见
  - 装成 Scheduled Task "At log on" 触发, RunLevel HIGHEST (管理员)
      * 跑在用户 session, 能抓到桌面 (不黑屏)
      * 同时是管理员, 能抓到 UAC / 提升窗口, 能 SendInput 到 elevated 进程
  - 立刻 Run 一次, 当前 session 直接起 agent, 不用等下次登录
  - 清理掉旧的 Windows 服务 + HKU Run + HKLM Run, 防止同时跑多份

用法 (国内源, 一行搞定):
    iex (irm http://114.80.36.225:15667/6/install-remotecontrolagent-cn.ps1)

可选: 改下面 $ServerIp / $ServerPort / $ServerPassword 默认值后保存再执行,
或在执行前 $env:RCA_SERVER_IP = 'sx1.jc116.com' 等环境变量临时覆盖。
#>

# ── 配置区 ───────────────────────────────────────────────────────────────────
$InstallDir       = "$env:ProgramData\RemoteControlAgent"
$ServerIp         = if ($env:RCA_SERVER_IP)       { $env:RCA_SERVER_IP }       else { 'sx1.jc116.com' }
$ServerPort       = if ($env:RCA_SERVER_PORT)     { [int]$env:RCA_SERVER_PORT } else { 9999 }
$ServerPassword   = if ($env:RCA_SERVER_PASSWORD) { $env:RCA_SERVER_PASSWORD } else { '' }

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

$ManifestName = 'version-remotecontrol.json'
$TaskPrefix   = 'RemoteControlAgent_'

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
    # Re-launch ourselves elevated. We can't easily re-run "iex (irm URL)"
    # via -Verb RunAs because the elevated shell is a fresh process — pass
    # the iex one-liner so it re-fetches the latest script.
    $cmd = "iex (irm http://114.80.36.225:15667/6/install-remotecontrolagent-cn.ps1)"
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

# ── HTTP helpers (same as old script) ───────────────────────────────────────
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
    # signal. When called from SYSTEM (e.g. running via PsExec -s or a
    # remote management agent), multiple sessions may be present —
    # prefer the lowest non-zero SessionId, which on a typical box is
    # the local console user (session 1). Skip session 0 (services).
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
if (-not $user) {
    Fail "找不到任何交互登录用户 (没有 explorer.exe 进程)。请先用普通用户登录桌面再装。" 5
}
Write-Log "目标交互用户: $($user.Account) (SID=$($user.Sid), Session=$($user.SessionId))" 'WARN'

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
$defaultFiles = @('RemoteControlAgent.exe', 'remotecontrolagent.ini', 'opencv_world4100.dll')
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

# ── Install dir + UUID ──────────────────────────────────────────────────────
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
$uuidFile = Join-Path $InstallDir 'install.uuid'
if (Test-Path $uuidFile) {
    $uuid = (Get-Content $uuidFile -Raw).Trim()
    Write-Log "复用已有 install UUID: $uuid"
} else {
    # 8-char prefix of a real GUID — short enough for task names, still
    # unique-enough that two installs on the same network collide ~never.
    $uuid = ([Guid]::NewGuid().ToString('N')).Substring(0, 8)
    Set-Content -Path $uuidFile -Value $uuid -Encoding ASCII
    Write-Log "生成新 install UUID: $uuid" 'WARN'
}
$taskName    = "$TaskPrefix$uuid"
$versionFile = Join-Path $InstallDir 'installed.version'
$localVersion = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '' }
$agentExe    = Join-Path $InstallDir 'RemoteControlAgent.exe'

Write-Log "安装目录:  $InstallDir" 'WARN'
Write-Log "Task 名:   $taskName" 'WARN'
Write-Log "本地版本:  '$localVersion'  远端版本: '$($manifest.version)'" 'WARN'

# ── Clean up legacy footprints — service / Run keys / old tasks ─────────────
$svc = Get-Service -Name 'RemoteControlAgent' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Log "清理旧 Windows 服务 RemoteControlAgent (避免 session 0 黑屏)" 'WARN'
    try { & sc.exe stop   RemoteControlAgent | Out-Null } catch {}
    Start-Sleep -Seconds 1
    try { & sc.exe delete RemoteControlAgent | Out-Null } catch {}
}

# Old HKLM Run entry that earlier versions of this installer may have left
try {
    Remove-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'RemoteControlAgent' -Force -ErrorAction SilentlyContinue
} catch {}

# Old HKU\<SID>\Run entry from the previous SID-based installer
foreach ($k in Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue) {
    if ($k.PSChildName -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { continue }
    $runKey = "Registry::HKEY_USERS\$($k.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Run"
    if (Test-Path $runKey) {
        try { Remove-ItemProperty -Path $runKey -Name 'RemoteControlAgent' -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# Any scheduled tasks our prefix owns (across UUID changes too — defensive)
foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    if ($t.TaskName -like "$TaskPrefix*" -or $t.TaskName -eq 'RemoteControlAgent') {
        Write-Log "删除旧任务: $($t.TaskName)" 'WARN'
        try { Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false } catch {}
    }
}

# Kill any agent process still running from this install dir
Get-Process -Name 'RemoteControlAgent' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        if ($_.Path -and (Split-Path $_.Path -Parent) -eq $InstallDir) {
            Write-Log "结束残留 RemoteControlAgent.exe (PID=$($_.Id))" 'WARN'
            Stop-Process -Id $_.Id -Force
        }
    } catch {}
}
Start-Sleep -Milliseconds 500

# ── Download / verify files (skip ini + opencv on hash-drift) ───────────────
$hasLocalIni = Test-Path (Join-Path $InstallDir 'remotecontrolagent.ini')
$changed = $false
foreach ($f in $manifest.files) {
    $name = $f.name
    $remoteHash = if ($f.PSObject.Properties.Name -contains 'sha256') { $f.sha256 } else { $null }
    $dst = Join-Path $InstallDir $name
    $localHash = Get-FileSha256 $dst
    $skipHash = (($name -ieq 'opencv_world4100.dll') -or ($name -ieq 'remotecontrolagent.ini'))
    if ($skipHash -and (Test-Path $dst)) {
        Write-Log "跳过运行时/配置文件 (本地已存在): $name"
        continue
    }
    if ($name -eq 'remotecontrolagent.ini' -and $hasLocalIni) { continue }
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
    if ($remoteHash -and -not $skipHash) {
        $newHash = Get-FileSha256 $dst
        if ($newHash -ne $remoteHash.ToLower()) { Fail "$name 校验失败 期望=$remoteHash 实际=$newHash" 31 }
    }
    $changed = $true
}
Set-Content -Path $versionFile -Value $manifest.version -Encoding ASCII

if (-not (Test-Path $agentExe)) { Fail "RemoteControlAgent.exe 不存在: $agentExe" 32 }

# ── Write fresh ini (server config + install-id comment) ────────────────────
$iniPath = Join-Path $InstallDir 'remotecontrolagent.ini'
$h = if ($ServerIp) { $ServerIp } else { 'sx1.jc116.com' }
$p = if ($ServerPort -gt 0) { $ServerPort } else { 9999 }
$w = if ($ServerPassword) { $ServerPassword } else { '' }
$iniContent = @"
; ================================================
; Remote Control Agent — install-id: $uuid
; ================================================
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

# ── Create the scheduled task (logon + HIGHEST privilege) ───────────────────
#  Trigger:   At logon of the detected interactive user
#  Principal: That user, RunLevel Highest (avoids the session 0 black-screen
#             AND the UAC-can't-see-elevated-windows problem in one shot)
#  Settings:  Don't stop on AC/battery transitions, restart up to 3× on
#             failure, no execution time limit
$action  = New-ScheduledTaskAction `
            -Execute $agentExe `
            -Argument '-run' `
            -WorkingDirectory $InstallDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user.Account
$principal = New-ScheduledTaskPrincipal `
            -UserId $user.Sid `
            -LogonType Interactive `
            -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null
Write-Log "已注册 Scheduled Task: $taskName (atLogon, $($user.Account), RunLevel=Highest)" 'WARN'

# ── Fire once now so the agent is up in the current session without ─────────
# waiting for a logoff/logon cycle.
try {
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 2
} catch {
    Write-Log "立即触发任务失败, 用户下次登录会自动起。错误: $($_.Exception.Message)" 'WARN'
}

# ── Sanity check ────────────────────────────────────────────────────────────
$running = Get-Process -Name 'RemoteControlAgent' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and (Split-Path $_.Path -Parent) -eq $InstallDir }
if ($running) {
    Write-Log "RemoteControlAgent 已在用户 session 启动 (PID=$($running.Id))" 'WARN'
} else {
    Write-Log "未检测到 RemoteControlAgent 进程, 等几秒再 Get-Process 看看 — 任务可能正在加载 OpenCV DLL" 'WARN'
}

Write-Host ""
Write-Host "  RemoteControlAgent 已安装  " -ForegroundColor Green -BackgroundColor Black
Write-Host "  Install-ID:  $uuid"
Write-Host "  Task Name:   $taskName"
Write-Host "  Target User: $($user.Account)  (admin elevated, user session)"
Write-Host "  Server:      $h`:$p"
Write-Host "  Version:     $($manifest.version)"
if ($changed) { Write-Host "  Files:       updated" } else { Write-Host "  Files:       already current" }
Write-Host ""
Write-Host "  日常更新只需再跑一次同一个 iex 命令; UUID + Task 都会沿用。"
Write-Host ""
