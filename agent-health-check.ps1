<#
Remote Agent health check (IEX friendly)

国内源:
  iex (irm http://114.80.36.225:15667/6/agent-status.ps1)

GitHub:
  iex (irm https://raw.githubusercontent.com/abxian/agent-dist/main/agent-status.ps1)

可选环境变量:
  $env:AGENT_HEALTH_SERVER_HOST = '110.42.44.89'
  $env:AGENT_HEALTH_SERVER_PORT = '9999'
  $env:AGENT_HEALTH_AGENT_DIR   = 'C:\ProgramData\Agent'
  $env:AGENT_HEALTH_SCREEN_DIR  = 'C:\ProgramData\ScreenAgent'
#>

$ErrorActionPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$CnBase = 'http://114.80.36.225:15667/6'
$GithubRaw = 'https://raw.githubusercontent.com/abxian/agent-dist/main'
$AgentDir = if ($env:AGENT_HEALTH_AGENT_DIR) { $env:AGENT_HEALTH_AGENT_DIR } else { "$env:ProgramData\Agent" }
$ScreenDir = if ($env:AGENT_HEALTH_SCREEN_DIR) { $env:AGENT_HEALTH_SCREEN_DIR } else { "$env:ProgramData\ScreenAgent" }
$OverrideHost = $env:AGENT_HEALTH_SERVER_HOST
$OverridePort = $env:AGENT_HEALTH_SERVER_PORT

$script:OkCount = 0
$script:WarnCount = 0
$script:BadCount = 0

function Write-Title {
    param([string]$Text)
    Write-Host ""
    Write-Host "==== $Text ====" -ForegroundColor Cyan
}

function Write-Check {
    param(
        [string]$Name,
        [string]$Value,
        [ValidateSet('OK','WARN','BAD','INFO')]
        [string]$State = 'INFO'
    )
    $color = switch ($State) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'BAD' { 'Red' }
        default { 'Gray' }
    }
    if ($State -eq 'OK') { $script:OkCount++ }
    elseif ($State -eq 'WARN') { $script:WarnCount++ }
    elseif ($State -eq 'BAD') { $script:BadCount++ }
    Write-Host ("{0,-30} {1}" -f ($Name + ':'), $Value) -ForegroundColor $color
}

function Read-Ini {
    param([string]$Path)
    $data = @{}
    if (-not (Test-Path $Path)) { return $data }
    $section = ''
    foreach ($line in Get-Content $Path) {
        $s = $line.Trim()
        if (-not $s -or $s.StartsWith(';') -or $s.StartsWith('#')) { continue }
        if ($s.StartsWith('[') -and $s.EndsWith(']')) {
            $section = $s.Substring(1, $s.Length - 2)
            continue
        }
        $idx = $s.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $s.Substring(0, $idx).Trim()
        $val = $s.Substring($idx + 1).Trim()
        $data["$section.$key"] = $val
    }
    return $data
}

function Get-RemoteVersion {
    param([string]$Url)
    try {
        $raw = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 8).Content
        $j = $raw | ConvertFrom-Json
        return $j.version
    } catch {
        return $null
    }
}

function Get-FileVersionString {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $v = (Get-Item $Path).VersionInfo.ProductVersion
        if (-not $v) { $v = (Get-Item $Path).VersionInfo.FileVersion }
        return $v
    } catch { return $null }
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port)
    if (-not $HostName -or $Port -le 0) { return $false }
    try {
        $client = New-Object Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(3000, $false)
        if (-not $ok) {
            $client.Close()
            return $false
        }
        $client.EndConnect($iar)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

function Get-ProcInfo {
    param([string]$Name, [string]$ExpectedDir)
    $items = @()
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='$Name'" -ErrorAction SilentlyContinue) {
        $same = $false
        if ($p.ExecutablePath) {
            try { $same = ((Split-Path $p.ExecutablePath -Parent) -ieq $ExpectedDir) } catch {}
        }
        $owner = ''
        try {
            $o = $p.GetOwner()
            if ($o.User) { $owner = "$($o.Domain)\$($o.User)" }
        } catch {}
        $items += [pscustomobject]@{
            PID = $p.ProcessId
            Path = $p.ExecutablePath
            CommandLine = $p.CommandLine
            SameDir = $same
            Owner = $owner
        }
    }
    return $items
}

