USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 4
    THROW 53104, 'FEAT-124 rollback requires schema version 4.', 1;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.ReviewAssignment')
      AND name = N'UX_ReviewAssignment_AbstractReviewer'
      AND is_unique = 1
)
    THROW 53114, 'FEAT-124 rollback refuses to weaken assignment uniqueness.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP PROCEDURE IF EXISTS dbo.usp_ReviewAssignment_Reassign;
    DROP PROCEDURE IF EXISTS dbo.usp_ReviewReassignment_Candidates_Get;
    DELETE dbo.SchemaVersion WHERE VersionNumber = 4;

    IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 3
        THROW 53124, 'FEAT-124 rollback did not restore version 3.', 1;

    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
GO
