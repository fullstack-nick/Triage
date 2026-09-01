USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 3
    THROW 53103, 'PERF-112 rollback requires schema version 3.', 1;
GO

-- Restore the version-2 application contract. Supporting indexes remain in
-- place because removing them would add lock time without restoring data.
CREATE OR ALTER PROCEDURE dbo.usp_AtRiskReviewQueue_Get
    @AbstractId int = NULL,
    @Track nvarchar(80) = NULL,
    @Reviewer nvarchar(120) = NULL,
    @ReviewStatus varchar(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        abstractRow.AbstractId,
        abstractRow.Title,
        abstractRow.Track,
        conference.RequiredReviewCount,
        (
            SELECT COUNT(*)
            FROM dbo.ReviewAssignment countAssignment
            INNER JOIN dbo.Review countReview ON countReview.AssignmentId = countAssignment.AssignmentId
            WHERE countAssignment.AbstractId = abstractRow.AbstractId
              AND countReview.IsFinal = 1
        ) AS CompletedReviewCount,
        (
            SELECT STRING_AGG(CONCAT(account.DisplayName, N' — ', assignment.Status, N' — ', CONVERT(nvarchar(19), assignment.DueAtUtc, 126)), N'; ')
            FROM dbo.ReviewAssignment assignment
            INNER JOIN dbo.UserAccount account ON account.UserId = assignment.ReviewerUserId
            WHERE assignment.AbstractId = abstractRow.AbstractId
              AND assignment.Status <> 'Reassigned'
        ) AS AssignmentSummary,
        (
            SELECT TOP (1) actionAssignment.AssignmentId
            FROM dbo.ReviewAssignment actionAssignment
            WHERE actionAssignment.AbstractId = abstractRow.AbstractId
              AND actionAssignment.Status IN ('Assigned', 'Draft')
            ORDER BY actionAssignment.DueAtUtc, actionAssignment.AssignmentId
        ) AS ActionAssignmentId
    FROM dbo.Abstract abstractRow
    INNER JOIN dbo.Conference conference ON conference.ConferenceId = abstractRow.ConferenceId
    WHERE abstractRow.Status = 'Active'
      AND (@AbstractId IS NULL OR abstractRow.AbstractId = @AbstractId)
      AND (@Track IS NULL OR abstractRow.Track = @Track)
      AND
      (
          @Reviewer IS NULL
          OR EXISTS
          (
              SELECT 1
              FROM dbo.ReviewAssignment filterAssignment
              INNER JOIN dbo.UserAccount filterAccount ON filterAccount.UserId = filterAssignment.ReviewerUserId
              WHERE filterAssignment.AbstractId = abstractRow.AbstractId
                AND filterAccount.DisplayName LIKE N'%' + @Reviewer + N'%'
          )
      )
      AND
      (
          @ReviewStatus IS NULL
          OR EXISTS
          (
              SELECT 1
              FROM dbo.ReviewAssignment statusAssignment
              WHERE statusAssignment.AbstractId = abstractRow.AbstractId
                AND statusAssignment.Status = @ReviewStatus
          )
      )
      AND
      (
          SELECT COUNT(*)
          FROM dbo.ReviewAssignment riskAssignment
          INNER JOIN dbo.Review riskReview ON riskReview.AssignmentId = riskAssignment.AssignmentId
          WHERE riskAssignment.AbstractId = abstractRow.AbstractId
            AND riskReview.IsFinal = 1
      ) < conference.RequiredReviewCount
    ORDER BY abstractRow.AbstractId;
END;
GO

SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;
    DELETE dbo.SchemaVersion WHERE VersionNumber = 3;
    IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 2
        THROW 53113, 'PERF-112 rollback did not restore version 2.', 1;
    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
GO
