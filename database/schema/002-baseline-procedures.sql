USE Triage;
GO

CREATE OR ALTER PROCEDURE dbo.usp_DevelopmentSession_Start
    @Email nvarchar(254),
    @ExpectedRole varchar(16)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        UserId,
        Email,
        DisplayName,
        UserRole,
        CONVERT(varchar(64), CRYPT_GEN_RANDOM(32), 2) AS CsrfToken
    FROM dbo.UserAccount
    WHERE Email = @Email
      AND UserRole = @ExpectedRole
      AND IsActive = 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_AtRiskReviewQueue_Get
    @AbstractId int = NULL,
    @Track nvarchar(80) = NULL,
    @Reviewer nvarchar(120) = NULL,
    @ReviewStatus varchar(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        a.AbstractId,
        a.Title,
        a.Track,
        c.RequiredReviewCount,
        (
            SELECT COUNT(*)
            FROM dbo.ReviewAssignment ra_count
            INNER JOIN dbo.Review r_count ON r_count.AssignmentId = ra_count.AssignmentId
            WHERE ra_count.AbstractId = a.AbstractId
              AND r_count.IsFinal = 1
        ) AS CompletedReviewCount,
        (
            SELECT STRING_AGG(CONCAT(u.DisplayName, N' — ', ra.Status, N' — ', CONVERT(nvarchar(19), ra.DueAtUtc, 126)), N'; ')
            FROM dbo.ReviewAssignment ra
            INNER JOIN dbo.UserAccount u ON u.UserId = ra.ReviewerUserId
            WHERE ra.AbstractId = a.AbstractId
              AND ra.Status <> 'Reassigned'
        ) AS AssignmentSummary,
        (
            SELECT TOP (1) ra_action.AssignmentId
            FROM dbo.ReviewAssignment ra_action
            WHERE ra_action.AbstractId = a.AbstractId
              AND ra_action.Status IN ('Assigned', 'Draft')
            ORDER BY ra_action.DueAtUtc, ra_action.AssignmentId
        ) AS ActionAssignmentId
    FROM dbo.Abstract a
    INNER JOIN dbo.Conference c ON c.ConferenceId = a.ConferenceId
    WHERE a.Status = 'Active'
      AND (@AbstractId IS NULL OR a.AbstractId = @AbstractId)
      AND (@Track IS NULL OR a.Track = @Track)
      AND
      (
          @Reviewer IS NULL
          OR EXISTS
          (
              SELECT 1
              FROM dbo.ReviewAssignment ra_filter
              INNER JOIN dbo.UserAccount u_filter ON u_filter.UserId = ra_filter.ReviewerUserId
              WHERE ra_filter.AbstractId = a.AbstractId
                AND u_filter.DisplayName LIKE N'%' + @Reviewer + N'%'
          )
      )
      AND
      (
          @ReviewStatus IS NULL
          OR EXISTS
          (
              SELECT 1
              FROM dbo.ReviewAssignment ra_status
              WHERE ra_status.AbstractId = a.AbstractId
                AND ra_status.Status = @ReviewStatus
          )
      )
      AND
      (
          SELECT COUNT(*)
          FROM dbo.ReviewAssignment ra_risk
          INNER JOIN dbo.Review r_risk ON r_risk.AssignmentId = ra_risk.AssignmentId
          WHERE ra_risk.AbstractId = a.AbstractId
            AND r_risk.IsFinal = 1
      ) < c.RequiredReviewCount
    ORDER BY a.AbstractId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReviewAssignment_ConflictDeclare
    @AssignmentId int,
    @ReviewerUserId int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

    DECLARE @AbstractId int;

    SELECT @AbstractId = AbstractId
    FROM dbo.ReviewAssignment WITH (UPDLOCK, HOLDLOCK)
    WHERE AssignmentId = @AssignmentId
      AND ReviewerUserId = @ReviewerUserId
      AND Status IN ('Assigned', 'Draft');

    IF @AbstractId IS NULL
        THROW 51010, 'Assignment not found or not editable.', 1;

    IF EXISTS (SELECT 1 FROM dbo.Review WHERE AssignmentId = @AssignmentId AND IsFinal = 1)
        THROW 51011, 'A completed evaluation cannot be marked as a conflict.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.ReviewerConflict
        WHERE AbstractId = @AbstractId
          AND ReviewerUserId = @ReviewerUserId
    )
    BEGIN
        INSERT dbo.ReviewerConflict (AbstractId, ReviewerUserId)
        VALUES (@AbstractId, @ReviewerUserId);
    END;

    UPDATE dbo.ReviewAssignment
    SET Status = 'Conflict'
    WHERE AssignmentId = @AssignmentId;

    INSERT dbo.AuditEvent (EntityType, EntityId, Action, PerformedByUserId, Details)
    VALUES
    (
        'ReviewAssignment',
        @AssignmentId,
        'ConflictDeclared',
        @ReviewerUserId,
        CONCAT(N'{"assignmentId":', @AssignmentId, N',"abstractId":', @AbstractId, N'}')
    );

    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReviewAssignment_Get
    @AssignmentId int,
    @ReviewerUserId int
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ra.AssignmentId,
        ra.AbstractId,
        a.Title,
        a.Body,
        a.Track,
        ra.DueAtUtc,
        ra.Status,
        r.ReviewId,
        r.Score,
        r.Comment,
        r.IsFinal
    FROM dbo.ReviewAssignment ra
    INNER JOIN dbo.Abstract a ON a.AbstractId = ra.AbstractId
    LEFT JOIN dbo.Review r ON r.AssignmentId = ra.AssignmentId
    WHERE ra.AssignmentId = @AssignmentId
      AND ra.ReviewerUserId = @ReviewerUserId
      AND ra.Status <> 'Reassigned';