function Get-RunEntries {
    param([string]$ValueName)
    $result = @()
    $paths = @(
        'Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run',
        'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($p in $paths) {
        try {
            $v = (Get-ItemProperty -Path $p -Name $ValueName -ErrorAction SilentlyContinue).$ValueName
            if ($v) { $result += [pscustomobject]@{ Path=$p; Value=$v } }
        } catch {}
    }
    try {
        foreach ($sidKey in Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue) {
            $sid = $sidKey.PSChildName
            if ($sid -notmatch '^S-1-5-21-' -or $sid.EndsWith('_Classes')) { continue }
            $p = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Run"
            $v = (Get-ItemProperty -Path $p -Name $ValueName -ErrorAction SilentlyContinue).$ValueName
            if ($v) { $result += [pscustomobject]@{ Path=$p; Value=$v } }
        }
    } catch {}
    return $result
}

function Check-Source {
    Write-Title '发布源检查'
    $agentCn = Get-RemoteVersion "$CnBase/version.json"
    $agentGh = Get-RemoteVersion "$GithubRaw/version.json"
    $screenCn = Get-RemoteVersion "$CnBase/version-screen.json"
    $screenGh = Get-RemoteVersion "$GithubRaw/version-screen.json"
    Write-Check 'Camera 国内源 version.json' ($(if ($agentCn) { $agentCn } else { '不可达' })) ($(if ($agentCn) { 'OK' } else { 'WARN' }))
    Write-Check 'Camera GitHub version.json' ($(if ($agentGh) { $agentGh } else { '不可达' })) ($(if ($agentGh) { 'OK' } else { 'WARN' }))
    Write-Check 'Screen 国内源 version-screen' ($(if ($screenCn) { $screenCn } else { '不可达' })) ($(if ($screenCn) { 'OK' } else { 'WARN' }))
    Write-Check 'Screen GitHub version-screen' ($(if ($screenGh) { $screenGh } else { '不可达' })) ($(if ($screenGh) { 'OK' } else { 'WARN' }))
}

