# 在同目录放好 Agent.exe / agent.ini / opencv_world4100.dll 后运行,
# 自动生成 version.json (带 SHA256). 新版本只需提升 version 字段。
[CmdletBinding()]
param(
    [string]$Version = (Get-Date -Format 'yyyy.MM.dd.HHmm'),
    [string[]]$Files = @('Agent.exe','agent.ini','opencv_world4100.dll'),
    [string]$OutFile = 'version.json'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$entries = foreach ($f in $Files) {
    $p = Join-Path $here $f
    if (-not (Test-Path $p)) { throw "缺少文件: $p" }
    [pscustomobject]@{
        name   = $f
        sha256 = (Get-FileHash -Algorithm SHA256 $p).Hash.ToLower()
    }
}
$obj = [ordered]@{ version = $Version; files = $entries }
$obj | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $here $OutFile) -Encoding UTF8
Write-Host "已生成 $OutFile (version=$Version)"
