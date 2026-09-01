[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$root = Get-TriageRoot
$sqlResult = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql (Get-Content -LiteralPath (Join-Path $root 'database\tests\inc-101-review-uniqueness.sql') -Raw)
if (($sqlResult -join "`n") -notmatch 'INC101_SQL_OK') { throw 'INC-101 SQL assertions failed.' }

$fixture = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql @'
SET NOCOUNT ON;
DECLARE @AssignmentId int = 19998;
DELETE FROM dbo.Review WHERE AssignmentId = @AssignmentId;
UPDATE dbo.ReviewAssignment SET Status = 'Assigned' WHERE AssignmentId = @AssignmentId;
SELECT ReviewerUserId FROM dbo.ReviewAssignment WHERE AssignmentId = @AssignmentId;
'@
$reviewerId = [int](($fixture | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -Last 1).Trim())

$saveSql = "SET NOCOUNT ON; EXEC dbo.usp_Review_Save @AssignmentId=19998, @ReviewerUserId=$reviewerId, @Score=3, @Comment=N'Concurrent invariant test', @IsFinal=0;"
1..20 | ForEach-Object -Parallel {
    $using:saveSql | & docker exec -i triage-sql bash -lc '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -r 1 -d Triage' *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Concurrent INC-101 save failed.' }
} -ThrottleLimit 20

$countResult = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql 'SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.Review WHERE AssignmentId = 19998;'
$count = [int](($countResult | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -Last 1).Trim())
if ($count -ne 1) { throw "Concurrent saves produced $count review rows instead of one." }

Write-Host 'INC-101 passed sequential, final-idempotency, post-final rejection, archive, constraint, and 20-way concurrency checks.' -ForegroundColor Green
