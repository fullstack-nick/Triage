USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.ReviewAssignment')
      AND name = N'UX_ReviewAssignment_AbstractReviewer'
      AND is_unique = 1
)
    THROW 54200, 'Abstract/reviewer assignment uniqueness is missing.', 1;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.ReviewAssignment')
      AND name = N'UX_ReviewAssignment_ReassignedFrom'
      AND is_unique = 1
      AND has_filter = 1
)
    THROW 54201, 'Predecessor replacement uniqueness is missing.', 1;

DECLARE @ConflictAssignmentId int = 83;
DECLARE @CurrentReviewerId int = (SELECT ReviewerUserId FROM dbo.ReviewAssignment WHERE AssignmentId = @ConflictAssignmentId);
DECLARE @ExistingReviewerId int = (SELECT ReviewerUserId FROM dbo.ReviewAssignment WHERE AssignmentId = 84);
CREATE TABLE #Candidates (UserId int, DisplayName nvarchar(120));
INSERT #Candidates
EXEC dbo.usp_ReviewReassignment_Candidates_Get @ConflictAssignmentId, 1, 0;

IF EXISTS (SELECT 1 FROM #Candidates WHERE UserId IN (@CurrentReviewerId, @ExistingReviewerId, 200))
    THROW 54202, 'Candidate list included the current, prior, or conflicted reviewer.', 1;
IF NOT EXISTS (SELECT 1 FROM #Candidates)
    THROW 54203, 'Candidate list unexpectedly returned no eligible reviewers.', 1;

BEGIN TRY
    EXEC dbo.usp_ReviewAssignment_Reassign @ConflictAssignmentId, @CurrentReviewerId, 1;
    THROW 54204, 'No-op reassignment unexpectedly succeeded.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 54204 THROW;
    IF ERROR_NUMBER() <> 51032 THROW;
END CATCH;

BEGIN TRY
    EXEC dbo.usp_ReviewAssignment_Reassign @ConflictAssignmentId, 200, 1;
    THROW 54205, 'Conflict reassignment unexpectedly succeeded.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 54205 THROW;
    IF ERROR_NUMBER() <> 51035 THROW;
END CATCH;

BEGIN TRY
    EXEC dbo.usp_ReviewAssignment_Reassign @ConflictAssignmentId, @ExistingReviewerId, 1;
    THROW 54206, 'Prior reviewer reassignment unexpectedly succeeded.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 54206 THROW;
    IF ERROR_NUMBER() <> 51036 THROW;
END CATCH;

DECLARE @CompletedAssignmentId int = 4;
DECLARE @CompletedTarget int = (SELECT TOP (1) UserId FROM #Candidates ORDER BY UserId);
BEGIN TRY
    EXEC dbo.usp_ReviewAssignment_Reassign @CompletedAssignmentId, @CompletedTarget, 1;
    THROW 54207, 'Completed reassignment unexpectedly succeeded.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 54207 THROW;
    IF ERROR_NUMBER() <> 51033 THROW;
END CATCH;

BEGIN TRANSACTION;

DECLARE @SuccessAssignmentId int = 19994;
DECLARE @SuccessAbstractId int = (SELECT AbstractId FROM dbo.ReviewAssignment WHERE AssignmentId = @SuccessAssignmentId);
DECLARE @SuccessOldReviewerId int = (SELECT ReviewerUserId FROM dbo.ReviewAssignment WHERE AssignmentId = @SuccessAssignmentId);
DECLARE @SuccessNewReviewerId int =
(
    SELECT TOP (1) account.UserId
    FROM dbo.UserAccount account
    WHERE account.UserRole = 'Reviewer'
      AND account.IsActive = 1
      AND NOT EXISTS
      (
          SELECT 1 FROM dbo.ReviewAssignment assignment
          WHERE assignment.AbstractId = @SuccessAbstractId AND assignment.ReviewerUserId = account.UserId
      )
      AND NOT EXISTS
      (
          SELECT 1 FROM dbo.ReviewerConflict conflictRow
          WHERE conflictRow.AbstractId = @SuccessAbstractId AND conflictRow.ReviewerUserId = account.UserId
      )
    ORDER BY account.UserId
);

CREATE TABLE #Result (NewAssignmentId int, ReassignedFromAssignmentId int, NewReviewerUserId int, AssignedAtUtc datetime2(3), DueAtUtc datetime2(3));
INSERT #Result
EXEC dbo.usp_ReviewAssignment_Reassign @SuccessAssignmentId, @SuccessNewReviewerId, 1;

DECLARE @NewAssignmentId int = (SELECT NewAssignmentId FROM #Result);
IF (SELECT Status FROM dbo.ReviewAssignment WHERE AssignmentId = @SuccessAssignmentId) <> 'Reassigned'
    THROW 54208, 'Predecessor assignment was not preserved and closed.', 1;
IF NOT EXISTS
(
    SELECT 1 FROM dbo.ReviewAssignment
    WHERE AssignmentId = @NewAssignmentId
      AND ReassignedFromAssignmentId = @SuccessAssignmentId
      AND ReviewerUserId = @SuccessNewReviewerId
      AND Status = 'Assigned'
)
    THROW 54209, 'Linked replacement assignment is incorrect.', 1;
IF NOT EXISTS
(
    SELECT 1 FROM dbo.AuditEvent
    WHERE EntityType = 'ReviewAssignment'
      AND EntityId = @SuccessAssignmentId
      AND Action = 'ReviewReassigned'
      AND PerformedByUserId = 1
      AND JSON_VALUE(Details, '$.newAssignmentId') = CONVERT(varchar(20), @NewAssignmentId)
      AND JSON_VALUE(Details, '$.oldReviewerUserId') = CONVERT(varchar(20), @SuccessOldReviewerId)
      AND JSON_VALUE(Details, '$.newReviewerUserId') = CONVERT(varchar(20), @SuccessNewReviewerId)
)
    THROW 54210, 'Reassignment audit event is incomplete.', 1;

ROLLBACK;

PRINT 'FEAT124_SQL_OK';
GO
