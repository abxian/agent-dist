<#
RemoteControlAgent 安装脚本 (国内源优先, 管理员计划任务版本)

亮点:
  - 自动 elevate 到管理员 (UAC); SYSTEM 自动跳过 UAC 直接装
  - 自动检测当前登录的交互用户, 不再要求脚本顶部硬编码 SID
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

[CmdletBinding()]
param(
    [string]$InstallDir = $(if ($env:CAM_INSTALL_DIR) { $env:CAM_INSTALL_DIR } else { "$env:ProgramData\CamAgents\remotecontrol" }),
    [ValidateSet('auto','github','cn')]
    [string]$Source = 'cn',
    [string]$CnBase = $(if ($env:CAM_DELIVERY_BASE) { $env:CAM_DELIVERY_BASE.TrimEnd('/') + '/downloads' } else { 'http://114.80.36.225:15667/6' })
)
$ScriptFlavor = 'remotecontrol-cn-task-20260601'

# ── 配置区 ───────────────────────────────────────────────────────────────────
$ServerIp         = if ($env:RCA_SERVER_IP)       { $env:RCA_SERVER_IP }       else { 'sx1.jc116.com' }
$ServerPort       = if ($env:RCA_SERVER_PORT)     { [int]$env:RCA_SERVER_PORT } else { 9999 }
$ServerPassword   = if ($env:RCA_SERVER_PASSWORD) { $env:RCA_SERVER_PASSWORD } else { '' }
$ServerProtocol   = if ($env:CAM_SERVER_PROTOCOL) { $env:CAM_SERVER_PROTOCOL.ToLowerInvariant() } else { 'tcp' }
$CertificateFingerprint = if ($env:CAM_SERVER_FINGERPRINT) { ($env:CAM_SERVER_FINGERPRINT -replace '[^0-9a-fA-F]','').ToLowerInvariant() } else { '' }
if ($ServerProtocol -notin @('tcp','tls') -or ($ServerProtocol -eq 'tls' -and $CertificateFingerprint.Length -ne 64)) { throw 'Invalid TLS settings: set CAM_SERVER_PROTOCOL=tls and a 64-hex CAM_SERVER_FINGERPRINT' }

$GithubUser       = 'abxian'
$GithubRepo       = 'agent-dist'
$GithubBranch     = 'main'
$ShowInfoLogs     = $true

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol =
    [Net.SecurityProtocolType]::Tls12 -bor
    [Net.SecurityProtocolType]::Tls11 -bor
    [Net.SecurityProtocolType]::Tls

$ManifestName = 'version-remotecontrol.json'
$TaskName     = 'RemoteControlAgent'
$script:InstallLogPath = $null

