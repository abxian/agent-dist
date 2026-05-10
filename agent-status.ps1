<#
Remote agent health check. IEX friendly.

CN:
  iex (irm http://114.80.36.225:15667/6/agent-status.ps1)

GitHub:
  iex (irm https://raw.githubusercontent.com/abxian/agent-dist/main/agent-status.ps1)

Optional overrides:
  $env:AGENT_HEALTH_SERVER_HOST='110.42.44.89'
  $env:AGENT_HEALTH_SERVER_PORT='9999'
#>

$ErrorActionPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$CnBase = 'http://114.80.36.225:15667/6'
$GithubRaw = 'https://raw.githubusercontent.com/abxian/agent-dist/main'
$ServerHostOverride = $env:AGENT_HEALTH_SERVER_HOST
$ServerPortOverride = $env:AGENT_HEALTH_SERVER_PORT

$ChecksOk = 0
$ChecksWarn = 0
$ChecksBad = 0

function Title([string]$s) {
    Write-Host ""
    Write-Host "==== $s ====" -ForegroundColor Cyan
}

function Check([string]$name, [string]$value, [string]$state) {
    $color = 'Gray'
    if ($state -eq 'OK') { $color = 'Green'; $script:ChecksOk++ }
    elseif ($state -eq 'WARN') { $color = 'Yellow'; $script:ChecksWarn++ }
    elseif ($state -eq 'BAD') { $color = 'Red'; $script:ChecksBad++ }
    Write-Host ("{0,-32} {1}" -f ($name + ':'), $value) -ForegroundColor $color
}

function Read-Ini([string]$path) {
    $map = @{}
    if (-not (Test-Path $path)) { return $map }
    $section = ''
    foreach ($line in Get-Content $path) {
        $s = $line.Trim()
        if (-not $s -or $s.StartsWith(';') -or $s.StartsWith('#')) { continue }
        if ($s.StartsWith('[') -and $s.EndsWith(']')) {
            $section = $s.Substring(1, $s.Length - 2)
            continue
        }
        $idx = $s.IndexOf('=')
        if ($idx -lt 1) { continue }
        $map["$section.$($s.Substring(0,$idx).Trim())"] = $s.Substring($idx + 1).Trim()
    }
    return $map
}

function Remote-Version([string]$url) {
    try {
        return ((Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8).Content | ConvertFrom-Json).version
    } catch { return $null }
}

function Tcp-Test([string]$host, [int]$port) {
    if (-not $host -or $port -le 0) { return $false }
    try {
        $c = New-Object Net.Sockets.TcpClient
        $iar = $c.BeginConnect($host, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(3000, $false)) { $c.Close(); return $false }
        $c.EndConnect($iar)
        $c.Close()
        return $true
    } catch { return $false }
}

function Run-Entries([string]$name) {
    $items = @()
    foreach ($root in @('Registry::HKEY_LOCAL_MACHINE','Registry::HKEY_CURRENT_USER')) {
        $p = "$root\Software\Microsoft\Windows\CurrentVersion\Run"
        $v = (Get-ItemProperty -Path $p -Name $name -ErrorAction SilentlyContinue).$name
        if ($v) { $items += [pscustomobject]@{ Path=$p; Value=$v } }
    }
    foreach ($sidKey in Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue) {
        $sid = $sidKey.PSChildName
        if ($sid -notmatch '^S-1-5-21-' -or $sid.EndsWith('_Classes')) { continue }
        $p = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Run"
        $v = (Get-ItemProperty -Path $p -Name $name -ErrorAction SilentlyContinue).$name
        if ($v) { $items += [pscustomobject]@{ Path=$p; Value=$v } }
    }
    return $items
}

function Check-App($title, $dir, $exeName, $iniName, $manifest, $serviceName, $runName) {
    Title $title
    Check 'Install dir' $dir ($(if (Test-Path $dir) { 'OK' } else { 'BAD' }))

    $exe = Join-Path $dir $exeName
    $ini = Join-Path $dir $iniName
    $verFile = Join-Path $dir 'installed.version'
    $localVer = if (Test-Path $verFile) { (Get-Content $verFile -Raw).Trim() } else { '' }

    Check 'Exe file' $exeName ($(if (Test-Path $exe) { 'OK' } else { 'BAD' }))
    Check 'Ini file' $iniName ($(if (Test-Path $ini) { 'OK' } else { 'WARN' }))
    Check 'Local version' ($(if ($localVer) { $localVer } else { 'missing' })) ($(if ($localVer) { 'OK' } else { 'WARN' }))

    $cn = Remote-Version "$CnBase/$manifest"
    $gh = Remote-Version "$GithubRaw/$manifest"
    Check 'CN version' ($(if ($cn) { $cn } else { 'unreachable' })) ($(if ($cn) { 'OK' } else { 'WARN' }))
    Check 'GitHub version' ($(if ($gh) { $gh } else { 'unreachable' })) ($(if ($gh) { 'OK' } else { 'WARN' }))
    $latest = if ($cn) { $cn } else { $gh }
    if ($localVer -and $latest) {
        Check 'Version state' ($(if ($localVer -eq $latest) { 'current' } else { "$localVer -> $latest available" })) ($(if ($localVer -eq $latest) { 'OK' } else { 'WARN' }))
    }

    $iniData = Read-Ini $ini
    $host = if ($ServerHostOverride) { $ServerHostOverride } else { $iniData['Server.Host'] }
    $portText = if ($ServerPortOverride) { $ServerPortOverride } else { $iniData['Server.Port'] }
    $port = 0
    [void][int]::TryParse([string]$portText, [ref]$port)
    Check 'Server host' ($(if ($host) { $host } else { 'missing' })) ($(if ($host) { 'OK' } else { 'WARN' }))
    Check 'Server port' ($(if ($port -gt 0) { [string]$port } else { 'missing' })) ($(if ($port -gt 0) { 'OK' } else { 'WARN' }))
    if ($host -and $port -gt 0) {
        Check 'Server TCP' "$host`:$port" ($(if (Tcp-Test $host $port) { 'OK' } else { 'BAD' }))
    }

    $procs = @(Get-CimInstance Win32_Process -Filter "Name='$exeName'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) {
        Check 'Process' 'not running' 'BAD'
    } else {
        Check 'Process' "$($procs.Count) running" 'OK'
        foreach ($p in $procs) {
            Write-Host ("  PID={0} Path={1}" -f $p.ProcessId, $p.ExecutablePath) -ForegroundColor Gray
        }
    }

    if ($serviceName) {
        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($svc) { Check "Service $serviceName" "$($svc.Status) / $($svc.StartType)" ($(if ($svc.Status -eq 'Running') { 'OK' } else { 'BAD' })) }
        else { Check "Service $serviceName" 'missing' 'WARN' }
    }

    if ($runName) {
        $runs = @(Run-Entries $runName)
        Check "Run $runName" "$($runs.Count) entries" ($(if ($runs.Count -gt 0) { 'OK' } else { 'WARN' }))
        foreach ($r in $runs) {
            Write-Host ("  {0} = {1}" -f $r.Path, $r.Value) -ForegroundColor Gray
        }
    }
}

Write-Host ""
Write-Host "Remote Agent Health Check" -ForegroundColor Green
Write-Host ("Time: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Gray
Write-Host ("User: {0}" -f ([Security.Principal.WindowsIdentity]::GetCurrent().Name)) -ForegroundColor Gray

Check-App 'Camera Agent' "$env:ProgramData\Agent" 'Agent.exe' 'agent.ini' 'version.json' 'RemoteCameraAgent' 'AgentAutoUpdate'
Check-App 'Screen Agent' "$env:ProgramData\ScreenAgent" 'ScreenAgent.exe' 'screenagent.ini' 'version-screen.json' '' 'ScreenAgent'
Check-App 'Remote Control Agent' "$env:ProgramData\RemoteControlAgent" 'RemoteControlAgent.exe' 'remotecontrolagent.ini' 'version-remotecontrol.json' '' 'RemoteControlAgent'

Title 'Summary'
if ($ChecksBad -gt 0) {
    Write-Host "BAD=$ChecksBad WARN=$ChecksWarn OK=$ChecksOk" -ForegroundColor Red
} elseif ($ChecksWarn -gt 0) {
    Write-Host "WARN=$ChecksWarn OK=$ChecksOk" -ForegroundColor Yellow
} else {
    Write-Host "All checks OK." -ForegroundColor Green
}
