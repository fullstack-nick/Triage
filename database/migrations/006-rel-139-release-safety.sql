USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @CurrentVersion int = ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0);
IF @CurrentVersion NOT IN (5, 6)
    THROW 53080, 'REL-139 requires schema version 5.', 1;

IF OBJECT_ID(N'dbo.ReviewDuplicateArchive', N'U') IS NULL
    THROW 53081, 'REL-139 preflight failed: review quarantine is missing.', 1;
IF OBJECT_ID(N'dbo.usp_Review_Save', N'P') IS NULL
    THROW 53082, 'REL-139 preflight failed: safe review save procedure is missing.', 1;
IF OBJECT_ID(N'dbo.usp_AtRiskReviewQueue_Get', N'P') IS NULL
    THROW 53083, 'REL-139 preflight failed: bounded queue procedure is missing.', 1;
IF OBJECT_ID(N'dbo.usp_ReviewAssignment_Reassign', N'P') IS NULL
    THROW 53084, 'REL-139 preflight failed: reassignment procedure is missing.', 1;
IF OBJECT_ID(N'dbo.usp_ReviewReminder_Create', N'P') IS NULL
    THROW 53085, 'REL-139 preflight failed: reminder procedure is missing.', 1;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.Review')
      AND name = N'UX_Review_AssignmentId'
      AND is_unique = 1
)
    THROW 53086, 'REL-139 preflight failed: review uniqueness invariant is missing.', 1;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.NotificationLog')
      AND name = N'UX_NotificationLog_IdempotencyKey'
      AND is_unique = 1
)
    THROW 53087, 'REL-139 preflight failed: reminder uniqueness invariant is missing.', 1;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Triage_ReleaseSmokeTest
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 6
        THROW 51080, 'Release smoke failed: schema version is not 6.', 1;
    IF (SELECT COUNT(*) FROM dbo.Abstract) <> 10000
        THROW 51081, 'Release smoke failed: expected 10,000 fictional abstracts.', 1;
    IF (SELECT COUNT(*) FROM dbo.UserAccount WHERE UserRole = 'Reviewer') <> 250
        THROW 51082, 'Release smoke failed: expected 250 fictional reviewers.', 1;
    IF (SELECT COUNT(*) FROM dbo.ReviewAssignment) NOT BETWEEN 20000 AND 20010
        THROW 51083, 'Release smoke failed: assignment count is outside the seeded range.', 1;
    IF EXISTS
    (
        SELECT AssignmentId
        FROM dbo.Review
        GROUP BY AssignmentId
        HAVING COUNT(*) > 1
    )
        THROW 51084, 'Release smoke failed: duplicate logical reviews exist.', 1;
    IF EXISTS
    (
        SELECT IdempotencyKey
        FROM dbo.NotificationLog
        GROUP BY IdempotencyKey
        HAVING COUNT(*) > 1
    )
        THROW 51085, 'Release smoke failed: duplicate logical reminders exist.', 1;
    IF OBJECT_ID(N'dbo.ReviewDuplicateArchive', N'U') IS NULL
        THROW 51086, 'Release smoke failed: review quarantine is missing.', 1;

    EXEC dbo.usp_AtRiskReviewQueue_Get
        @PageNumber = 1,
        @PageSize = 1,
        @AsOfUtc = '2027-03-16T12:00:00';

    SELECT
        'REL139_SMOKE_OK' AS SmokeStatus,
        (SELECT MAX(VersionNumber) FROM dbo.SchemaVersion) AS SchemaVersion,
        (SELECT COUNT(*) FROM dbo.Abstract) AS AbstractCount,
        (SELECT COUNT(*) FROM dbo.ReviewAssignment) AS AssignmentCount,
        (SELECT COUNT(*) FROM dbo.ReviewDuplicateArchive) AS QuarantinedReviewCount;
END;
GO

SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;

    IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = 6)
    BEGIN
        IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 5
            THROW 53088, 'REL-139 version changed after preflight.', 1;
        IF OBJECT_ID(N'dbo.usp_Triage_ReleaseSmokeTest', N'P') IS NULL
            THROW 53089, 'REL-139 smoke procedure was not created.', 1;

        INSERT dbo.SchemaVersion (VersionNumber, Description)
        VALUES (6, N'REL-139 safe local release controls');
    END;

    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
GO