END;
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

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.ReviewAssignment
        WHERE AssignmentId = @AssignmentId
          AND ReviewerUserId = @ReviewerUserId
          AND Status IN ('Assigned', 'Draft')
    )
        THROW 51001, 'Assignment not found or not editable.', 1;

    IF @IsFinal = 1 AND @Score IS NULL
        THROW 51002, 'A final review requires a score.', 1;

    IF EXISTS (SELECT 1 FROM dbo.Review WHERE AssignmentId = @AssignmentId)
    BEGIN
        UPDATE dbo.Review
        SET Score = @Score,
            Comment = NULLIF(@Comment, N''),
            IsFinal = @IsFinal,
            UpdatedAtUtc = SYSUTCDATETIME()
        WHERE AssignmentId = @AssignmentId;
    END
    ELSE
    BEGIN
        -- This intentional baseline delay makes the check-then-insert race reproducible.
        WAITFOR DELAY '00:00:00.050';

        INSERT dbo.Review (AssignmentId, Score, Comment, IsFinal)
        VALUES (@AssignmentId, @Score, NULLIF(@Comment, N''), @IsFinal);
    END;

    UPDATE dbo.ReviewAssignment
    SET Status = CASE WHEN @IsFinal = 1 THEN 'Completed' ELSE 'Draft' END
    WHERE AssignmentId = @AssignmentId;

    SELECT TOP (1) ReviewId, AssignmentId, Score, Comment, IsFinal
    FROM dbo.Review
    WHERE AssignmentId = @AssignmentId
    ORDER BY ReviewId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReviewReminder_Create
    @AssignmentId int,
    @RequestedByUserId int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IdempotencyKey nvarchar(100) =
        CONCAT(N'review-reminder-', @AssignmentId, N'-', CONVERT(char(8), SYSUTCDATETIME(), 112));

    INSERT dbo.NotificationLog
    (
        AssignmentId,
        IdempotencyKey,
        RequestStatus,
        AttemptCount,
        RequestedByUserId
    )
    VALUES
    (
        @AssignmentId,
        @IdempotencyKey,
        'Pending',
        0,
        @RequestedByUserId
    );

    SELECT
        n.NotificationId,
        n.AssignmentId,
        n.IdempotencyKey,
        u.Email AS ReviewerEmail,
        c.Name AS ConferenceName,
        ra.DueAtUtc
    FROM dbo.NotificationLog n
    INNER JOIN dbo.ReviewAssignment ra ON ra.AssignmentId = n.AssignmentId
    INNER JOIN dbo.UserAccount u ON u.UserId = ra.ReviewerUserId
    INNER JOIN dbo.Abstract a ON a.AbstractId = ra.AbstractId
    INNER JOIN dbo.Conference c ON c.ConferenceId = a.ConferenceId
    WHERE n.NotificationId = SCOPE_IDENTITY();
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReviewReminder_MarkResult
    @NotificationId bigint,
    @RequestStatus varchar(24),
    @ProviderResponse nvarchar(1000)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.NotificationLog
    SET RequestStatus = @RequestStatus,
        AttemptCount = AttemptCount + 1,
        LastAttemptAtUtc = SYSUTCDATETIME(),
        ProviderResponse = LEFT(@ProviderResponse, 1000)
    WHERE NotificationId = @NotificationId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_AuditEvent_Create
    @EntityType varchar(40),
    @EntityId bigint,
    @Action varchar(60),
    @PerformedByUserId int,
    @Details nvarchar(2000)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT dbo.AuditEvent (EntityType, EntityId, Action, PerformedByUserId, Details)
    VALUES (@EntityType, @EntityId, @Action, @PerformedByUserId, @Details);
END;
GO
