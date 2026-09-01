USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.Review')
      AND name = N'UX_Review_AssignmentId'
      AND is_unique = 1
)
    THROW 54001, 'Unique review assignment index is missing.', 1;

IF EXISTS
(
    SELECT AssignmentId
    FROM dbo.Review
    GROUP BY AssignmentId
    HAVING COUNT(*) > 1
)
    THROW 54002, 'Duplicate review rows remain.', 1;

IF NOT EXISTS (SELECT 1 FROM dbo.ReviewDuplicateArchive)
    THROW 54003, 'Expected quarantined baseline duplicates.', 1;

BEGIN TRANSACTION;

DECLARE @AssignmentId int, @ReviewerUserId int, @FirstReviewId int, @SecondReviewId int;
SELECT TOP (1)
    @AssignmentId = assignment.AssignmentId,
    @ReviewerUserId = assignment.ReviewerUserId
FROM dbo.ReviewAssignment assignment
LEFT JOIN dbo.Review reviewRow ON reviewRow.AssignmentId = assignment.AssignmentId
WHERE assignment.Status = 'Assigned'
  AND reviewRow.ReviewId IS NULL
ORDER BY assignment.AssignmentId DESC;

DECLARE @FirstSave TABLE (ReviewId int, AssignmentId int, Score tinyint, Comment nvarchar(2000), IsFinal bit);
INSERT @FirstSave EXEC dbo.usp_Review_Save @AssignmentId, @ReviewerUserId, 3, N'First draft', 0;
SELECT @FirstReviewId = ReviewId FROM @FirstSave;

DECLARE @SecondSave TABLE (ReviewId int, AssignmentId int, Score tinyint, Comment nvarchar(2000), IsFinal bit);
INSERT @SecondSave EXEC dbo.usp_Review_Save @AssignmentId, @ReviewerUserId, 4, N'Updated draft', 0;
SELECT @SecondReviewId = ReviewId FROM @SecondSave;

IF @FirstReviewId <> @SecondReviewId OR (SELECT COUNT(*) FROM dbo.Review WHERE AssignmentId = @AssignmentId) <> 1
    THROW 54004, 'Draft update created a second logical review.', 1;

EXEC dbo.usp_Review_Save @AssignmentId, @ReviewerUserId, 4, N'Final value', 1;
EXEC dbo.usp_Review_Save @AssignmentId, @ReviewerUserId, 4, N'Final value', 1;

BEGIN TRY
    EXEC dbo.usp_Review_Save @AssignmentId, @ReviewerUserId, 5, N'Changed final value', 1;
    THROW 54005, 'Changed post-final update unexpectedly succeeded.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 54005 THROW;
    IF ERROR_NUMBER() <> 51003 THROW;
END CATCH;

IF (SELECT COUNT(*) FROM dbo.AuditEvent WHERE Action = 'ReviewFinalized' AND EntityId = @AssignmentId) <> 1
    THROW 54006, 'Final repeat created a duplicate audit event.', 1;

ROLLBACK;

PRINT 'INC101_SQL_OK';
GO
