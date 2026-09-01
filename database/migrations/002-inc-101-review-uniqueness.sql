USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = 2)
    RETURN;

IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 1
    THROW 53001, 'INC-101 requires schema version 1.', 1;

BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.ReviewDuplicateArchive', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReviewDuplicateArchive
    (
        ReviewDuplicateArchiveId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ReviewDuplicateArchive PRIMARY KEY,
        OriginalReviewId int NOT NULL,
        AssignmentId int NOT NULL,
        Score tinyint NULL,
        Comment nvarchar(2000) NULL,
        IsFinal bit NOT NULL,
        CreatedAtUtc datetime2(3) NOT NULL,
        UpdatedAtUtc datetime2(3) NOT NULL,
        ArchivedAtUtc datetime2(3) NOT NULL CONSTRAINT DF_ReviewDuplicateArchive_ArchivedAtUtc DEFAULT SYSUTCDATETIME(),
        ArchiveReason varchar(80) NOT NULL,
        CONSTRAINT UQ_ReviewDuplicateArchive_OriginalReviewId UNIQUE (OriginalReviewId),
        CONSTRAINT CK_ReviewDuplicateArchive_Score CHECK (Score IS NULL OR Score BETWEEN 1 AND 5)
    );
END;

DECLARE @PreMigrationReviewCount int = (SELECT COUNT(*) FROM dbo.Review);

;WITH RankedReviews AS
(
    SELECT
        r.ReviewId,
        ROW_NUMBER() OVER
        (
            PARTITION BY r.AssignmentId
            ORDER BY r.IsFinal DESC, r.UpdatedAtUtc DESC, r.ReviewId DESC
        ) AS SurvivorRank
    FROM dbo.Review r
)
SELECT r.ReviewId, r.AssignmentId, r.Score, r.Comment, r.IsFinal, r.CreatedAtUtc, r.UpdatedAtUtc
INTO #SurplusReview
FROM dbo.Review r
INNER JOIN RankedReviews ranked ON ranked.ReviewId = r.ReviewId
WHERE ranked.SurvivorRank > 1;

INSERT dbo.ReviewDuplicateArchive
(
    OriginalReviewId,
    AssignmentId,
    Score,
    Comment,
    IsFinal,
    CreatedAtUtc,
    UpdatedAtUtc,
    ArchiveReason
)
SELECT
    surplus.ReviewId,
    surplus.AssignmentId,
    surplus.Score,
    surplus.Comment,
    surplus.IsFinal,
    surplus.CreatedAtUtc,
    surplus.UpdatedAtUtc,
    'INC-101 deterministic surplus row'
FROM #SurplusReview surplus
WHERE NOT EXISTS
(
    SELECT 1
    FROM dbo.ReviewDuplicateArchive archive
    WHERE archive.OriginalReviewId = surplus.ReviewId
);

DECLARE @ArchivedNow int = @@ROWCOUNT;

DELETE reviewRow
FROM dbo.Review reviewRow
INNER JOIN #SurplusReview surplus ON surplus.ReviewId = reviewRow.ReviewId;

IF @@ROWCOUNT <> @ArchivedNow
    THROW 53002, 'INC-101 archive/delete count mismatch.', 1;

IF @PreMigrationReviewCount <> (SELECT COUNT(*) FROM dbo.Review) + @ArchivedNow
    THROW 53003, 'INC-101 conservation check failed.', 1;

IF EXISTS
(
    SELECT AssignmentId
    FROM dbo.Review
    GROUP BY AssignmentId
    HAVING COUNT(*) > 1
)
    THROW 53004, 'Duplicate reviews remain after cleanup.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.Review')
      AND name = N'UX_Review_AssignmentId'
)
BEGIN
    CREATE UNIQUE INDEX UX_Review_AssignmentId ON dbo.Review(AssignmentId);
END;

COMMIT;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Review_Save
    @AssignmentId int,
    @ReviewerUserId int,
    @Score tinyint = NULL,
    @Comment nvarchar(2000) = NULL,
    @IsFinal bit
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Score IS NOT NULL AND @Score NOT BETWEEN 1 AND 5
        THROW 51002, 'Score must be between 1 and 5.', 1;
    IF @IsFinal = 1 AND @Score IS NULL
        THROW 51002, 'A final review requires a score.', 1;
    IF LEN(@Comment) > 2000
        THROW 51004, 'Comment is too long.', 1;

    BEGIN TRANSACTION;

    DECLARE @AssignmentStatus varchar(20);
    SELECT @AssignmentStatus = Status
    FROM dbo.ReviewAssignment WITH (UPDLOCK, HOLDLOCK)
    WHERE AssignmentId = @AssignmentId
      AND ReviewerUserId = @ReviewerUserId
      AND Status <> 'Reassigned';

    IF @AssignmentStatus IS NULL
        THROW 51001, 'Assignment not found or not editable.', 1;

    DECLARE @ReviewId int, @ExistingScore tinyint, @ExistingComment nvarchar(2000), @ExistingIsFinal bit;
    SELECT
        @ReviewId = ReviewId,
        @ExistingScore = Score,
        @ExistingComment = Comment,
        @ExistingIsFinal = IsFinal
    FROM dbo.Review WITH (UPDLOCK, HOLDLOCK)
    WHERE AssignmentId = @AssignmentId;

    IF @ExistingIsFinal = 1
    BEGIN
        IF @IsFinal = 1
           AND ISNULL(@ExistingScore, 0) = ISNULL(@Score, 0)
           AND ISNULL(@ExistingComment, N'') = ISNULL(NULLIF(@Comment, N''), N'')
        BEGIN
            COMMIT;
            SELECT ReviewId, AssignmentId, Score, Comment, IsFinal
            FROM dbo.Review
            WHERE ReviewId = @ReviewId;
            RETURN;
        END;
        THROW 51003, 'A final review cannot be changed.', 1;
    END;

    IF @AssignmentStatus NOT IN ('Assigned', 'Draft')
        THROW 51001, 'Assignment not found or not editable.', 1;

    IF @ReviewId IS NULL
    BEGIN
        INSERT dbo.Review (AssignmentId, Score, Comment, IsFinal)
        VALUES (@AssignmentId, @Score, NULLIF(@Comment, N''), @IsFinal);
        SET @ReviewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE dbo.Review
        SET Score = @Score,
            Comment = NULLIF(@Comment, N''),
            IsFinal = @IsFinal,
            UpdatedAtUtc = SYSUTCDATETIME()
        WHERE ReviewId = @ReviewId;
    END;

    UPDATE dbo.ReviewAssignment
    SET Status = CASE WHEN @IsFinal = 1 THEN 'Completed' ELSE 'Draft' END
    WHERE AssignmentId = @AssignmentId;

    IF @IsFinal = 1
    BEGIN
        INSERT dbo.AuditEvent (EntityType, EntityId, Action, PerformedByUserId, Details)
        VALUES
        (
            'ReviewAssignment',
            @AssignmentId,
            'ReviewFinalized',
            @ReviewerUserId,
            CONCAT(N'{"assignmentId":', @AssignmentId, N',"reviewId":', @ReviewId, N'}')
        );
    END;

    COMMIT;

    SELECT ReviewId, AssignmentId, Score, Comment, IsFinal
    FROM dbo.Review
    WHERE ReviewId = @ReviewId;
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = 2)
BEGIN
    INSERT dbo.SchemaVersion (VersionNumber, Description)
    VALUES (2, N'INC-101 one logical review per assignment');
END;
GO
