[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$root = Get-TriageRoot
$sqlResult = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql (Get-Content -LiteralPath (Join-Path $root 'database\tests\final-security-boundaries.sql') -Raw)
if (($sqlResult -join "`n") -notmatch 'FINAL_SECURITY_BOUNDARIES_OK') {
    throw 'Final ownership, projection, and score-boundary assertions failed.'
}

$sentinelHits = @()
foreach ($relative in @('logs', 'test-results')) {
    $target = Get-TriageLocalPath -ChildPath $relative
    if (Test-Path -LiteralPath $target) {
        $sentinelHits += Get-ChildItem -LiteralPath $target -File -Recurse -ErrorAction SilentlyContinue |
            Select-String -SimpleMatch 'PRIVATE-AUTHOR-' -ErrorAction SilentlyContinue
    }
}
if ($sentinelHits.Count -gt 0) { throw 'A private author sentinel appeared in ignored runtime logs or test reports.' }

Write-Host 'Final security boundaries passed ownership, blind projection, score validation, and runtime leakage checks.' -ForegroundColor Green
