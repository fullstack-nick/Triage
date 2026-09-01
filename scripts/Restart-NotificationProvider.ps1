[CmdletBinding()]
param([switch] $TestMode)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$root = Get-TriageRoot
$statePath = Get-TriageLocalPath -ChildPath 'run-state.json'
if (-not (Test-Path -LiteralPath $statePath)) { throw 'Triage is not running.' }

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$entry = $state.processes | Where-Object name -eq 'NotificationApi'
if ($null -eq $entry) { throw 'The notification provider is not recorded in local run state.' }

$process = Get-CimInstance Win32_Process -Filter "ProcessId = $($entry.pid)" -ErrorAction SilentlyContinue
if ($null -eq $process -or -not ([string]$process.CommandLine).Contains([string]$entry.marker) -or -not ([string]$process.CommandLine).Contains($root)) {
    throw 'Refusing provider restart because the recorded process identity no longer matches.'
}
Stop-Process -Id ([int]$entry.pid) -Force

$settings = Read-TriageEnvironment
Set-TriageProcessEnvironment -Settings $settings
if ($TestMode) { [Environment]::SetEnvironmentVariable('TRIAGE_PROVIDER_TEST_MODE', '1', 'Process') }

$logDirectory = Get-TriageLocalPath -ChildPath 'logs'
$apiDll = Join-Path $root 'src\NotificationApi\bin\Release\net10.0\Triage.NotificationApi.dll'
$apiProcess = Start-Process -FilePath 'dotnet' -ArgumentList @("`"$apiDll`"") -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDirectory 'notification-api.out.log') -RedirectStandardError (Join-Path $logDirectory 'notification-api.err.log') -PassThru
try {
    Wait-TriageHttp -Uri 'http://127.0.0.1:5071/health' | Out-Null
} catch {
    Stop-Process -Id $apiProcess.Id -Force -ErrorAction SilentlyContinue
    throw
}

$entry.pid = $apiProcess.Id
$state.startedAtUtc = [DateTime]::UtcNow.ToString('o')
$state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
Write-Host 'Triage notification provider restarted with its durable receipt store intact.' -ForegroundColor Green
