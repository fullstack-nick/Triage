[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$statePath = Get-TriageLocalPath -ChildPath 'run-state.json'
if (-not (Test-Path -LiteralPath $statePath)) {
    Write-Host 'Triage has no recorded application processes.'
    exit 0
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$root = Get-TriageRoot
foreach ($entry in $state.processes) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($entry.pid)" -ErrorAction SilentlyContinue
    if ($null -eq $process) { continue }

    $commandLine = [string]$process.CommandLine
    $executableName = [System.IO.Path]::GetFileNameWithoutExtension([string]$process.ExecutablePath)
    $expectedExecutableName = [System.IO.Path]::GetFileNameWithoutExtension([string]$entry.executable)
    if ($executableName -ine $expectedExecutableName -or -not $commandLine.Contains([string]$entry.marker) -or -not $commandLine.Contains($root)) {
        throw "Refusing to stop PID $($entry.pid): it no longer matches the recorded Triage process."
    }
    Stop-Process -Id ([int]$entry.pid) -Force
}

Remove-Item -LiteralPath $statePath -Force
Write-Host 'Triage application processes stopped. SQL data remains available.' -ForegroundColor Green
