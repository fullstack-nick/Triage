[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$root = Get-TriageRoot
$sqlResult = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql (Get-Content -LiteralPath (Join-Path $root 'database\tests\int-131-reminders.sql') -Raw)
if (($sqlResult -join "`n") -notmatch 'INT131_SQL_OK') { throw 'INT-131 SQL assertions failed.' }

$mainFixture = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql @'
SET NOCOUNT ON;
DECLARE @Key nvarchar(100) = N'review-reminder-19982-20270402';
DELETE auditEvent FROM dbo.AuditEvent auditEvent
WHERE auditEvent.EntityType = 'Notification'
  AND auditEvent.EntityId IN (SELECT NotificationId FROM dbo.NotificationLog WHERE IdempotencyKey = @Key);
DELETE FROM dbo.NotificationLog WHERE IdempotencyKey = @Key;
SELECT 'MAIN_FIXTURE_OK';
'@
if (($mainFixture -join "`n") -notmatch 'MAIN_FIXTURE_OK') { throw 'Main reminder concurrency fixture failed.' }

$mainSaveSql = "SET NOCOUNT ON; EXEC dbo.usp_ReviewReminder_Create @AssignmentId=19982, @RequestedByUserId=1, @AsOfUtc='2027-04-02T12:00:00';"
1..20 | ForEach-Object -Parallel {
    $using:mainSaveSql | & docker exec -i triage-sql bash -lc '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -I -b -r 1 -d Triage' *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Concurrent main reminder creation failed.' }
} -ThrottleLimit 20

$mainResult = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql @'
SET NOCOUNT ON;
DECLARE @NotificationId bigint = (SELECT NotificationId FROM dbo.NotificationLog WHERE IdempotencyKey = N'review-reminder-19982-20270402');
SELECT CONCAT('MAIN_CONCURRENCY|',
    (SELECT COUNT(*) FROM dbo.NotificationLog WHERE IdempotencyKey = N'review-reminder-19982-20270402'), '|',
    (SELECT COUNT(*) FROM dbo.AuditEvent WHERE EntityType = 'Notification' AND EntityId = @NotificationId AND Action IN ('ReminderRequested', 'ReminderRetried')));
'@
$mainLine = ($mainResult | Where-Object { $_ -match '^MAIN_CONCURRENCY\|' } | Select-Object -Last 1).Trim()
if ($mainLine -ne 'MAIN_CONCURRENCY|1|20') { throw "Unexpected main reminder concurrency state: $mainLine" }

$providerUrl = 'http://127.0.0.1:5071/api/review-reminders'
function New-ReminderJson([string] $Key, [string] $Recipient = 'reviewer101@example.test') {
    return @{
        assignmentId = 101
        idempotencyKey = $Key
        recipient = $Recipient
        eventName = 'Aster Vale Research Forum 2027'
        dueAtUtc = '2027-03-15T17:00:00Z'
    } | ConvertTo-Json -Compress
}

$concurrentKey = "http-concurrent-$([Guid]::NewGuid().ToString('N'))"
$concurrentJson = New-ReminderJson -Key $concurrentKey
$providerResults = 1..20 | ForEach-Object -Parallel {
    Invoke-RestMethod -Uri 'http://127.0.0.1:5071/api/review-reminders' -Method Post -ContentType 'application/json' -Headers @{ 'Idempotency-Key' = $using:concurrentKey } -Body $using:concurrentJson
} -ThrottleLimit 20
if (@($providerResults.receiptId | Sort-Object -Unique).Count -ne 1) { throw 'Concurrent provider requests returned multiple receipt IDs.' }
if (@($providerResults | Where-Object { -not $_.replayed }).Count -ne 1) { throw 'Concurrent provider requests did not create exactly one first receipt.' }

$mismatchKey = "http-mismatch-$([Guid]::NewGuid().ToString('N'))"
$mismatch = Invoke-WebRequest -Uri $providerUrl -Method Post -ContentType 'application/json' -Headers @{ 'Idempotency-Key' = "$mismatchKey-other" } -Body (New-ReminderJson $mismatchKey) -SkipHttpErrorCheck
if ($mismatch.StatusCode -ne 400) { throw "Header/body key mismatch returned $($mismatch.StatusCode), expected 400." }

$conflictKey = "http-conflict-$([Guid]::NewGuid().ToString('N'))"
$conflictHeaders = @{ 'Idempotency-Key' = $conflictKey }
[void](Invoke-WebRequest -Uri $providerUrl -Method Post -ContentType 'application/json' -Headers $conflictHeaders -Body (New-ReminderJson $conflictKey))
$conflict = Invoke-WebRequest -Uri $providerUrl -Method Post -ContentType 'application/json' -Headers $conflictHeaders -Body (New-ReminderJson $conflictKey 'another-reviewer@example.test') -SkipHttpErrorCheck
if ($conflict.StatusCode -ne 409) { throw "Same-key/different-payload returned $($conflict.StatusCode), expected 409." }

$malformed = Invoke-WebRequest -Uri $providerUrl -Method Post -ContentType 'application/json' -Headers @{ 'Idempotency-Key' = 'malformed-request-key' } -Body '{' -SkipHttpErrorCheck
if ($malformed.StatusCode -ne 400) { throw "Malformed payload returned $($malformed.StatusCode), expected 400." }
$invalidKey = "http-invalid-$([Guid]::NewGuid().ToString('N'))"
$invalid = Invoke-WebRequest -Uri $providerUrl -Method Post -ContentType 'application/json' -Headers @{ 'Idempotency-Key' = $invalidKey } -Body (New-ReminderJson $invalidKey 'not-an-email') -SkipHttpErrorCheck
if ($invalid.StatusCode -ne 400) { throw "Invalid email returned $($invalid.StatusCode), expected 400." }

$failureKey = "http-failure-$([Guid]::NewGuid().ToString('N'))"
$failureBody = New-ReminderJson $failureKey
$failure = Invoke-WebRequest -Uri $providerUrl -Method Post -ContentType 'application/json' -Headers @{ 'Idempotency-Key' = $failureKey; 'X-Triage-Test-Failure' = 'after-commit-503' } -Body $failureBody -SkipHttpErrorCheck
if ($failure.StatusCode -ne 503) { throw "After-commit failure returned $($failure.StatusCode), expected 503." }
$failedReceipt = ($failure.Content | ConvertFrom-Json).receiptId
$failureReplay = Invoke-RestMethod -Uri $providerUrl -Method Post -ContentType 'application/json' -Headers @{ 'Idempotency-Key' = $failureKey } -Body $failureBody
if (-not $failureReplay.replayed -or $failureReplay.receiptId -ne $failedReceipt) { throw '503 retry did not return the committed receipt.' }

$timeoutKey = "http-timeout-$([Guid]::NewGuid().ToString('N'))"
$timeoutBody = New-ReminderJson $timeoutKey
$timedOut = $false
try {
    [void](Invoke-WebRequest -Uri $providerUrl -Method Post -ContentType 'application/json' -Headers @{ 'Idempotency-Key' = $timeoutKey; 'X-Triage-Test-Failure' = 'after-commit-timeout' } -Body $timeoutBody -TimeoutSec 1)
} catch {
    $timedOut = $true
}
if (-not $timedOut) { throw 'After-commit timeout request did not time out at the client.' }
$timeoutReplay = Invoke-RestMethod -Uri $providerUrl -Method Post -ContentType 'application/json' -Headers @{ 'Idempotency-Key' = $timeoutKey } -Body $timeoutBody
if (-not $timeoutReplay.replayed) { throw 'Timeout retry did not replay the committed receipt.' }

$restartKey = "http-restart-$([Guid]::NewGuid().ToString('N'))"
$restartBody = New-ReminderJson $restartKey
$beforeRestart = Invoke-RestMethod -Uri $providerUrl -Method Post -ContentType 'application/json' -Headers @{ 'Idempotency-Key' = $restartKey } -Body $restartBody
& (Join-Path $PSScriptRoot 'Restart-NotificationProvider.ps1') -TestMode
$afterRestart = Invoke-RestMethod -Uri $providerUrl -Method Post -ContentType 'application/json' -Headers @{ 'Idempotency-Key' = $restartKey } -Body $restartBody
if (-not $afterRestart.replayed -or $afterRestart.receiptId -ne $beforeRestart.receiptId) { throw 'Provider restart did not preserve the receipt.' }

$settings = Read-TriageEnvironment
$webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
[void](Invoke-WebRequest 'http://127.0.0.1:5070/admin/dev-login.asp' -WebSession $webSession)
[void](Invoke-WebRequest 'http://127.0.0.1:5070/admin/dev-login.asp' -Method Post -Body @{ password = $settings.TRIAGE_ADMIN_PASSWORD } -WebSession $webSession)
$queue = Invoke-WebRequest 'http://127.0.0.1:5070/admin/review-queue.asp?abstractId=9991' -WebSession $webSession
$csrf = [regex]::Match($queue.Content, 'name="csrfToken" value="([A-F0-9]{64})"').Groups[1].Value
$assignmentId = [int][regex]::Match($queue.Content, 'name="assignmentId" value="(\d+)"').Groups[1].Value
if (-not $csrf -or $assignmentId -lt 1) { throw 'Could not read the Classic ASP reminder action.' }

$cleanupSql = "SET NOCOUNT ON; DELETE auditEvent FROM dbo.AuditEvent auditEvent WHERE auditEvent.EntityType='Notification' AND auditEvent.EntityId IN (SELECT NotificationId FROM dbo.NotificationLog WHERE AssignmentId=$assignmentId); DELETE FROM dbo.NotificationLog WHERE AssignmentId=$assignmentId;"
Invoke-TriageSqlText -Database 'Triage' -Sql $cleanupSql
1..2 | ForEach-Object {
    $response = Invoke-WebRequest 'http://127.0.0.1:5070/admin/review-queue.asp' -Method Post -Body @{ csrfToken = $csrf; action = 'send-reminder'; assignmentId = $assignmentId } -WebSession $webSession
    if ($response.Content -notmatch 'Reminder accepted') { throw 'Classic ASP reminder request was not accepted.' }
}

$classicResult = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql "SET NOCOUNT ON; DECLARE @NotificationId bigint=(SELECT NotificationId FROM dbo.NotificationLog WHERE AssignmentId=$assignmentId); SELECT CONCAT('CLASSIC|',(SELECT COUNT(*) FROM dbo.NotificationLog WHERE AssignmentId=$assignmentId),'|',(SELECT AttemptCount FROM dbo.NotificationLog WHERE NotificationId=@NotificationId),'|',(SELECT COUNT(*) FROM dbo.AuditEvent WHERE EntityType='Notification' AND EntityId=@NotificationId),'|',(SELECT RequestStatus FROM dbo.NotificationLog WHERE NotificationId=@NotificationId));"
$classicLine = ($classicResult | Where-Object { $_ -match '^CLASSIC\|' } | Select-Object -Last 1).Trim()
if ($classicLine -ne 'CLASSIC|1|2|4|Succeeded') { throw "Unexpected Classic ASP reminder state: $classicLine" }

Write-Host 'INT-131 passed main/provider concurrency, 4xx, conflict, 503, timeout, restart, and Classic ASP retry checks.' -ForegroundColor Green
