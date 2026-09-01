USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.NotificationLog')
      AND name = N'UX_NotificationLog_IdempotencyKey'
      AND is_unique = 1
)
    THROW 54300, 'Main notification idempotency index is missing.', 1;

BEGIN TRY
    EXEC dbo.usp_ReviewReminder_Create 19986, 2, '2027-03-20T12:00:00';
    THROW 54301, 'Non-admin reminder request unexpectedly succeeded.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 54301 THROW;
    IF ERROR_NUMBER() <> 51050 THROW;
END CATCH;

BEGIN TRANSACTION;

DECLARE @AssignmentId int = 19986;
DECLARE @AsOfUtc datetime2(3) = '2027-03-20T12:00:00';
CREATE TABLE #Created
(
    NotificationId bigint,
    AssignmentId int,
    IdempotencyKey nvarchar(100),
    ReviewerEmail nvarchar(254),
    ConferenceName nvarchar(160),
    DueAtUtc datetime2(3)
);

INSERT #Created EXEC dbo.usp_ReviewReminder_Create @AssignmentId, 1, @AsOfUtc;
DECLARE @FirstNotificationId bigint = (SELECT NotificationId FROM #Created);
DECLARE @FirstKey nvarchar(100) = (SELECT IdempotencyKey FROM #Created);
TRUNCATE TABLE #Created;
INSERT #Created EXEC dbo.usp_ReviewReminder_Create @AssignmentId, 1, @AsOfUtc;

IF (SELECT NotificationId FROM #Created) <> @FirstNotificationId
    THROW 54302, 'Same-day logical reminder returned another notification.', 1;
IF (SELECT COUNT(*) FROM dbo.NotificationLog WHERE IdempotencyKey = @FirstKey) <> 1
    THROW 54303, 'Same-day logical reminder has more than one main row.', 1;
IF (SELECT COUNT(*) FROM dbo.AuditEvent WHERE EntityType = 'Notification' AND EntityId = @FirstNotificationId AND Action IN ('ReminderRequested', 'ReminderRetried')) <> 2
    THROW 54304, 'Reminder request/retry audit events are incomplete.', 1;

EXEC dbo.usp_ReviewReminder_MarkResult @FirstNotificationId, 1, 'RetryableFailure', N'temporary status only';
EXEC dbo.usp_ReviewReminder_MarkResult @FirstNotificationId, 1, 'Succeeded', N'provider receipt accepted';

IF NOT EXISTS
(
    SELECT 1 FROM dbo.NotificationLog
    WHERE NotificationId = @FirstNotificationId
      AND RequestStatus = 'Succeeded'
      AND AttemptCount = 2
)
    THROW 54305, 'Reminder result state or attempt count is incorrect.', 1;
IF (SELECT COUNT(*) FROM dbo.AuditEvent WHERE EntityType = 'Notification' AND EntityId = @FirstNotificationId AND Action = 'ReminderResultRecorded') <> 2
    THROW 54306, 'Reminder result audit events are incomplete.', 1;

TRUNCATE TABLE #Created;
INSERT #Created EXEC dbo.usp_ReviewReminder_Create @AssignmentId, 1, '2027-03-21T12:00:00';
IF (SELECT NotificationId FROM #Created) = @FirstNotificationId OR (SELECT IdempotencyKey FROM #Created) = @FirstKey
    THROW 54307, 'A later UTC day did not create a new logical reminder.', 1;

BEGIN TRY
    EXEC dbo.usp_ReviewReminder_MarkResult @FirstNotificationId, 1, 'Unknown', N'invalid';
    THROW 54308, 'Invalid result state unexpectedly succeeded.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 54308 THROW;
    IF ERROR_NUMBER() <> 51052 THROW;
END CATCH;

ROLLBACK;

PRINT 'INT131_SQL_OK';
GO
