USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 2
    THROW 53102, 'INC-101 rollback requires schema version 2.', 1;
IF OBJECT_ID(N'dbo.ReviewDuplicateArchive', N'U') IS NULL
    THROW 53112, 'INC-101 rollback refuses to discard the review quarantine.', 1;
IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.Review')
      AND name = N'UX_Review_AssignmentId'
      AND is_unique = 1
)
    THROW 53122, 'INC-101 rollback refuses to weaken review uniqueness.', 1;

-- The safe save procedure has the legacy call signature. Keep it, its unique
-- index, and all quarantined rows; only the release ledger entry is reversed.
BEGIN TRY
    BEGIN TRANSACTION;
    DELETE dbo.SchemaVersion WHERE VersionNumber = 2;

    IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 1
        THROW 53132, 'INC-101 rollback did not restore version 1.', 1;
    IF EXISTS
    (
        SELECT AssignmentId
        FROM dbo.Review
        GROUP BY AssignmentId
        HAVING COUNT(*) > 1
    )
        THROW 53142, 'INC-101 rollback detected duplicate logical reviews.', 1;

    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
GO
