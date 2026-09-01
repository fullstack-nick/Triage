USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = 5)
    RETURN;

IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 4
    THROW 53060, 'INT-131 requires schema version 4.', 1;

BEGIN TRANSACTION;

;WITH DuplicateGroups AS
(
    SELECT
        IdempotencyKey,
        MIN(NotificationId) AS SurvivorNotificationId,
        SUM(AttemptCount) AS TotalAttempts,
        MAX(LastAttemptAtUtc) AS LastAttemptAtUtc,
        MAX(CASE RequestStatus WHEN 'Succeeded' THEN 4 WHEN 'Pending' THEN 3 WHEN 'RetryableFailure' THEN 2 ELSE 1 END) AS StatusRank
    FROM dbo.NotificationLog
    GROUP BY IdempotencyKey
    HAVING COUNT(*) > 1
)
UPDATE survivor
SET AttemptCount = duplicateGroup.TotalAttempts,
    LastAttemptAtUtc = duplicateGroup.LastAttemptAtUtc,
    RequestStatus = CASE duplicateGroup.StatusRank
        WHEN 4 THEN 'Succeeded'
        WHEN 3 THEN 'Pending'
        WHEN 2 THEN 'RetryableFailure'
        ELSE 'PermanentFailure'
    END
FROM dbo.NotificationLog survivor
INNER JOIN DuplicateGroups duplicateGroup ON duplicateGroup.SurvivorNotificationId = survivor.NotificationId;

;WITH RankedNotification AS
(
    SELECT
        NotificationId,
        ROW_NUMBER() OVER (PARTITION BY IdempotencyKey ORDER BY NotificationId) AS LogicalRank
    FROM dbo.NotificationLog
)
DELETE notificationRow
FROM dbo.NotificationLog notificationRow
INNER JOIN RankedNotification ranked ON ranked.NotificationId = notificationRow.NotificationId
WHERE ranked.LogicalRank > 1;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.NotificationLog')
      AND name = N'UX_NotificationLog_IdempotencyKey'
)
BEGIN
    CREATE UNIQUE INDEX UX_NotificationLog_IdempotencyKey
        ON dbo.NotificationLog(IdempotencyKey);
END;

