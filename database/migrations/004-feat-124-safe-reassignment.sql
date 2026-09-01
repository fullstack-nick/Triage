USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = 4)
    RETURN;

IF ISNULL((SELECT MAX(VersionNumber) FROM dbo.SchemaVersion), 0) <> 3
    THROW 53040, 'FEAT-124 requires schema version 3.', 1;

IF EXISTS
(
    SELECT AbstractId, ReviewerUserId
    FROM dbo.ReviewAssignment
    GROUP BY AbstractId, ReviewerUserId
    HAVING COUNT(*) > 1
)
    THROW 53041, 'Existing assignment history violates abstract/reviewer uniqueness.', 1;

BEGIN TRANSACTION;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.ReviewAssignment')
      AND name = N'UX_ReviewAssignment_AbstractReviewer'
)
BEGIN
    CREATE UNIQUE INDEX UX_ReviewAssignment_AbstractReviewer
        ON dbo.ReviewAssignment(AbstractId, ReviewerUserId);
END;

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.ReviewAssignment')
      AND name = N'UX_ReviewAssignment_ReassignedFrom'
)
BEGIN
    CREATE UNIQUE INDEX UX_ReviewAssignment_ReassignedFrom
        ON dbo.ReviewAssignment(ReassignedFromAssignmentId)
        WHERE ReassignedFromAssignmentId IS NOT NULL;
END;