# ── Logging ─────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Msg"
    if ($script:InstallLogPath) { try { Add-Content -LiteralPath $script:InstallLogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {} }
    if (-not $ShowInfoLogs -and $Level -eq 'INFO') { return }
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
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
    try {
        $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec).Content
        if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
        return [string]$content
    }
    catch { return $null }
}
function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower()
}
function Set-IniValuePreserve {
    param([string]$Path,[string]$Section,[string]$Key,[string]$Value)
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Path) { foreach ($line in (Get-Content -LiteralPath $Path)) { [void]$lines.Add([string]$line) } }
    $sectionStart = -1; $sectionEnd = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[([^]]+)\]\s*$') {
            if ($sectionStart -ge 0) { $sectionEnd = $i; break }
            if ($Matches[1] -ieq $Section) { $sectionStart = $i }
        }
    }
    if ($sectionStart -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') { [void]$lines.Add('') }
        [void]$lines.Add("[$Section]"); [void]$lines.Add("$Key=$Value")
    } else {
        $keyIndex = -1
        for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
            if ($lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) { $keyIndex = $i; break }
        }
        if ($keyIndex -ge 0) { $lines[$keyIndex] = "$Key=$Value" } else { $lines.Insert($sectionEnd, "$Key=$Value") }
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
}
function Remove-IniSection {
    param([string]$Path,[string]$Section)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $lines = @(Get-Content -LiteralPath $Path)
    $result = [System.Collections.Generic.List[string]]::new()
    $skip = $false
    foreach ($line in $lines) {
        if ([string]$line -match '^\s*\[([^]]+)\]\s*$') { $skip = $Matches[1] -ieq $Section }
        if (-not $skip) { [void]$result.Add([string]$line) }
    }
    Set-Content -LiteralPath $Path -Value $result -Encoding ASCII
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
            $owner = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
            $sid = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid
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

# InteractiveToken tasks can be registered successfully yet refuse an
# immediate session-0 start with 0x800710E0.  SYSTEM therefore launches the
# image with the logged-on user's primary token; the task remains the normal
# autostart mechanism for future logons.
function Initialize-InteractiveProcessLauncher {
    if ('CamInstaller.UserSessionProcess' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace CamInstaller {
    public static class UserSessionProcess {
        private const uint MAXIMUM_ALLOWED = 0x02000000;
        private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        private const uint CREATE_NO_WINDOW = 0x08000000;
        private enum TOKEN_TYPE { TokenPrimary = 1, TokenImpersonation }
        private enum SECURITY_IMPERSONATION_LEVEL {
            SecurityAnonymous, SecurityIdentification,
            SecurityImpersonation, SecurityDelegation
        }
        private enum TOKEN_ELEVATION_TYPE { Default = 1, Full, Limited }
        [StructLayout(LayoutKind.Sequential)]
        private struct TOKEN_LINKED_TOKEN { public IntPtr LinkedToken; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO {
            public int cb;
            public string lpReserved, lpDesktop, lpTitle;
            public uint dwX, dwY, dwXSize, dwYSize;
            public uint dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2;
            public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION {
            public IntPtr hProcess, hThread;
            public uint dwProcessId, dwThreadId;
        }
        [DllImport("Wtsapi32.dll", SetLastError = true)]
        private static extern bool WTSQueryUserToken(uint sessionId, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool DuplicateTokenEx(IntPtr existingToken, uint desiredAccess,
            IntPtr tokenAttributes, SECURITY_IMPERSONATION_LEVEL level,
            TOKEN_TYPE tokenType, out IntPtr newToken);
        [DllImport("advapi32.dll", EntryPoint = "GetTokenInformation", SetLastError = true)]
        private static extern bool GetTokenElevationType(IntPtr token, int tokenInformationClass,
            out TOKEN_ELEVATION_TYPE tokenInformation, int tokenInformationLength, out int returnLength);
        [DllImport("advapi32.dll", EntryPoint = "GetTokenInformation", SetLastError = true)]
        private static extern bool GetLinkedToken(IntPtr token, int tokenInformationClass,
            out TOKEN_LINKED_TOKEN tokenInformation, int tokenInformationLength, out int returnLength);
        [DllImport("userenv.dll", SetLastError = true)]
        private static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inherit);
        [DllImport("userenv.dll", SetLastError = true)]
        private static extern bool DestroyEnvironmentBlock(IntPtr environment);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CreateProcessAsUser(IntPtr token, string applicationName,
            StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes,
            bool inheritHandles, uint creationFlags, IntPtr environment, string currentDirectory,
            ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static int Start(uint sessionId, string executable, string arguments, string workingDirectory) {
            IntPtr userToken = IntPtr.Zero, linkedToken = IntPtr.Zero;
            IntPtr primaryToken = IntPtr.Zero, environment = IntPtr.Zero;
            PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
            try {
                if (!WTSQueryUserToken(sessionId, out userToken))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "WTSQueryUserToken failed");
                IntPtr sourceToken = userToken;
                TOKEN_ELEVATION_TYPE elevationType;
                int returned;
                if (GetTokenElevationType(userToken, 18, out elevationType, sizeof(int), out returned) &&
                        elevationType == TOKEN_ELEVATION_TYPE.Limited) {
                    TOKEN_LINKED_TOKEN linked;
                    if (GetLinkedToken(userToken, 19, out linked, IntPtr.Size, out returned)) {
                        linkedToken = linked.LinkedToken;
                        sourceToken = linkedToken;
                    }
                }
                if (!DuplicateTokenEx(sourceToken, MAXIMUM_ALLOWED, IntPtr.Zero,
                        SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation,
                        TOKEN_TYPE.TokenPrimary, out primaryToken))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "DuplicateTokenEx failed");
                if (!CreateEnvironmentBlock(out environment, primaryToken, false))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateEnvironmentBlock failed");
                STARTUPINFO si = new STARTUPINFO();
                si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
                si.lpDesktop = @"winsta0\default";
                StringBuilder command = new StringBuilder("\"" + executable + "\"");
                if (!String.IsNullOrWhiteSpace(arguments)) command.Append(" ").Append(arguments);
                if (!CreateProcessAsUser(primaryToken, executable, command, IntPtr.Zero, IntPtr.Zero,
                        false, CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW, environment,
                        workingDirectory, ref si, out pi))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessAsUser failed");
                return checked((int)pi.dwProcessId);
            } finally {
                if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
                if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
                if (environment != IntPtr.Zero) DestroyEnvironmentBlock(environment);
                if (primaryToken != IntPtr.Zero) CloseHandle(primaryToken);
                if (linkedToken != IntPtr.Zero) CloseHandle(linkedToken);
                if (userToken != IntPtr.Zero) CloseHandle(userToken);
            }
        }
    }
}
'@
}

function Start-InteractiveAgentProcess {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string]$Arguments,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [Parameter(Mandatory=$true)]$TargetUser
    )
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($currentSid -eq $TargetUser.Sid) {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments `
            -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru
        return [pscustomobject]@{ Pid = $process.Id; Process = $process; Mode = 'current-user' }
    }
    if (-not $isSystem) { throw 'Interactive process launch requires the target user or SYSTEM.' }
    Initialize-InteractiveProcessLauncher
    $pidValue = [CamInstaller.UserSessionProcess]::Start(
        [uint32]$TargetUser.SessionId, $FilePath, $Arguments, $WorkingDirectory)
    return [pscustomobject]@{ Pid = $pidValue; Process = $null; Mode = 'system-user-token' }
}

$user = Get-InteractiveUser
if ($user) {
    Write-Log "目标交互用户: $($user.Account) (SID=$($user.Sid), Session=$($user.SessionId))" 'WARN'
} else {
    # Unattended-deploy fallback: no desktop user yet (golden-image install,
    # PXE flow, etc). Install a task triggered "at logon of ANY user" with
    # BUILTIN\Users as the principal — whoever logs in first picks it up.
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

# ── Install dir ─────────────────────────────────────────────────────────────
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
$script:InstallLogPath = Join-Path $InstallDir 'install-remotecontrolagent.log'
Write-Log "==== installer start: source=$chosen manifest=$manifestUrl ====" 'WARN'
$versionFile  = Join-Path $InstallDir 'installed.version'
$localVersion = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '' }
$agentExe     = Join-Path $InstallDir 'RemoteControlAgent.exe'
$oldTask      = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$oldTaskXml   = if ($oldTask) { Export-ScheduledTask -TaskName $TaskName } else { $null }
$oldTaskExecute = if ($oldTask) { [string](@($oldTask.Actions)[0].Execute) } else { '' }
$oldTaskArguments = if ($oldTask) { [string](@($oldTask.Actions)[0].Arguments) } else { '' }
$safeVersion  = ([string]$manifest.version -replace '[^0-9A-Za-z._-]', '_')
$legacyInstallDir = Join-Path $env:ProgramData 'RemoteControlAgent'
$legacyService = Get-CimInstance Win32_Service -Filter "Name='RemoteControlAgent'" -ErrorAction SilentlyContinue
$legacyServiceExe = ''
if ($legacyService -and $legacyService.PathName) {
    if ([string]$legacyService.PathName -match '^\s*"([^"]+)"') { $legacyServiceExe = $Matches[1] }
    elseif ([string]$legacyService.PathName -match '^\s*([^\s]+\.exe)') { $legacyServiceExe = $Matches[1] }
}
$runtimeDirs = @($InstallDir,$legacyInstallDir)
if ($legacyServiceExe) { $runtimeDirs += (Split-Path $legacyServiceExe -Parent) }
$runtimeDirs = @($runtimeDirs | Where-Object { $_ } | Select-Object -Unique)
$allRunningImages = @(Get-CimInstance Win32_Process -Filter "Name like 'RemoteControlAgent%.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and (Split-Path $_.ExecutablePath -Parent) -in $runtimeDirs })
$existingRuntime = $allRunningImages | Select-Object -First 1
$hasExistingRuntime = [bool]($oldTask -or $existingRuntime -or $legacyService)
$isFirstInstall = -not $hasExistingRuntime
$candidateExe = if ($hasExistingRuntime) { Join-Path $InstallDir "RemoteControlAgent-$safeVersion.exe" } else { $agentExe }
$candidateMsQuic = if ($hasExistingRuntime) { Join-Path $InstallDir "msquic-$safeVersion.dll" } else { Join-Path $InstallDir 'msquic.dll' }
$runningLegacyImage = $allRunningImages | Where-Object { $_.ExecutablePath -ne $candidateExe } | Select-Object -First 1
$oldRuntimeExecute = if ($existingRuntime) { [string]$existingRuntime.ExecutablePath } elseif ($legacyServiceExe) { $legacyServiceExe } else { $oldTaskExecute }
$taskExePath = if ($oldTask) { [string](@($oldTask.Actions)[0].Execute) } else { '' }
$activeExePath = if ($existingRuntime) { [string]$existingRuntime.ExecutablePath } elseif ($legacyServiceExe) { $legacyServiceExe } else { $taskExePath }
$actualVersion = if ($activeExePath -and (Split-Path $activeExePath -Leaf) -match '-v?([0-9]+(?:\.[0-9]+){1,3})\.exe$') { $Matches[1] } elseif ($activeExePath -and (Test-Path -LiteralPath $activeExePath)) { (([Diagnostics.FileVersionInfo]::GetVersionInfo($activeExePath).ProductVersion -replace ',','.').TrimEnd('.0')) } else { '' }
$remoteExe = @($manifest.files | Where-Object { $_.name -ieq 'RemoteControlAgent.exe' } | Select-Object -First 1)
$remoteExeHash = if ($remoteExe -and $remoteExe[0].sha256) { ([string]$remoteExe[0].sha256).ToLower() } else { '' }
$activeHash = if ($activeExePath -and (Test-Path -LiteralPath $activeExePath)) { Get-FileSha256 $activeExePath } else { '' }
$activeIsCurrent = [bool](($remoteExeHash -and $activeHash -eq $remoteExeHash) -or (-not $remoteExeHash -and $actualVersion -eq ([string]$manifest.version).TrimStart('v')))
try {
    if ($actualVersion -and ([version]$actualVersion -gt [version](([string]$manifest.version).TrimStart('v')))) {
        Fail "Refusing stale manifest downgrade: active=$actualVersion manifest=$($manifest.version) source=$chosen" 8
    }
} catch [System.Management.Automation.PipelineStoppedException] { throw } catch {}
$needsHandover = [bool]($user -and $hasExistingRuntime -and
    (-not $activeIsCurrent -or $runningLegacyImage -or $legacyService))
$installState = if (-not $hasExistingRuntime) { 'first-install' } elseif ($activeIsCurrent -and $existingRuntime) { 'current' } elseif ($activeIsCurrent) { 'repair-start' } else { 'upgrade' }
Write-Log "Detected state: mode=$installState task=$($oldTask.State) configured='$taskExePath' running='$($existingRuntime.ExecutablePath)' actual='$actualVersion' marker='$localVersion' current=$activeIsCurrent" 'WARN'

# Clean up the install.uuid file an earlier version of this script wrote;
# no longer used. (Safe to leave behind, just tidiness.)
Remove-Item (Join-Path $InstallDir 'install.uuid') -Force -ErrorAction SilentlyContinue

Write-Log "安装目录:  $InstallDir" 'WARN'
Write-Log "Task 名:   $TaskName" 'WARN'
Write-Log "本地版本:  '$localVersion'  远端版本: '$($manifest.version)'" 'WARN'

# ── Clean up legacy footprints — service / Run keys / old tasks ─────────────
$legacyServiceWasRunning = [bool]($legacyService -and $legacyService.State -eq 'Running')
if ($legacyService) {
    Write-Log '检测到旧 Windows 服务 RemoteControlAgent；候选认证成功前保持运行' 'WARN'
    if (-not $user) {
        Fail '没有交互用户，不能把旧 RemoteControl 服务安全迁移到桌面任务；旧服务保持不变，请在用户登录后重试' 42
    }
}

# Old HKLM Run entry that earlier versions of this installer may have left
try {
    Remove-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'RemoteControlAgent' -Force -ErrorAction SilentlyContinue
} catch {}

# Old HKU\<SID>\Run entry from the previous SID-based installer.
# 遍历所有 user profile (Win32_UserProfile), 不只是当前已加载 hive 的用户.
# 离线用户的 hive 用 reg load / reg unload 临时挂上, 否则他们登录时还会从 Run
# 键拉起第二份 agent (前一次出现过 2 个实例同时跑的 bug).
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
            $cur = (Get-ItemProperty -Path $runKey -Name 'RemoteControlAgent' -ErrorAction SilentlyContinue).RemoteControlAgent
            if ($cur) {
                Remove-ItemProperty -Path $runKey -Name 'RemoteControlAgent' -Force -ErrorAction SilentlyContinue
                Write-Log "清理 HKU\$sid\...\Run\RemoteControlAgent (旧 install 残留)" 'WARN'
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

# Old scheduled tasks: the fixed name + any legacy UUID-suffixed name
# left over from earlier versions of this script.
foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    if ($t.TaskName -ne $TaskName -and $t.TaskName -like 'RemoteControlAgent_*') {
        Write-Log "删除旧任务: $($t.TaskName)" 'WARN'
        try { Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false } catch {}
    }
}

# Keep the current task/process alive until a candidate has authenticated.

$iniPath = Join-Path $InstallDir 'remotecontrolagent.ini'
if (-not (Test-Path -LiteralPath $iniPath)) {
    $legacyIniCandidates = @()
    foreach ($exe in @($activeExePath, $oldTaskExecute, $legacyServiceExe)) {
        if ($exe) { $legacyIniCandidates += (Join-Path (Split-Path $exe -Parent) 'remotecontrolagent.ini') }
    }
    $legacyIniCandidates += (Join-Path $legacyInstallDir 'remotecontrolagent.ini')
    $legacyIni = $legacyIniCandidates | Where-Object {
        $_ -and $_ -ne $iniPath -and (Test-Path -LiteralPath $_)
    } | Select-Object -First 1
    if ($legacyIni) {
        Copy-Item -LiteralPath $legacyIni -Destination $iniPath -Force
        Write-Log "已迁移旧 remotecontrolagent.ini: $legacyIni -> $iniPath（保留 InstanceId）" 'WARN'
    }
}

# ── Download / verify files (skip ini + opencv on hash-drift) ───────────────
$hasLocalIni = Test-Path (Join-Path $InstallDir 'remotecontrolagent.ini')
$changed = $false
foreach ($f in $manifest.files) {
    $name = $f.name
    $remoteHash = if ($f.PSObject.Properties.Name -contains 'sha256') { $f.sha256 } else { $null }
    $dst = if ($name -ieq 'RemoteControlAgent.exe') { $candidateExe } elseif ($name -ieq 'msquic.dll') { $candidateMsQuic } else { Join-Path $InstallDir $name }
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
if (-not (Test-Path $candidateExe)) { Fail "候选 RemoteControlAgent 不存在: $candidateExe" 32 }
if (($manifest.files.name -contains 'msquic.dll') -and -not (Test-Path $candidateMsQuic)) { Fail "候选 MsQuic 不存在: $candidateMsQuic" 32 }

# ── Write fresh ini (server config only) ────────────────────────────────────
$iniPath = Join-Path $InstallDir 'remotecontrolagent.ini'
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

[QUIC]
Enabled=1
"@
if (-not (Test-Path $iniPath)) {
    Set-Content -Path $iniPath -Value $iniContent -Encoding ASCII
    Write-Log "首次写入 remotecontrolagent.ini: Host=$h Port=$p" 'WARN'
} else {
    Write-Log '保留现有 remotecontrolagent.ini（InstanceId、迁移地址和画质状态不变）' 'WARN'
}
$explicitServer = $isFirstInstall -or [bool]$env:RCA_SERVER_IP -or [bool]$env:RCA_SERVER_PORT -or
    ($null -ne $env:RCA_SERVER_PASSWORD) -or [bool]$env:CAM_SERVER_PROTOCOL -or
    ($null -ne $env:CAM_SERVER_FINGERPRINT)
if ($explicitServer) {
    Set-IniValuePreserve $iniPath 'Server' 'Host' $h
    Set-IniValuePreserve $iniPath 'Server' 'Port' ([string]$p)
    Set-IniValuePreserve $iniPath 'Server' 'Password' $w
    Set-IniValuePreserve $iniPath 'Server' 'Protocol' $ServerProtocol
    Set-IniValuePreserve $iniPath 'Server' 'CertificateFingerprint' $CertificateFingerprint
    Write-Log "Applied endpoint to existing remotecontrolagent.ini: $ServerProtocol $h`:$p (identity preserved)" 'WARN'
}
if ($env:CAM_DELIVERY_BASE) { Set-IniValuePreserve $iniPath 'Bootstrap' 'ConfigUrl' $env:CAM_DELIVERY_BASE.TrimEnd('/') }
if ($env:CAM_DEVICE_TOKEN) { Set-IniValuePreserve $iniPath 'Identity' 'DeviceToken' $env:CAM_DEVICE_TOKEN }
Set-IniValuePreserve $iniPath 'QUIC' 'Enabled' '1'
Remove-IniSection $iniPath 'Update'

# ── Create the scheduled task (logon + HIGHEST privilege) ───────────────────
#  Two modes:
#    A) Interactive user detected → trigger at logon of THAT user, principal
#       = that user. Most precise; what we want for "装机当下就有人坐在
#       前面" 的场景.
#    B) No user detected (unattended) → trigger at logon of ANY user, principal
#       = BUILTIN\Users group (SID S-1-5-32-545). Whoever logs in first
#       picks it up. Useful for golden-image deployment.
#  Both modes use RunLevel Highest so the agent has admin privileges in the
#  user's session — sees UAC, can SendInput to elevated windows, captures
#  the actual desktop instead of session 0's black screen.
$action  = New-ScheduledTaskAction `
            -Execute $candidateExe `
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
    # AtLogOn without -User fires for any user; BUILTIN\Users SID as
    # principal means the task runs as whoever logged in.
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal `
                    -GroupId 'S-1-5-32-545' `
                    -RunLevel Highest
    $modeDesc  = "atLogon[ANY USER], BUILTIN\Users, RunLevel=Highest"
}
$watchdogTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$taskTriggers = @($trigger, $watchdogTrigger)

function Wait-ReadyFile {
    param([string]$Path,[int]$TimeoutSeconds = 45)
    for ($i = 0; $i -lt ($TimeoutSeconds * 10); $i++) {
        if (Test-Path -LiteralPath $Path) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

$handoverTask = $null
$candidateProcess = $null
$candidateProcessId = $null
$serviceReady = $null
if ($needsHandover) {
    $token = [Guid]::NewGuid().ToString('N')
    $handoverTask = "$TaskName-Handover-$token"
    $candidateReady = Join-Path $InstallDir ".handover-remote-candidate-$token.ready"
    $serviceReady = Join-Path $InstallDir ".handover-remote-task-$token.ready"
    Remove-Item -LiteralPath $candidateReady,$serviceReady -Force -ErrorAction SilentlyContinue
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $runCandidateDirect = [bool]($user -and (($currentSid -eq $user.Sid) -or $isSystem))
    if ($runCandidateDirect) {
        Write-Log '直接在目标桌面会话启动候选（绕过可能拒绝按需启动的 Task Scheduler）' 'WARN'
        $candidateLaunch = Start-InteractiveAgentProcess -FilePath $candidateExe `
            -Arguments ('-handover-once -handover-ready "{0}" -run' -f $candidateReady) `
            -WorkingDirectory $InstallDir -TargetUser $user
        $candidateProcess = $candidateLaunch.Process
        $candidateProcessId = $candidateLaunch.Pid
        Write-Log "候选启动模式=$($candidateLaunch.Mode), PID=$candidateProcessId, Session=$($user.SessionId)" 'WARN'
    } else {
        $candidateAction = New-ScheduledTaskAction -Execute $candidateExe `
            -Argument ('-handover-once -handover-ready "{0}" -run' -f $candidateReady) `
            -WorkingDirectory $InstallDir
        Register-ScheduledTask -TaskName $handoverTask -Action $candidateAction `
            -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $handoverTask
    }
    Write-Log "候选诊断日志: $candidateReady.log；等待认证最长 45 秒" 'WARN'
    if (-not (Wait-ReadyFile -Path $candidateReady)) {
        if ($runCandidateDirect) {
            $candidateRunning = Get-Process -Id $candidateProcessId -ErrorAction SilentlyContinue
            $candidateCode = if ($candidateProcess -and $candidateProcess.HasExited) { $candidateProcess.ExitCode } elseif ($candidateRunning) { 'running' } else { 'exited' }
            Write-Log "Candidate diagnostics: PID=$candidateProcessId State=$candidateCode Log=$candidateReady.log" 'ERROR'
        } else {
            $candidateInfo = Get-ScheduledTaskInfo -TaskName $handoverTask -ErrorAction SilentlyContinue
            $candidateState = (Get-ScheduledTask -TaskName $handoverTask -ErrorAction SilentlyContinue).State
            Write-Log "Candidate task diagnostics: State=$candidateState LastTaskResult=$($candidateInfo.LastTaskResult) Log=$candidateReady.log" 'ERROR'
        }
        if (Test-Path -LiteralPath "$candidateReady.log") {
            Get-Content -LiteralPath "$candidateReady.log" -Tail 40 | ForEach-Object { Write-Log "candidate> $_" 'ERROR' }
        }
        if (-not $runCandidateDirect) { Unregister-ScheduledTask -TaskName $handoverTask -Confirm:$false -ErrorAction SilentlyContinue }
        if ($candidateProcessId) { Stop-Process -Id $candidateProcessId -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $candidateReady,$serviceReady -Force -ErrorAction SilentlyContinue
        Fail "Remote candidate did not receive Server handover confirmation. Old task remains. See $script:InstallLogPath and $candidateReady.log" 40
    }
    if ($legacyService) {
        Write-Log '候选已认证，停止旧 Windows 服务 RemoteControlAgent' 'WARN'
        try { & sc.exe stop RemoteControlAgent | Out-Null } catch {}
        for ($i = 0; $i -lt 30; $i++) {
            $legacyState = (Get-CimInstance Win32_Service -Filter "Name='RemoteControlAgent'" -ErrorAction SilentlyContinue).State
            if (-not $legacyState -or $legacyState -eq 'Stopped') { break }
            Start-Sleep -Milliseconds 500
        }
    }
    $action = New-ScheduledTaskAction -Execute $candidateExe `
        -Argument ('-handover-ready "{0}" -run' -f $serviceReady) `
        -WorkingDirectory $InstallDir
}

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $taskTriggers `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null
Write-Log "已注册 Scheduled Task: $TaskName ($modeDesc)" 'WARN'

if ($needsHandover) {
    Get-CimInstance Win32_Process -Filter "Name like 'RemoteControlAgent%.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ne $candidateExe -and
                       (Split-Path $_.ExecutablePath -Parent) -in $runtimeDirs } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    # Avoid a candidate/permanent-process race for the same InstanceId on
    # slower relays. The candidate has already proved the new image and config;
    # stop it before the final task performs its authenticated connection.
    if (-not $runCandidateDirect) { Stop-ScheduledTask -TaskName $handoverTask -ErrorAction SilentlyContinue }
    for ($i = 0; $i -lt 100; $i++) {
        $candidateRunning = Get-CimInstance Win32_Process -Filter "Name like 'RemoteControlAgent%.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -eq $candidateExe }
        if (-not $candidateRunning) { break }
        Start-Sleep -Milliseconds 100
    }
    Get-CimInstance Win32_Process -Filter "Name like 'RemoteControlAgent%.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $candidateExe } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $finalProcess = $null
    if ($runCandidateDirect) {
        Write-Log '直接启动正式新进程；计划任务保留用于后续登录自启' 'WARN'
        $finalLaunch = Start-InteractiveAgentProcess -FilePath $candidateExe `
            -Arguments ('-handover-ready "{0}" -run' -f $serviceReady) `
            -WorkingDirectory $InstallDir -TargetUser $user
        $finalProcess = $finalLaunch.Process
        Write-Log "正式进程启动模式=$($finalLaunch.Mode), PID=$($finalLaunch.Pid), Session=$($user.SessionId)" 'WARN'
    } else {
        Start-ScheduledTask -TaskName $TaskName
    }
    if (-not (Wait-ReadyFile -Path $serviceReady)) {
        $failedTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $failedInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        $failedPids = @(Get-CimInstance Win32_Process -Filter "Name like 'RemoteControlAgent%.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -eq $candidateExe } |
            ForEach-Object { $_.ProcessId }) -join ','
        Write-Log "Final RemoteControlAgent diagnostics: State=$($failedTask.State), LastTaskResult=$($failedInfo.LastTaskResult), PIDs=$failedPids" 'ERROR'
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Get-CimInstance Win32_Process -Filter "Name like 'RemoteControlAgent%.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -eq $candidateExe } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        if ($oldTaskXml) {
            Register-ScheduledTask -TaskName $TaskName -Xml $oldTaskXml -Force | Out-Null
        } elseif ($oldRuntimeExecute -and -not $legacyService) {
            $rollbackAction = New-ScheduledTaskAction -Execute $oldRuntimeExecute -Argument '-run' `
                -WorkingDirectory (Split-Path $oldRuntimeExecute -Parent)
            Register-ScheduledTask -TaskName $TaskName -Action $rollbackAction -Trigger $taskTriggers `
                -Principal $principal -Settings $settings -Force | Out-Null
        }
        if ($legacyService) {
            if ($legacyServiceWasRunning) { try { & sc.exe start RemoteControlAgent | Out-Null } catch {} }
        } elseif ($runCandidateDirect -and $oldRuntimeExecute) {
            $rollbackArguments = if ($oldTaskArguments) { $oldTaskArguments } else { '-run' }
            Start-InteractiveAgentProcess -FilePath $oldRuntimeExecute -Arguments $rollbackArguments `
                -WorkingDirectory (Split-Path $oldRuntimeExecute -Parent) -TargetUser $user | Out-Null
        } else {
            Start-ScheduledTask -TaskName $TaskName
        }
        if (-not $runCandidateDirect) { Unregister-ScheduledTask -TaskName $handoverTask -Confirm:$false -ErrorAction SilentlyContinue }
        Fail "New RemoteControlAgent task did not authenticate; restored old task. Check $iniPath" 41
    }
    if (-not $runCandidateDirect) { Unregister-ScheduledTask -TaskName $handoverTask -Confirm:$false -ErrorAction SilentlyContinue }
    if ($legacyService) {
        try { & sc.exe delete RemoteControlAgent | Out-Null } catch {}
        Write-Log '新进程认证完成，已删除旧 Windows 服务 RemoteControlAgent' 'WARN'
    }
    Remove-Item -LiteralPath $candidateReady,$serviceReady -Force -ErrorAction SilentlyContinue
    Write-Log 'RemoteControlAgent 新旧进程无感交接完成' 'WARN'
}

# Fire once now ONLY if we have a target user logged in — otherwise there's
# no session to start the agent into. The task will fire naturally on
# the next login.
if ($user -and -not $needsHandover) {
    try {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if (($currentSid -eq $user.Sid) -or $isSystem) {
            Start-InteractiveAgentProcess -FilePath $candidateExe -Arguments '-run' `
                -WorkingDirectory $InstallDir -TargetUser $user | Out-Null
        } else {
            Start-ScheduledTask -TaskName $TaskName
        }
        Start-Sleep -Seconds 2
    } catch {
        Write-Log "立即触发任务失败, 用户下次登录会自动起。错误: $($_.Exception.Message)" 'WARN'
    }
} elseif (-not $user) {
    Write-Log "无人值守模式: agent 将在下一个用户登录时自动起动" 'WARN'
}

Set-Content -Path $versionFile -Value $manifest.version -Encoding ASCII

# ── Sanity check (only meaningful if we expected to start one) ──────────────
if ($user) {
    $running = Get-CimInstance Win32_Process -Filter "Name like 'RemoteControlAgent%.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and (Split-Path $_.ExecutablePath -Parent) -eq $InstallDir }
    if ($running) {
        Write-Log "RemoteControlAgent 已在用户 session 启动 (PID=$($running[0].ProcessId))" 'WARN'
    } else {
        Write-Log "未检测到 RemoteControlAgent 进程, 等几秒再 Get-Process 看看 — 任务可能正在加载 OpenCV DLL" 'WARN'
    }
}

Write-Host ""
Write-Host "  RemoteControlAgent 已安装  " -ForegroundColor Green -BackgroundColor Black
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
