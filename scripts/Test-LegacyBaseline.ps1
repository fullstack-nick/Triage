[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$sqlOutput = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql (Get-Content -LiteralPath (Join-Path (Get-TriageRoot) 'database\tests\baseline-smoke.sql') -Raw)
if (($sqlOutput -join "`n") -notmatch 'BASELINE_SMOKE_OK') { throw 'Baseline database smoke assertion failed.' }

$key = "baseline-defect-$([Guid]::NewGuid().ToString('N'))"
$payload = @{
    assignmentId = 1
    idempotencyKey = $key
    recipient = 'reviewer001@example.test'
    eventName = 'Aster Vale Research Forum 2027'
    dueAtUtc = '2027-03-15T17:00:00Z'
} | ConvertTo-Json -Compress
$headers = @{ 'Idempotency-Key' = $key }
$first = Invoke-RestMethod -Uri 'http://127.0.0.1:5071/api/review-reminders' -Method Post -ContentType 'application/json' -Headers $headers -Body $payload
$second = Invoke-RestMethod -Uri 'http://127.0.0.1:5071/api/review-reminders' -Method Post -ContentType 'application/json' -Headers $headers -Body $payload
if ($first.receiptId -eq $second.receiptId) { throw 'Expected the intentional baseline provider defect to create different receipts.' }

Write-Host 'Legacy baseline smoke test passed and its planned idempotency defect remains reproducible.' -ForegroundColor Yellow