COMMIT;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReviewReassignment_Candidates_Get
    @AssignmentId int,
    @PerformedByUserId int,
    @IncludeAudit bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.UserAccount
        WHERE UserId = @PerformedByUserId
          AND UserRole = 'Admin'
          AND IsActive = 1
    )
        THROW 51030, 'Administrator access is required.', 1;

    DECLARE @AbstractId int, @CurrentReviewerUserId int, @AssignmentStatus varchar(20);
    SELECT
        @AbstractId = AbstractId,
        @CurrentReviewerUserId = ReviewerUserId,
        @AssignmentStatus = Status
    FROM dbo.ReviewAssignment
    WHERE AssignmentId = @AssignmentId;

    IF @AbstractId IS NULL
        THROW 51031, 'Assignment was not found.', 1;

    IF @IncludeAudit = 1
    BEGIN
        SELECT TOP (10)
            auditEvent.Action,
            actor.DisplayName AS PerformedBy,
            auditEvent.OccurredAtUtc,
            auditEvent.Details
        FROM dbo.AuditEvent auditEvent
        INNER JOIN dbo.UserAccount actor ON actor.UserId = auditEvent.PerformedByUserId
        WHERE auditEvent.EntityType = 'ReviewAssignment'
          AND auditEvent.EntityId = @AssignmentId
        ORDER BY auditEvent.OccurredAtUtc DESC, auditEvent.AuditEventId DESC;
        RETURN;
    END;

    IF @AssignmentStatus NOT IN ('Assigned', 'Draft')
    BEGIN
        SELECT TOP (0) UserId, DisplayName
        FROM dbo.UserAccount;
        RETURN;
    END;

    SELECT
        candidate.UserId,
        candidate.DisplayName
    FROM dbo.UserAccount candidate
    WHERE candidate.UserRole = 'Reviewer'
      AND candidate.IsActive = 1
      AND candidate.UserId <> @CurrentReviewerUserId
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.ReviewerConflict conflictRow
          WHERE conflictRow.AbstractId = @AbstractId
            AND conflictRow.ReviewerUserId = candidate.UserId
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.ReviewAssignment priorAssignment
          WHERE priorAssignment.AbstractId = @AbstractId
            AND priorAssignment.ReviewerUserId = candidate.UserId
      )
    ORDER BY candidate.DisplayName, candidate.UserId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReviewAssignment_Reassign
    @AssignmentId int,
    @NewReviewerUserId int,
    @PerformedByUserId int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.UserAccount WITH (UPDLOCK, HOLDLOCK)
            WHERE UserId = @PerformedByUserId
              AND UserRole = 'Admin'
              AND IsActive = 1
        )
            THROW 51030, 'Administrator access is required.', 1;

        DECLARE @AbstractId int, @OldReviewerUserId int, @OldStatus varchar(20);
        SELECT
            @AbstractId = AbstractId,
            @OldReviewerUserId = ReviewerUserId,
            @OldStatus = Status
        FROM dbo.ReviewAssignment WITH (UPDLOCK, HOLDLOCK)
        WHERE AssignmentId = @AssignmentId;

        IF @AbstractId IS NULL
            THROW 51031, 'Assignment was not found or is no longer open.', 1;
        IF @OldStatus = 'Completed' OR EXISTS (SELECT 1 FROM dbo.Review WHERE AssignmentId = @AssignmentId AND IsFinal = 1)
            THROW 51033, 'A completed assignment cannot be reassigned.', 1;
        IF @OldStatus NOT IN ('Assigned', 'Draft')
            THROW 51031, 'Assignment was not found or is no longer open.', 1;
        IF @NewReviewerUserId = @OldReviewerUserId
            THROW 51032, 'Choose a different reviewer.', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.UserAccount WITH (UPDLOCK, HOLDLOCK)
            WHERE UserId = @NewReviewerUserId
              AND UserRole = 'Reviewer'
              AND IsActive = 1
        )
            THROW 51034, 'The target reviewer is not eligible.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM dbo.ReviewerConflict WITH (UPDLOCK, HOLDLOCK)
            WHERE AbstractId = @AbstractId
              AND ReviewerUserId = @NewReviewerUserId
        )
            THROW 51035, 'The target reviewer has declared a conflict.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM dbo.ReviewAssignment WITH (UPDLOCK, HOLDLOCK)
            WHERE AbstractId = @AbstractId
              AND ReviewerUserId = @NewReviewerUserId
        )
            THROW 51036, 'The target reviewer already has assignment history for this abstract.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM dbo.ReviewAssignment WITH (UPDLOCK, HOLDLOCK)
            WHERE ReassignedFromAssignmentId = @AssignmentId
        )
            THROW 51037, 'This assignment already has a replacement.', 1;

        UPDATE dbo.ReviewAssignment
        SET Status = 'Reassigned'
        WHERE AssignmentId = @AssignmentId;

        IF TRY_CONVERT(bit, SESSION_CONTEXT(N'Triage.ForceReassignFailure')) = 1
            THROW 51038, 'Forced reassignment failure for local verification.', 1;

        DECLARE @AssignedAtUtc datetime2(3) = SYSUTCDATETIME();
        DECLARE @NewDueAtUtc datetime2(3) = DATEADD(day, 7, @AssignedAtUtc);
        DECLARE @NewAssignmentId int;

        INSERT dbo.ReviewAssignment
        (
            AbstractId,
            ReviewerUserId,
            AssignedAtUtc,
            DueAtUtc,
            Status,
            ReassignedFromAssignmentId
        )
        VALUES
        (
            @AbstractId,
            @NewReviewerUserId,
            @AssignedAtUtc,
            @NewDueAtUtc,
            'Assigned',
            @AssignmentId
        );
        SET @NewAssignmentId = SCOPE_IDENTITY();

        INSERT dbo.AuditEvent (EntityType, EntityId, Action, PerformedByUserId, Details)
        VALUES
        (
            'ReviewAssignment',
            @AssignmentId,
            'ReviewReassigned',
            @PerformedByUserId,
            CONCAT
            (
                N'{"oldAssignmentId":', @AssignmentId,
                N',"newAssignmentId":', @NewAssignmentId,
                N',"oldReviewerUserId":', @OldReviewerUserId,
                N',"newReviewerUserId":', @NewReviewerUserId,
                N'}'
            )
        );

        COMMIT;

        SELECT
            @NewAssignmentId AS NewAssignmentId,
            @AssignmentId AS ReassignedFromAssignmentId,
            @NewReviewerUserId AS NewReviewerUserId,
            @AssignedAtUtc AS AssignedAtUtc,
            @NewDueAtUtc AS DueAtUtc;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = 4)
BEGIN
    INSERT dbo.SchemaVersion (VersionNumber, Description)
    VALUES (4, N'FEAT-124 audited conflict-safe reassignment');
END;
GO
