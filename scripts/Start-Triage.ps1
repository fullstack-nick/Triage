[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$root = Get-TriageRoot
$statePath = Get-TriageLocalPath -ChildPath 'run-state.json'
if (Test-Path -LiteralPath $statePath) {
    throw 'A local run-state file already exists. Run scripts/Stop-Triage.ps1 before starting again.'
}

& (Join-Path $PSScriptRoot 'Verify-Prerequisites.ps1') -SkipPortCheck
foreach ($port in @(5070, 5071)) {
    if (-not (Test-TriagePortAvailable -Port $port)) { throw "Port $port is already in use." }
}

$settings = Read-TriageEnvironment
Set-TriageProcessEnvironment -Settings $settings
$environmentPath = Get-TriageLocalPath -ChildPath 'triage.env'

Push-Location $root
try {
    & docker compose --env-file $environmentPath up -d sqlserver
    if ($LASTEXITCODE -ne 0) { throw 'Unable to start the local SQL container.' }
    Wait-TriageSql

    $logDirectory = Get-TriageLocalPath -ChildPath 'logs'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $apiDll = Join-Path $root 'src\NotificationApi\bin\Release\net10.0\Triage.NotificationApi.dll'
    if (-not (Test-Path -LiteralPath $apiDll)) { throw 'The API build is missing. Run scripts/Initialize-Triage.ps1.' }

    $apiProcess = Start-Process -FilePath 'dotnet' -ArgumentList @("`"$apiDll`"") -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDirectory 'notification-api.out.log') -RedirectStandardError (Join-Path $logDirectory 'notification-api.err.log') -PassThru
    try {
        Wait-TriageHttp -Uri 'http://127.0.0.1:5071/health' | Out-Null

        $iisConfig = New-TriageIisConfiguration
        $iisArguments = @("/config:`"$iisConfig`"", '/site:Triage')
        $iisProcess = Start-Process -FilePath 'C:\Program Files\IIS Express\iisexpress.exe' -ArgumentList $iisArguments -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDirectory 'iis.out.log') -RedirectStandardError (Join-Path $logDirectory 'iis.err.log') -PassThru
        try {
            Wait-TriageHttp -Uri 'http://127.0.0.1:5070/admin/dev-login.asp' | Out-Null
            Wait-TriageHttp -Uri 'http://127.0.0.1:5070/reviewer/dev-login.aspx' | Out-Null

            @{
                startedAtUtc = [DateTime]::UtcNow.ToString('o')
                root = $root
                processes = @(
                    @{ name = 'NotificationApi'; pid = $apiProcess.Id; executable = 'dotnet'; marker = $apiDll }
                    @{ name = 'IISExpress'; pid = $iisProcess.Id; executable = 'iisexpress.exe'; marker = $iisConfig }
                )
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
        } catch {
            Stop-Process -Id $iisProcess.Id -Force -ErrorAction SilentlyContinue
            throw
        }
    } catch {
        Stop-Process -Id $apiProcess.Id -Force -ErrorAction SilentlyContinue
        throw
    }

    Write-Host 'Triage is running at http://127.0.0.1:5070' -ForegroundColor Green
    Write-Host 'Administrator: admin@aster-vale.example.test'
    Write-Host 'Reviewer: reviewer001@example.test'
    Write-Host "Passwords remain in $environmentPath"
    Write-Host 'Stop with: .\scripts\Stop-Triage.ps1'
} finally {
    Pop-Location
}
