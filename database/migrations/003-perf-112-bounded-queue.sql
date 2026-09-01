USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = 3)
    RETURN;

IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 2
    THROW 53020, 'PERF-112 requires schema version 2.', 1;

BEGIN TRANSACTION;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.ReviewAssignment')
      AND name = N'IX_ReviewAssignment_Abstract_Status_Due'
)
BEGIN
    CREATE INDEX IX_ReviewAssignment_Abstract_Status_Due
        ON dbo.ReviewAssignment(AbstractId, Status, DueAtUtc, AssignmentId)
        INCLUDE (ReviewerUserId);
END;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.Review')
      AND name = N'IX_Review_Final_Assignment'
)
BEGIN
    CREATE INDEX IX_Review_Final_Assignment
        ON dbo.Review(IsFinal, AssignmentId);
END;

COMMIT;
GO

CREATE OR ALTER PROCEDURE dbo.usp_AtRiskReviewQueue_Get
    @AbstractId int = NULL,
    @Track nvarchar(80) = NULL,
    @Reviewer nvarchar(120) = NULL,
    @ReviewStatus varchar(20) = NULL,
    @PageNumber int = 1,
    @PageSize int = 50,
    @AsOfUtc datetime2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @AbstractId IS NOT NULL AND @AbstractId < 1
        THROW 51020, 'Abstract ID must be positive.', 1;
    IF @PageNumber < 1 OR @PageNumber > 2000
        THROW 51021, 'Page number is outside the supported range.', 1;
    IF @PageSize < 1 OR @PageSize > 100
        THROW 51022, 'Page size must be from 1 through 100.', 1;
    IF @ReviewStatus IS NOT NULL AND @ReviewStatus NOT IN ('Assigned', 'Draft', 'Completed', 'Conflict')
        THROW 51023, 'Review status is not supported.', 1;

    SET @AsOfUtc = ISNULL(@AsOfUtc, SYSUTCDATETIME());
    DECLARE @Offset bigint = CONVERT(bigint, @PageNumber - 1) * @PageSize;

    CREATE TABLE #QueuePage
    (
        AbstractId int NOT NULL PRIMARY KEY,
        Title nvarchar(300) NOT NULL,
        Track nvarchar(80) NOT NULL,
        RequiredReviewCount tinyint NOT NULL,
        CompletedReviewCount int NOT NULL
    );

    ;WITH CompletedReviews AS
    (
        SELECT
            assignment.AbstractId,
            COUNT_BIG(*) AS CompletedReviewCount
        FROM dbo.Review reviewRow
        INNER JOIN dbo.ReviewAssignment assignment ON assignment.AssignmentId = reviewRow.AssignmentId
        WHERE reviewRow.IsFinal = 1
        GROUP BY assignment.AbstractId
    )
    INSERT #QueuePage (AbstractId, Title, Track, RequiredReviewCount, CompletedReviewCount)
    SELECT
        abstractRow.AbstractId,
        abstractRow.Title,
        abstractRow.Track,
        conference.RequiredReviewCount,
        CONVERT(int, ISNULL(completed.CompletedReviewCount, 0))
    FROM dbo.Abstract abstractRow
    INNER JOIN dbo.Conference conference ON conference.ConferenceId = abstractRow.ConferenceId
    LEFT JOIN CompletedReviews completed ON completed.AbstractId = abstractRow.AbstractId
    WHERE abstractRow.Status = 'Active'
      AND (@AbstractId IS NULL OR abstractRow.AbstractId = @AbstractId)
      AND (@Track IS NULL OR abstractRow.Track = @Track)
      AND ISNULL(completed.CompletedReviewCount, 0) < conference.RequiredReviewCount
      AND
      (
          @Reviewer IS NULL
          OR EXISTS
          (
              SELECT 1
              FROM dbo.ReviewAssignment reviewerAssignment
              INNER JOIN dbo.UserAccount reviewerAccount ON reviewerAccount.UserId = reviewerAssignment.ReviewerUserId
              WHERE reviewerAssignment.AbstractId = abstractRow.AbstractId
                AND reviewerAccount.DisplayName LIKE N'%' + @Reviewer + N'%'
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
    ORDER BY abstractRow.AbstractId
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    ;WITH AssignmentRows AS
    (
        SELECT
            pageRow.AbstractId,
            assignment.AssignmentId,
            assignment.Status,
            assignment.DueAtUtc,
            account.DisplayName
        FROM #QueuePage pageRow
        INNER JOIN dbo.ReviewAssignment assignment ON assignment.AbstractId = pageRow.AbstractId
        INNER JOIN dbo.UserAccount account ON account.UserId = assignment.ReviewerUserId
        WHERE assignment.Status <> 'Reassigned'
    ),
    AssignmentSummary AS
    (
        SELECT
            assignment.AbstractId,
            STRING_AGG
            (
                CONCAT
                (
                    CASE
                        WHEN assignment.Status IN ('Assigned', 'Draft') AND assignment.DueAtUtc < @AsOfUtc
                            THEN N'OVERDUE — '
                        ELSE N''
                    END,
                    assignment.DisplayName,
                    N' — ',
                    assignment.Status,
                    N' — ',
                    CONVERT(nvarchar(19), assignment.DueAtUtc, 126)
                ),
                N'; '
            ) WITHIN GROUP (ORDER BY assignment.DueAtUtc, assignment.AssignmentId) AS SummaryText
        FROM AssignmentRows assignment
        GROUP BY assignment.AbstractId
    ),
    OpenAssignment AS
    (
        SELECT
            assignment.AbstractId,
            assignment.AssignmentId,
            ROW_NUMBER() OVER
            (
                PARTITION BY assignment.AbstractId
                ORDER BY assignment.DueAtUtc, assignment.AssignmentId
            ) AS ActionRank
        FROM AssignmentRows assignment
        WHERE assignment.Status IN ('Assigned', 'Draft')
    )
    SELECT
        pageRow.AbstractId,
        pageRow.Title,
        pageRow.Track,
        pageRow.RequiredReviewCount,
        pageRow.CompletedReviewCount,
        summaryRow.SummaryText AS AssignmentSummary,
        actionRow.AssignmentId AS ActionAssignmentId
    FROM #QueuePage pageRow
    LEFT JOIN AssignmentSummary summaryRow ON summaryRow.AbstractId = pageRow.AbstractId
    LEFT JOIN OpenAssignment actionRow ON actionRow.AbstractId = pageRow.AbstractId AND actionRow.ActionRank = 1
    ORDER BY pageRow.AbstractId;
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = 3)
BEGIN
    INSERT dbo.SchemaVersion (VersionNumber, Description)
    VALUES (3, N'PERF-112 bounded set-based review queue');
END;
GO
