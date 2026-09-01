USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = 3)
    THROW 54100, 'PERF-112 schema version is missing.', 1;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.ReviewAssignment')
      AND name = N'IX_ReviewAssignment_Abstract_Status_Due'
)
    THROW 54101, 'Assignment queue index is missing.', 1;

CREATE TABLE #Actual
(
    AbstractId int,
    Title nvarchar(300),
    Track nvarchar(80),
    RequiredReviewCount tinyint,
    CompletedReviewCount int,
    AssignmentSummary nvarchar(max),
    ActionAssignmentId int NULL
);

INSERT #Actual
EXEC dbo.usp_AtRiskReviewQueue_Get
    @PageNumber = 1,
    @PageSize = 50,
    @AsOfUtc = '2027-03-16T12:00:00';

IF (SELECT COUNT(*) FROM #Actual) <> 50
    THROW 54102, 'Default queue page is not bounded to 50 rows.', 1;
IF (SELECT COUNT(DISTINCT AbstractId) FROM #Actual) <> 50
    THROW 54103, 'Queue page contains duplicate abstracts.', 1;

;WITH Completed AS
(
    SELECT assignment.AbstractId, COUNT_BIG(*) AS CompletedReviewCount
    FROM dbo.ReviewAssignment assignment
    INNER JOIN dbo.Review reviewRow ON reviewRow.AssignmentId = assignment.AssignmentId AND reviewRow.IsFinal = 1
    GROUP BY assignment.AbstractId
), Expected AS
(
    SELECT TOP (50)
        abstractRow.AbstractId,
        abstractRow.Title,
        abstractRow.Track,
        conference.RequiredReviewCount,
        CONVERT(int, ISNULL(completed.CompletedReviewCount, 0)) AS CompletedReviewCount
    FROM dbo.Abstract abstractRow
    INNER JOIN dbo.Conference conference ON conference.ConferenceId = abstractRow.ConferenceId
    LEFT JOIN Completed completed ON completed.AbstractId = abstractRow.AbstractId
    WHERE abstractRow.Status = 'Active'
      AND ISNULL(completed.CompletedReviewCount, 0) < conference.RequiredReviewCount
    ORDER BY abstractRow.AbstractId
)
SELECT AbstractId, Title, Track, RequiredReviewCount, CompletedReviewCount
INTO #Expected
FROM Expected;

IF EXISTS
(
    SELECT AbstractId, Title, Track, RequiredReviewCount, CompletedReviewCount FROM #Actual
    EXCEPT
    SELECT AbstractId, Title, Track, RequiredReviewCount, CompletedReviewCount FROM #Expected
)
OR EXISTS
(
    SELECT AbstractId, Title, Track, RequiredReviewCount, CompletedReviewCount FROM #Expected
    EXCEPT
    SELECT AbstractId, Title, Track, RequiredReviewCount, CompletedReviewCount FROM #Actual
)
    THROW 54104, 'Optimized queue differs from the independent reference page.', 1;

BEGIN TRY
    EXEC dbo.usp_AtRiskReviewQueue_Get @PageSize = 101;
    THROW 54105, 'Unbounded page size unexpectedly succeeded.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 54105 THROW;
    IF ERROR_NUMBER() <> 51022 THROW;
END CATCH;

TRUNCATE TABLE #Actual;
INSERT #Actual
EXEC dbo.usp_AtRiskReviewQueue_Get
    @Track = N'Clinical Methods''; DROP TABLE dbo.Abstract;--',
    @PageNumber = 1,
    @PageSize = 50,
    @AsOfUtc = '2027-03-16T12:00:00';
IF EXISTS (SELECT 1 FROM #Actual) OR OBJECT_ID(N'dbo.Abstract', N'U') IS NULL
    THROW 54106, 'Track filter was not treated as a literal value.', 1;

PRINT 'PERF112_SQL_OK';
GO