COMMIT;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReviewReminder_Create
    @AssignmentId int,
    @RequestedByUserId int,
    @AsOfUtc datetime2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @AsOfUtc = ISNULL(@AsOfUtc, SYSUTCDATETIME());

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS
        (
            SELECT 1 FROM dbo.UserAccount WITH (UPDLOCK, HOLDLOCK)
            WHERE UserId = @RequestedByUserId
              AND UserRole = 'Admin'
              AND IsActive = 1
        )
            THROW 51050, 'Administrator access is required.', 1;

        DECLARE @ReviewerEmail nvarchar(254), @ConferenceName nvarchar(160), @DueAtUtc datetime2(3), @AssignmentStatus varchar(20);
        SELECT
            @ReviewerEmail = reviewer.Email,
            @ConferenceName = conference.Name,
            @DueAtUtc = assignment.DueAtUtc,
            @AssignmentStatus = assignment.Status
        FROM dbo.ReviewAssignment assignment WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN dbo.UserAccount reviewer ON reviewer.UserId = assignment.ReviewerUserId AND reviewer.IsActive = 1
        INNER JOIN dbo.Abstract abstractRow ON abstractRow.AbstractId = assignment.AbstractId
        INNER JOIN dbo.Conference conference ON conference.ConferenceId = abstractRow.ConferenceId
        WHERE assignment.AssignmentId = @AssignmentId;

        IF @ReviewerEmail IS NULL OR @AssignmentStatus NOT IN ('Assigned', 'Draft')
            THROW 51051, 'Assignment was not found or is not reminder-eligible.', 1;

        DECLARE @IdempotencyKey nvarchar(100) =
            CONCAT(N'review-reminder-', @AssignmentId, N'-', CONVERT(char(8), @AsOfUtc, 112));
        DECLARE @NotificationId bigint, @WasCreated bit = 0;

        SELECT @NotificationId = NotificationId
        FROM dbo.NotificationLog WITH (UPDLOCK, HOLDLOCK)
        WHERE IdempotencyKey = @IdempotencyKey;

        IF @NotificationId IS NULL
        BEGIN
            INSERT dbo.NotificationLog
            (
                AssignmentId,
                IdempotencyKey,
                RequestStatus,
                AttemptCount,
                RequestedByUserId,
                CreatedAtUtc
            )
            VALUES
            (
                @AssignmentId,
                @IdempotencyKey,
                'Pending',
                0,
                @RequestedByUserId,
                @AsOfUtc
            );
            SET @NotificationId = SCOPE_IDENTITY();
            SET @WasCreated = 1;
        END;

        INSERT dbo.AuditEvent (EntityType, EntityId, Action, PerformedByUserId, OccurredAtUtc, Details)
        VALUES
        (
            'Notification',
            @NotificationId,
            CASE WHEN @WasCreated = 1 THEN 'ReminderRequested' ELSE 'ReminderRetried' END,
            @RequestedByUserId,
            @AsOfUtc,
            CONCAT(N'{"assignmentId":', @AssignmentId, N',"notificationId":', @NotificationId, N'}')
        );

        COMMIT;

        SELECT
            @NotificationId AS NotificationId,
            @AssignmentId AS AssignmentId,
            @IdempotencyKey AS IdempotencyKey,
            @ReviewerEmail AS ReviewerEmail,
            @ConferenceName AS ConferenceName,
            @DueAtUtc AS DueAtUtc;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReviewReminder_MarkResult
    @NotificationId bigint,
    @RequestedByUserId int,
    @RequestStatus varchar(24),
    @ProviderResponse nvarchar(1000)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @RequestStatus NOT IN ('Succeeded', 'RetryableFailure', 'PermanentFailure')
        THROW 51052, 'Reminder result state is not supported.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS
        (
            SELECT 1 FROM dbo.UserAccount WITH (UPDLOCK, HOLDLOCK)
            WHERE UserId = @RequestedByUserId
              AND UserRole = 'Admin'
              AND IsActive = 1
        )
            THROW 51050, 'Administrator access is required.', 1;

        DECLARE @AssignmentId int, @CurrentStatus varchar(24);
        SELECT
            @AssignmentId = AssignmentId,
            @CurrentStatus = RequestStatus
        FROM dbo.NotificationLog WITH (UPDLOCK, HOLDLOCK)
        WHERE NotificationId = @NotificationId;

        IF @AssignmentId IS NULL
            THROW 51053, 'Notification was not found.', 1;

        UPDATE dbo.NotificationLog
        SET RequestStatus = CASE WHEN @CurrentStatus = 'Succeeded' THEN 'Succeeded' ELSE @RequestStatus END,
            AttemptCount = AttemptCount + 1,
            LastAttemptAtUtc = SYSUTCDATETIME(),
            ProviderResponse = LEFT(REPLACE(REPLACE(ISNULL(@ProviderResponse, N''), CHAR(13), N' '), CHAR(10), N' '), 1000)
        WHERE NotificationId = @NotificationId;

        INSERT dbo.AuditEvent (EntityType, EntityId, Action, PerformedByUserId, Details)
        VALUES
        (
            'Notification',
            @NotificationId,
            'ReminderResultRecorded',
            @RequestedByUserId,
            CONCAT(N'{"assignmentId":', @AssignmentId, N',"notificationId":', @NotificationId, N'}')
        );

        COMMIT;

        SELECT NotificationId, RequestStatus, AttemptCount, LastAttemptAtUtc
        FROM dbo.NotificationLog
        WHERE NotificationId = @NotificationId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = 5)
BEGIN
    INSERT dbo.SchemaVersion (VersionNumber, Description)
    VALUES (5, N'INT-131 durable idempotent reminder delivery');
END;
GO
