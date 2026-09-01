USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 6
    THROW 53106, 'REL-139 rollback requires schema version 6.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    DROP PROCEDURE IF EXISTS dbo.usp_Triage_ReleaseSmokeTest;
    DELETE dbo.SchemaVersion WHERE VersionNumber = 6;

    IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 5
        THROW 53107, 'REL-139 rollback did not restore version 5.', 1;

    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
GO
