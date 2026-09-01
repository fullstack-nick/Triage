USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 5
    THROW 53105, 'INT-131 rollback requires schema version 5.', 1;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.NotificationLog')
      AND name = N'UX_NotificationLog_IdempotencyKey'
      AND is_unique = 1
)
    THROW 53115, 'INT-131 rollback refuses to weaken reminder uniqueness.', 1;
GO

-- Restore the version-4 procedure contract while retaining the unique key and
-- conflict-safe insert. Known duplicate reminder identities are never recreated.
CREATE OR ALTER PROCEDURE dbo.usp_ReviewReminder_Create
    @AssignmentId int,
    @RequestedByUserId int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AsOfUtc datetime2(3) = SYSUTCDATETIME();

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
        DECLARE @NotificationId bigint;

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
        END;

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
    @RequestStatus varchar(24),
    @ProviderResponse nvarchar(1000)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @RequestStatus NOT IN ('Succeeded', 'RetryableFailure', 'PermanentFailure')
        THROW 51052, 'Reminder result state is not supported.', 1;

    UPDATE dbo.NotificationLog
    SET RequestStatus = CASE WHEN RequestStatus = 'Succeeded' THEN 'Succeeded' ELSE @RequestStatus END,
        AttemptCount = AttemptCount + 1,
        LastAttemptAtUtc = SYSUTCDATETIME(),
        ProviderResponse = LEFT(REPLACE(REPLACE(ISNULL(@ProviderResponse, N''), CHAR(13), N' '), CHAR(10), N' '), 1000)
    WHERE NotificationId = @NotificationId;

    IF @@ROWCOUNT <> 1
        THROW 51053, 'Notification was not found.', 1;
END;
GO

SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;
    DELETE dbo.SchemaVersion WHERE VersionNumber = 5;
    IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 4
        THROW 53116, 'INT-131 rollback did not restore version 4.', 1;
    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
GO