function Check-Agent {
    param(
        [string]$Title,
        [string]$InstallDir,
        [string]$ExeName,
        [string]$IniName,
        [string]$ManifestName,
        [string]$ServiceName,
        [string]$RunValueName
    )

    Write-Title $Title
    Write-Check '安装目录' $InstallDir ($(if (Test-Path $InstallDir) { 'OK' } else { 'BAD' }))

    $exe = Join-Path $InstallDir $ExeName
    $ini = Join-Path $InstallDir $IniName
    $verFile = Join-Path $InstallDir 'installed.version'
    $localVer = if (Test-Path $verFile) { (Get-Content $verFile -Raw).Trim() } else { '' }
    $fileVer = Get-FileVersionString $exe

    Write-Check "$ExeName 文件" ($(if (Test-Path $exe) { $exe } else { '缺失' })) ($(if (Test-Path $exe) { 'OK' } else { 'BAD' }))
    Write-Check "$IniName 文件" ($(if (Test-Path $ini) { $ini } else { '缺失' })) ($(if (Test-Path $ini) { 'OK' } else { 'WARN' }))
    Write-Check 'installed.version' ($(if ($localVer) { $localVer } else { '无' })) ($(if ($localVer) { 'OK' } else { 'WARN' }))
    if ($fileVer) { Write-Check 'EXE 文件版本' $fileVer 'INFO' }

    $cnVer = Get-RemoteVersion "$CnBase/$ManifestName"
    $ghVer = Get-RemoteVersion "$GithubRaw/$ManifestName"
    Write-Check '国内源版本' ($(if ($cnVer) { $cnVer } else { '不可达' })) ($(if ($cnVer) { 'OK' } else { 'WARN' }))
    Write-Check 'GitHub源版本' ($(if ($ghVer) { $ghVer } else { '不可达' })) ($(if ($ghVer) { 'OK' } else { 'WARN' }))
    $latest = if ($cnVer) { $cnVer } else { $ghVer }
    if ($localVer -and $latest) {
        Write-Check '版本状态' ($(if ($localVer -eq $latest) { '已是最新' } else { "可升级 $localVer -> $latest" })) ($(if ($localVer -eq $latest) { 'OK' } else { 'WARN' }))
    }

    $iniData = Read-Ini $ini
    $host = if ($OverrideHost) { $OverrideHost } else { $iniData['Server.Host'] }
    $portText = if ($OverridePort) { $OverridePort } else { $iniData['Server.Port'] }
    $port = 0
    [void][int]::TryParse([string]$portText, [ref]$port)
    Write-Check '配置 Host' ($(if ($host) { $host } else { '未配置' })) ($(if ($host) { 'OK' } else { 'WARN' }))
    Write-Check '配置 Port' ($(if ($port -gt 0) { $port } else { '未配置/非法' })) ($(if ($port -gt 0) { 'OK' } else { 'WARN' }))
    if ($host -and $port -gt 0) {
        $tcpOk = Test-TcpPort $host $port
        Write-Check 'Server TCP 连通性' "$host`:$port" ($(if ($tcpOk) { 'OK' } else { 'BAD' }))
    }

    $procs = Get-ProcInfo $ExeName $InstallDir
    if ($procs.Count -eq 0) {
        Write-Check '进程状态' "$ExeName 未运行" 'BAD'
    } else {
        $sameCount = @($procs | Where-Object SameDir).Count
        $state = if ($sameCount -gt 0) { 'OK' } else { 'WARN' }
        Write-Check '进程状态' "$($procs.Count) 个进程, 安装目录进程 $sameCount 个" $state
        foreach ($p in $procs) {
            Write-Host ("  PID={0} Owner={1}" -f $p.PID, ($(if ($p.Owner) { $p.Owner } else { 'unknown' }))) -ForegroundColor Gray
            Write-Host ("  Path={0}" -f $p.Path) -ForegroundColor Gray
            if ($p.CommandLine) { Write-Host ("  Cmd ={0}" -f $p.CommandLine) -ForegroundColor Gray }
        }
    }

    if ($ServiceName) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Check "服务 $ServiceName" "$($svc.Status) / $($svc.StartType)" ($(if ($svc.Status -eq 'Running') { 'OK' } else { 'BAD' }))
        } else {
            Write-Check "服务 $ServiceName" '不存在' 'WARN'
        }
    }

    $task = Get-ScheduledTask -TaskName $RunValueName -ErrorAction SilentlyContinue
    if ($task) {
        Write-Check "计划任务 $RunValueName" "$($task.State)" ($(if ($task.State -eq 'Ready' -or $task.State -eq 'Running') { 'OK' } else { 'WARN' }))
    }

    $runs = Get-RunEntries $RunValueName
    if ($runs.Count -gt 0) {
        Write-Check "Run 自启项 $RunValueName" "$($runs.Count) 个" 'OK'
        foreach ($r in $runs) {
            Write-Host ("  {0} = {1}" -f $r.Path, $r.Value) -ForegroundColor Gray
        }
    } elseif (-not $ServiceName) {
        Write-Check "Run 自启项 $RunValueName" '未找到' 'BAD'
    }
}

Write-Host ""
Write-Host "Remote Agent Health Check" -ForegroundColor Green
Write-Host ("Time: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Gray
Write-Host ("User: {0}" -f ([Security.Principal.WindowsIdentity]::GetCurrent().Name)) -ForegroundColor Gray

Check-Source

Check-Agent `
    -Title 'Camera Agent 检查' `
    -InstallDir $AgentDir `
    -ExeName 'Agent.exe' `
    -IniName 'agent.ini' `
    -ManifestName 'version.json' `
    -ServiceName 'RemoteCameraAgent' `
    -RunValueName 'AgentAutoUpdate'

Check-Agent `
    -Title 'ScreenAgent 检查' `
    -InstallDir $ScreenDir `
    -ExeName 'ScreenAgent.exe' `
    -IniName 'screenagent.ini' `
    -ManifestName 'version-screen.json' `
    -ServiceName '' `
    -RunValueName 'ScreenAgent'

Write-Title '结论'
if ($script:BadCount -gt 0) {
    Write-Host "异常: $script:BadCount  警告: $script:WarnCount  正常: $script:OkCount" -ForegroundColor Red
    Write-Host "建议: 先确认 Server 端口已监听, 再重新执行安装/更新脚本。" -ForegroundColor Yellow
} elseif ($script:WarnCount -gt 0) {
    Write-Host "可运行但有警告: $script:WarnCount  正常: $script:OkCount" -ForegroundColor Yellow
} else {
    Write-Host "Agent 服务状态正常。" -ForegroundColor Green
}

