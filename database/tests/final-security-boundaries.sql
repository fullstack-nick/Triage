USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF EXISTS
(
    SELECT 1
    FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID(N'dbo.usp_ReviewAssignment_Get'), 0)
    WHERE name IN (N'SubmittingAuthorName', N'SubmittingAuthorEmail')
)
    THROW 54001, 'Reviewer projection exposes private author columns.', 1;

DECLARE @OwnedRead TABLE
(
    AssignmentId int,
    AbstractId int,
    Title nvarchar(300),
    Body nvarchar(max),
    Track nvarchar(80),
    DueAtUtc datetime2(3),
    Status varchar(20),
    ReviewId int,
    Score tinyint,
    Comment nvarchar(2000),
    IsFinal bit
);
DECLARE @ForeignRead TABLE
(
    AssignmentId int,
    AbstractId int,
    Title nvarchar(300),
    Body nvarchar(max),
    Track nvarchar(80),
    DueAtUtc datetime2(3),
    Status varchar(20),
    ReviewId int,
    Score tinyint,
    Comment nvarchar(2000),
    IsFinal bit
);
DECLARE @MissingRead TABLE
(
    AssignmentId int,
    AbstractId int,
    Title nvarchar(300),
    Body nvarchar(max),
    Track nvarchar(80),
    DueAtUtc datetime2(3),
    Status varchar(20),
    ReviewId int,
    Score tinyint,
    Comment nvarchar(2000),
    IsFinal bit
);

INSERT @OwnedRead EXEC dbo.usp_ReviewAssignment_Get @AssignmentId=1, @ReviewerUserId=2;
INSERT @ForeignRead EXEC dbo.usp_ReviewAssignment_Get @AssignmentId=2, @ReviewerUserId=2;
INSERT @MissingRead EXEC dbo.usp_ReviewAssignment_Get @AssignmentId=2000000000, @ReviewerUserId=2;

IF (SELECT COUNT(*) FROM @OwnedRead) <> 1
    THROW 54002, 'Owned assignment was not returned.', 1;
IF (SELECT COUNT(*) FROM @ForeignRead) <> 0 OR (SELECT COUNT(*) FROM @MissingRead) <> 0
    THROW 54003, 'Foreign and missing reads must both reveal no row.', 1;

DECLARE @ForeignErrorNumber int, @ForeignErrorMessage nvarchar(4000), @MissingErrorNumber int, @MissingErrorMessage nvarchar(4000);

BEGIN TRANSACTION;
BEGIN TRY
    EXEC dbo.usp_Review_Save @AssignmentId=2, @ReviewerUserId=2, @Score=3, @Comment=N'foreign write probe', @IsFinal=0;
END TRY
BEGIN CATCH
    SELECT @ForeignErrorNumber=ERROR_NUMBER(), @ForeignErrorMessage=ERROR_MESSAGE();
END CATCH;
IF XACT_STATE() <> 0 ROLLBACK;

BEGIN TRANSACTION;
BEGIN TRY
    EXEC dbo.usp_Review_Save @AssignmentId=2000000000, @ReviewerUserId=2, @Score=3, @Comment=N'missing write probe', @IsFinal=0;
END TRY
BEGIN CATCH
    SELECT @MissingErrorNumber=ERROR_NUMBER(), @MissingErrorMessage=ERROR_MESSAGE();
END CATCH;
IF XACT_STATE() <> 0 ROLLBACK;

IF @ForeignErrorNumber <> 51001 OR @MissingErrorNumber <> 51001 OR @ForeignErrorMessage <> @MissingErrorMessage
    THROW 54004, 'Foreign and missing writes must return the same not-editable result.', 1;

DECLARE @RejectedScores int = 0;
BEGIN TRY
    EXEC dbo.usp_Review_Save @AssignmentId=1, @ReviewerUserId=2, @Score=0, @Comment=N'invalid', @IsFinal=1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 51002 SET @RejectedScores += 1 ELSE THROW;
END CATCH;
BEGIN TRY
    EXEC dbo.usp_Review_Save @AssignmentId=1, @ReviewerUserId=2, @Score=6, @Comment=N'invalid', @IsFinal=1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 51002 SET @RejectedScores += 1 ELSE THROW;
END CATCH;
BEGIN TRY
    EXEC dbo.usp_Review_Save @AssignmentId=1, @ReviewerUserId=2, @Score=NULL, @Comment=N'invalid', @IsFinal=1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 51002 SET @RejectedScores += 1 ELSE THROW;
END CATCH;
IF @RejectedScores <> 3
    THROW 54005, 'Invalid final scores were not rejected.', 1;

SELECT 'FINAL_SECURITY_BOUNDARIES_OK';
GO
