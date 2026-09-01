[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$startedHere = -not (Test-Path -LiteralPath (Get-TriageLocalPath -ChildPath 'run-state.json'))
try {
    & (Join-Path $PSScriptRoot 'Verify-Prerequisites.ps1') -SkipPortCheck
    $root = Get-TriageRoot
    & dotnet restore (Join-Path $root 'src\NotificationApi\Triage.NotificationApi.csproj') --locked-mode
    if ($LASTEXITCODE -ne 0) { throw 'Notification API locked restore failed.' }
    & dotnet build (Join-Path $root 'src\NotificationApi\Triage.NotificationApi.csproj') -c Release --no-restore
    if ($LASTEXITCODE -ne 0) { throw 'Notification API build failed.' }
    & dotnet restore (Join-Path $root 'tests\Triage.NotificationApi.Tests\Triage.NotificationApi.Tests.csproj') --locked-mode
    if ($LASTEXITCODE -ne 0) { throw 'Notification API test locked restore failed.' }
    & dotnet test (Join-Path $root 'tests\Triage.NotificationApi.Tests\Triage.NotificationApi.Tests.csproj') -c Release --no-restore
    if ($LASTEXITCODE -ne 0) { throw 'Notification API xUnit tests failed.' }
    $msbuild = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe'
    & $msbuild (Join-Path $root 'src\ReviewerWeb\Triage.Reviewer.Web.vbproj') /p:Configuration=Release /v:minimal
    if ($LASTEXITCODE -ne 0) { throw 'Reviewer Web Forms build failed.' }

    if ($startedHere) { & (Join-Path $PSScriptRoot 'Start-Triage.ps1') -TestMode }
    & (Join-Path $PSScriptRoot 'Smoke-Test.ps1')

    $schemaVersionOutput = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql 'SET NOCOUNT ON; SELECT MAX(VersionNumber) AS VersionNumber FROM dbo.SchemaVersion;'
    $schemaVersion = [int](($schemaVersionOutput | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -Last 1).Trim())
    if ($schemaVersion -eq 1) {
        & (Join-Path $PSScriptRoot 'Test-LegacyBaseline.ps1')
    }
    if ($schemaVersion -ge 2) { & (Join-Path $PSScriptRoot 'Test-Inc101.ps1') }
    if ($schemaVersion -ge 3) { & (Join-Path $PSScriptRoot 'Test-Perf112.ps1') }
    if ($schemaVersion -ge 4) { & (Join-Path $PSScriptRoot 'Test-Feat124.ps1') }
    if ($schemaVersion -ge 5) { & (Join-Path $PSScriptRoot 'Test-Int131.ps1') }
    if ($schemaVersion -ge 6) { & (Join-Path $PSScriptRoot 'Test-Rel139.ps1') }
    Write-Host 'Triage local verification passed.' -ForegroundColor Green
} finally {
    if ($startedHere -and (Test-Path -LiteralPath (Get-TriageLocalPath -ChildPath 'run-state.json'))) {
        & (Join-Path $PSScriptRoot 'Stop-Triage.ps1')
    }
}
