[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$root = Get-TriageRoot
$sqlResult = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql (Get-Content -LiteralPath (Join-Path $root 'database\tests\feat-124-reassignment.sql') -Raw)
if (($sqlResult -join "`n") -notmatch 'FEAT124_SQL_OK') { throw 'FEAT-124 SQL assertions failed.' }

$fixtureOutput = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql @'
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
DECLARE @AssignmentId int = 19990;
DECLARE @AbstractId int = (SELECT AbstractId FROM dbo.ReviewAssignment WHERE AssignmentId = @AssignmentId);
DELETE auditEvent FROM dbo.AuditEvent auditEvent WHERE auditEvent.EntityType = 'ReviewAssignment' AND auditEvent.EntityId = @AssignmentId AND auditEvent.Action = 'ReviewReassigned';
DELETE childAssignment FROM dbo.ReviewAssignment childAssignment WHERE childAssignment.ReassignedFromAssignmentId = @AssignmentId;
DELETE FROM dbo.Review WHERE AssignmentId = @AssignmentId;
UPDATE dbo.ReviewAssignment SET Status = 'Assigned' WHERE AssignmentId = @AssignmentId;
DECLARE @CandidateOne int, @CandidateTwo int;
;WITH Eligible AS
(
    SELECT account.UserId, ROW_NUMBER() OVER (ORDER BY account.UserId) AS CandidateRank
    FROM dbo.UserAccount account
    WHERE account.UserRole = 'Reviewer' AND account.IsActive = 1
      AND NOT EXISTS (SELECT 1 FROM dbo.ReviewAssignment assignment WHERE assignment.AbstractId = @AbstractId AND assignment.ReviewerUserId = account.UserId)
      AND NOT EXISTS (SELECT 1 FROM dbo.ReviewerConflict conflictRow WHERE conflictRow.AbstractId = @AbstractId AND conflictRow.ReviewerUserId = account.UserId)
)
SELECT @CandidateOne = MAX(CASE WHEN CandidateRank = 1 THEN UserId END), @CandidateTwo = MAX(CASE WHEN CandidateRank = 2 THEN UserId END) FROM Eligible;
SELECT CONCAT('FIXTURE|', @CandidateOne, '|', @CandidateTwo);
'@
$fixtureLine = ($fixtureOutput | Where-Object { $_ -match '^FIXTURE\|' } | Select-Object -Last 1).Trim()
$fixtureParts = $fixtureLine.Split('|')
$candidateOne = [int]$fixtureParts[1]
$candidateTwo = [int]$fixtureParts[2]

$forcedFailureSql = @"
SET NOCOUNT ON;
EXEC sys.sp_set_session_context @key=N'Triage.ForceReassignFailure', @value=1;
BEGIN TRY
    EXEC dbo.usp_ReviewAssignment_Reassign 19990, $candidateOne, 1;
    THROW 54220, 'Forced failure unexpectedly succeeded.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 54220 THROW;
    IF ERROR_NUMBER() <> 51038 THROW;
END CATCH;
EXEC sys.sp_set_session_context @key=N'Triage.ForceReassignFailure', @value=NULL;
IF (SELECT Status FROM dbo.ReviewAssignment WHERE AssignmentId = 19990) <> 'Assigned'
   OR EXISTS (SELECT 1 FROM dbo.ReviewAssignment WHERE ReassignedFromAssignmentId = 19990)
   OR EXISTS (SELECT 1 FROM dbo.AuditEvent WHERE EntityId = 19990 AND Action = 'ReviewReassigned')
    THROW 54221, 'Forced failure left partial reassignment state.', 1;
SELECT 'ROLLBACK_OK';
"@
$forcedResult = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql $forcedFailureSql
if (($forcedResult -join "`n") -notmatch 'ROLLBACK_OK') { throw 'Forced reassignment rollback assertion failed.' }

$inactiveSql = @"
SET NOCOUNT ON;
DECLARE @InactiveReviewerId int = 251;
UPDATE dbo.UserAccount SET IsActive = 0 WHERE UserId = @InactiveReviewerId;
BEGIN TRY
    EXEC dbo.usp_ReviewAssignment_Reassign 19990, @InactiveReviewerId, 1;
    UPDATE dbo.UserAccount SET IsActive = 1 WHERE UserId = @InactiveReviewerId;
    THROW 54222, 'Inactive reviewer unexpectedly accepted.', 1;
END TRY
BEGIN CATCH
    DECLARE @ErrorNumber int = ERROR_NUMBER();
    UPDATE dbo.UserAccount SET IsActive = 1 WHERE UserId = @InactiveReviewerId;
    IF @ErrorNumber = 54222 THROW;
    IF @ErrorNumber <> 51034 THROW;
END CATCH;
SELECT 'INACTIVE_OK';
"@
$inactiveResult = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql $inactiveSql
if (($inactiveResult -join "`n") -notmatch 'INACTIVE_OK') { throw 'Inactive reviewer rejection failed.' }

$requests = @($candidateOne, $candidateTwo) | ForEach-Object -Parallel {
    $targetReviewer = $_
    $sql = "SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON; EXEC dbo.usp_ReviewAssignment_Reassign 19990, $targetReviewer, 1;"
    $output = $sql | & docker exec -i triage-sql bash -lc '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -I -b -r 1 -d Triage' 2>&1
    [pscustomobject]@{ succeeded = ($LASTEXITCODE -eq 0); output = ($output -join "`n") }
} -ThrottleLimit 2

if (@($requests | Where-Object succeeded).Count -ne 1 -or @($requests | Where-Object { -not $_.succeeded }).Count -ne 1) {
    throw 'Concurrent reassignment did not produce exactly one success and one rejection.'
}

$concurrencyResult = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql @'
SET NOCOUNT ON;
SELECT CONCAT('CONCURRENCY|',
    (SELECT COUNT(*) FROM dbo.ReviewAssignment WHERE ReassignedFromAssignmentId = 19990), '|',
    (SELECT COUNT(*) FROM dbo.AuditEvent WHERE EntityId = 19990 AND Action = 'ReviewReassigned'), '|',
    (SELECT Status FROM dbo.ReviewAssignment WHERE AssignmentId = 19990));
'@
$concurrencyLine = ($concurrencyResult | Where-Object { $_ -match '^CONCURRENCY\|' } | Select-Object -Last 1).Trim()
if ($concurrencyLine -ne 'CONCURRENCY|1|1|Reassigned') { throw "Unexpected concurrent state: $concurrencyLine" }

Write-Host 'FEAT-124 passed candidate, conflict, prior, inactive, completed, transaction rollback, audit, and concurrent reassignment checks.' -ForegroundColor Green
