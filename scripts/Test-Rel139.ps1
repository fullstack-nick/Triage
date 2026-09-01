[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$root = Get-TriageRoot
$verificationDatabase = 'TriageReleaseVerification'
$backupContainerPath = '/var/opt/mssql/data/triage-release-verification.bak'
$reportPath = Get-TriageLocalPath -ChildPath 'test-results\REL-139-release-verification.txt'
$report = [System.Collections.Generic.List[string]]::new()

if ($verificationDatabase -ne 'TriageReleaseVerification') { throw 'Unsafe release-verification database target.' }
if ($backupContainerPath -ne '/var/opt/mssql/data/triage-release-verification.bak') { throw 'Unsafe release-verification backup target.' }

function Add-ReleaseReport([string] $Message) {
    $script:report.Add("$([DateTime]::UtcNow.ToString('O')) $Message")
}

function Remove-ReleaseVerificationDatabase {
    $dropSql = @"
SET NOCOUNT ON;
IF DB_ID(N'$verificationDatabase') IS NOT NULL
BEGIN
    ALTER DATABASE [$verificationDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$verificationDatabase];
END;
"@
    Invoke-TriageSqlText -Database 'master' -Sql $dropSql
}

function Get-ReleaseSql([string] $Path) {
    $sql = Get-Content -LiteralPath $Path -Raw
    $sql = $sql.Replace("DB_ID(N'Triage')", "DB_ID(N'$verificationDatabase')")
    $sql = $sql.Replace('CREATE DATABASE Triage;', "CREATE DATABASE [$verificationDatabase];")
    $sql = $sql.Replace('USE Triage;', "USE [$verificationDatabase];")
    return $sql
}

function Invoke-ReleaseSqlFile([string] $Path) {
    Add-ReleaseReport "Apply $([System.IO.Path]::GetFileName($Path))"
    Invoke-TriageSqlText -Database 'master' -Sql (Get-ReleaseSql -Path $Path)
}

function Get-MarkerLine([string[]] $Output, [string] $Prefix) {
    $line = $Output | Where-Object { $_ -match "^$([regex]::Escape($Prefix))\|" } | Select-Object -Last 1
    if (-not $line) { throw "Expected release verification marker was not returned: $Prefix" }
    return $line.Trim()
}

New-Item -ItemType Directory -Path (Split-Path -Parent $reportPath) -Force | Out-Null

try {
    $mainSmoke = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql 'EXEC dbo.usp_Triage_ReleaseSmokeTest;'
    if (($mainSmoke -join "`n") -notmatch 'REL139_SMOKE_OK') { throw 'Main release smoke procedure failed.' }
    Add-ReleaseReport 'Main schema smoke procedure passed.'

    Remove-ReleaseVerificationDatabase
    foreach ($schemaFile in Get-ChildItem -LiteralPath (Join-Path $root 'database\schema') -Filter '*.sql' | Sort-Object Name) {
        Invoke-ReleaseSqlFile -Path $schemaFile.FullName
    }
    foreach ($seedFile in Get-ChildItem -LiteralPath (Join-Path $root 'database\seed') -Filter '*.sql' | Sort-Object Name) {
        Invoke-ReleaseSqlFile -Path $seedFile.FullName
    }

    $baseline = Invoke-TriageSqlText -Database $verificationDatabase -CaptureOutput -Sql @'
SET NOCOUNT ON;
SELECT CONCAT('BASELINE|', DB_ID(), '|',
    (SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), '|',
    (SELECT COUNT(*) FROM dbo.Abstract), '|',
    (SELECT COUNT(*) FROM dbo.UserAccount WHERE UserRole='Reviewer'), '|',
    (SELECT COUNT(*) FROM dbo.ReviewAssignment), '|',
    (SELECT COUNT(*) FROM dbo.Review WHERE AssignmentId=4));
'@
    $baselineLine = Get-MarkerLine -Output $baseline -Prefix 'BASELINE'
    $baselineParts = $baselineLine.Split('|')
    if ($baselineParts.Count -ne 7 -or $baselineParts[2] -ne '1' -or $baselineParts[3] -ne '10000' -or $baselineParts[4] -ne '250' -or $baselineParts[5] -ne '20000' -or $baselineParts[6] -ne '2') {
        throw "Unexpected baseline state: $baselineLine"
    }
    $databaseId = [int]$baselineParts[1]
    Add-ReleaseReport "Baseline copy created once with database ID $databaseId and one duplicate fixture."

    $migrations = @(Get-ChildItem -LiteralPath (Join-Path $root 'database\migrations') -Filter '*.sql' | Sort-Object Name)
    foreach ($migration in $migrations) { Invoke-ReleaseSqlFile -Path $migration.FullName }

    $firstForward = Invoke-TriageSqlText -Database $verificationDatabase -CaptureOutput -Sql @'
SET NOCOUNT ON;
EXEC dbo.usp_Triage_ReleaseSmokeTest;
SELECT CONCAT('FIRST_FORWARD|', DB_ID(), '|',
    (SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), '|',
    (SELECT COUNT(*) FROM dbo.ReviewDuplicateArchive), '|',
    (SELECT COUNT(*) FROM dbo.Review WHERE AssignmentId=4));
'@
    $firstForwardLine = Get-MarkerLine -Output $firstForward -Prefix 'FIRST_FORWARD'
    $firstForwardParts = $firstForwardLine.Split('|')
    if ($firstForwardParts.Count -ne 5 -or [int]$firstForwardParts[1] -ne $databaseId -or $firstForwardParts[2] -ne '6' -or $firstForwardParts[3] -ne '1' -or $firstForwardParts[4] -ne '1') {
        throw "Unexpected first forward state: $firstForwardLine"
    }
    $archiveCount = [int]$firstForwardParts[3]
    Add-ReleaseReport 'Baseline-to-version-6 migration passed without database recreation.'

    $backupSql = @"
BACKUP DATABASE [$verificationDatabase]
TO DISK = N'$backupContainerPath'
WITH COPY_ONLY, INIT, CHECKSUM, STATS = 100;
RESTORE VERIFYONLY FROM DISK = N'$backupContainerPath' WITH CHECKSUM;
SELECT 'BACKUP_VERIFY_OK';
"@
    $backupResult = Invoke-TriageSqlText -Database 'master' -CaptureOutput -Sql $backupSql
    if (($backupResult -join "`n") -notmatch 'BACKUP_VERIFY_OK') { throw 'Release backup verification failed.' }
    Add-ReleaseReport 'COPY_ONLY backup completed and RESTORE VERIFYONLY passed.'

    $rollbacks = @(Get-ChildItem -LiteralPath (Join-Path $root 'database\rollback') -Filter '*.sql' | Sort-Object Name -Descending)
    if ($rollbacks.Count -ne $migrations.Count) { throw 'Every release migration must have exactly one paired rollback script.' }
    foreach ($rollback in $rollbacks) { Invoke-ReleaseSqlFile -Path $rollback.FullName }

    $rolledBack = Invoke-TriageSqlText -Database $verificationDatabase -CaptureOutput -Sql @'
SET NOCOUNT ON;
SELECT CONCAT('ROLLED_BACK|', DB_ID(), '|',
    (SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), '|',
    (SELECT COUNT(*) FROM dbo.ReviewDuplicateArchive), '|',
    (SELECT COUNT(*) FROM (SELECT AssignmentId FROM dbo.Review GROUP BY AssignmentId HAVING COUNT(*) > 1) duplicateReview), '|',
    (SELECT COUNT(*) FROM (SELECT IdempotencyKey FROM dbo.NotificationLog GROUP BY IdempotencyKey HAVING COUNT(*) > 1) duplicateReminder), '|',
    (SELECT COUNT(*) FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.Review') AND name=N'UX_Review_AssignmentId' AND is_unique=1), '|',
    (SELECT COUNT(*) FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.NotificationLog') AND name=N'UX_NotificationLog_IdempotencyKey' AND is_unique=1));
'@
    $rolledBackLine = Get-MarkerLine -Output $rolledBack -Prefix 'ROLLED_BACK'
    $rolledBackParts = $rolledBackLine.Split('|')
    if ($rolledBackParts.Count -ne 8 -or [int]$rolledBackParts[1] -ne $databaseId -or $rolledBackParts[2] -ne '1' -or [int]$rolledBackParts[3] -ne $archiveCount -or $rolledBackParts[4] -ne '0' -or $rolledBackParts[5] -ne '0' -or $rolledBackParts[6] -ne '1' -or $rolledBackParts[7] -ne '1') {
        throw "Unexpected rollback state: $rolledBackLine"
    }
    Add-ReleaseReport 'All paired rollbacks restored version 1 while preserving quarantine and uniqueness invariants.'

    foreach ($migration in $migrations) { Invoke-ReleaseSqlFile -Path $migration.FullName }

    $secondForward = Invoke-TriageSqlText -Database $verificationDatabase -CaptureOutput -Sql @'
SET NOCOUNT ON;
EXEC dbo.usp_Triage_ReleaseSmokeTest;
SELECT CONCAT('SECOND_FORWARD|', DB_ID(), '|',
    (SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), '|',
    (SELECT COUNT(*) FROM dbo.ReviewDuplicateArchive), '|',
    (SELECT COUNT(*) FROM (SELECT AssignmentId FROM dbo.Review GROUP BY AssignmentId HAVING COUNT(*) > 1) duplicateReview));
'@
    $secondForwardLine = Get-MarkerLine -Output $secondForward -Prefix 'SECOND_FORWARD'
    $secondForwardParts = $secondForwardLine.Split('|')
    if ($secondForwardParts.Count -ne 5 -or [int]$secondForwardParts[1] -ne $databaseId -or $secondForwardParts[2] -ne '6' -or [int]$secondForwardParts[3] -ne $archiveCount -or $secondForwardParts[4] -ne '0') {
        throw "Unexpected second forward state: $secondForwardLine"
    }
    Add-ReleaseReport 'Second forward migration and stored smoke procedure passed on the same database.'
    Add-ReleaseReport 'REL-139 verification passed.'
} finally {
    try { Remove-ReleaseVerificationDatabase } catch { Add-ReleaseReport "Cleanup warning: $($_.Exception.Message)" }
    & docker exec triage-sql bash -lc "rm -f -- '$backupContainerPath'" 2>$null
    if ($LASTEXITCODE -ne 0) { Add-ReleaseReport 'Cleanup warning: disposable backup file could not be removed.' }
    $report | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
}

Write-Host "REL-139 passed baseline upgrade, backup verification, all rollbacks, second forward migration, and smoke checks. Report: $reportPath" -ForegroundColor Green
