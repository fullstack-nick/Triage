[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$root = Get-TriageRoot
$sqlResult = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql (Get-Content -LiteralPath (Join-Path $root 'database\tests\perf-112-queue.sql') -Raw)
if (($sqlResult -join "`n") -notmatch 'PERF112_SQL_OK') { throw 'PERF-112 SQL correctness assertions failed.' }

$baselinePath = Join-Path $root 'database\performance\PERF-112-baseline.json'
$optimizedPath = Join-Path $root 'database\performance\PERF-112-optimized.json'
if (-not (Test-Path -LiteralPath $baselinePath) -or -not (Test-Path -LiteralPath $optimizedPath)) {
    throw 'PERF-112 baseline and optimized evidence files are required.'
}
$baseline = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
$optimized = Get-Content -LiteralPath $optimizedPath -Raw | ConvertFrom-Json
if ($baseline.referenceFirstPage.checksum -ne $optimized.referenceFirstPage.checksum) { throw 'Before/after reference checksums differ.' }

$unfiltered = $optimized.summaries | Where-Object scenario -eq 'unfiltered'
$filtered = $optimized.summaries | Where-Object scenario -eq 'filtered'
if ($unfiltered.warmP95Milliseconds -gt 750) { throw "Unfiltered warm p95 exceeds 750 ms: $($unfiltered.warmP95Milliseconds)" }
if ($filtered.warmP95Milliseconds -gt 500) { throw "Filtered warm p95 exceeds 500 ms: $($filtered.warmP95Milliseconds)" }
if ($optimized.coldMaximumMilliseconds -gt 2000) { throw "Cold maximum exceeds 2 seconds: $($optimized.coldMaximumMilliseconds)" }

Write-Host 'PERF-112 passed reference correctness, index, bound, injection, and measured latency checks.' -ForegroundColor Green
