USE Triage;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM dbo.Conference)
BEGIN
    PRINT 'Demo data already exists; seed skipped.';
    RETURN;
END;

BEGIN TRANSACTION;

INSERT dbo.Conference (Name, RequiredReviewCount, ReviewDeadlineUtc)
VALUES (N'Aster Vale Research Forum 2027', 2, '2027-03-15T17:00:00');

INSERT dbo.UserAccount (Email, DisplayName, UserRole)
VALUES (N'admin@aster-vale.example.test', N'Development Administrator', 'Admin');

;WITH Numbers AS
(
    SELECT TOP (250)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS Number
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b
)
INSERT dbo.UserAccount (Email, DisplayName, UserRole)
SELECT
    CONCAT(N'reviewer', FORMAT(Number, '000'), N'@example.test'),
    CONCAT(N'Reviewer ', FORMAT(Number, '000')),
    'Reviewer'
FROM Numbers
ORDER BY Number;

;WITH Numbers AS
(
    SELECT TOP (10000)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS Number
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b
)
INSERT dbo.Abstract
(
    ConferenceId,
    Title,
    Body,
    Track,
    Status,
    SubmittingAuthorName,
    SubmittingAuthorEmail
)
SELECT
    1,
    CASE
        WHEN Number = 13 THEN N'<script>alert(''triage'')</script> — encoded fixture'
        ELSE CONCAT(N'Evidence synthesis abstract ', FORMAT(Number, '00000'))
    END,
    CONCAT(
        N'This fictional abstract body is generated for local review operations testing. Record ',
        Number,
        N' contains no real research or personal data.'
    ),
    CASE Number % 5
        WHEN 0 THEN N'Clinical Methods'
        WHEN 1 THEN N'Population Evidence'
        WHEN 2 THEN N'Diagnostic Practice'
        WHEN 3 THEN N'Care Delivery'
        ELSE N'Research Quality'
    END,
    'Active',
    CONCAT(N'PRIVATE-AUTHOR-', FORMAT(Number, '00000')),
    CONCAT(N'private-author-', FORMAT(Number, '00000'), N'@example.test')
FROM Numbers
ORDER BY Number;

INSERT dbo.ReviewAssignment
(
    AbstractId,
    ReviewerUserId,
    AssignedAtUtc,
    DueAtUtc,
    Status
)
SELECT
    a.AbstractId,
    2 + (((a.AbstractId - 1) * 2 + slots.SlotNumber) % 250),
    DATEADD(day, -21, CAST('2027-03-15T17:00:00' AS datetime2(3))),
    CASE
        WHEN (a.AbstractId + slots.SlotNumber) % 3 = 0
            THEN CAST('2027-03-05T17:00:00' AS datetime2(3))
        ELSE CAST('2027-03-15T17:00:00' AS datetime2(3))
    END,
    'Assigned'
FROM dbo.Abstract a
CROSS JOIN (VALUES (0), (1)) slots(SlotNumber)
ORDER BY a.AbstractId, slots.SlotNumber;

INSERT dbo.Review (AssignmentId, Score, Comment, IsFinal, CreatedAtUtc, UpdatedAtUtc)
SELECT
    AssignmentId,
    CAST(1 + (AssignmentId % 5) AS tinyint),
    CASE WHEN AssignmentId = 13 THEN N'<img src=x onerror=alert(1)> encoded comment fixture' ELSE N'Completed seed review.' END,
    1,
    '2027-03-01T09:00:00',
    '2027-03-01T09:00:00'
FROM dbo.ReviewAssignment
WHERE AssignmentId % 4 = 0;

INSERT dbo.Review (AssignmentId, Score, Comment, IsFinal, CreatedAtUtc, UpdatedAtUtc)
SELECT
    AssignmentId,
    NULL,
    N'Draft seed comment.',
    0,
    '2027-03-02T09:00:00',
    '2027-03-02T09:00:00'
FROM dbo.ReviewAssignment
WHERE AssignmentId % 4 = 1;

-- A known duplicate fixture makes the data-cleanup migration independently testable.
INSERT dbo.Review (AssignmentId, Score, Comment, IsFinal, CreatedAtUtc, UpdatedAtUtc)
SELECT
    AssignmentId,
    Score,
    N'Intentional duplicate baseline fixture.',
    IsFinal,
    DATEADD(minute, 1, CreatedAtUtc),
    DATEADD(minute, 1, UpdatedAtUtc)
FROM dbo.Review
WHERE AssignmentId = 4;

UPDATE ra
SET Status = CASE WHEN r.IsFinal = 1 THEN 'Completed' ELSE 'Draft' END
FROM dbo.ReviewAssignment ra
INNER JOIN
(
    SELECT AssignmentId, MAX(CAST(IsFinal AS tinyint)) AS IsFinal
    FROM dbo.Review
    GROUP BY AssignmentId
) r ON r.AssignmentId = ra.AssignmentId;

INSERT dbo.ReviewerConflict (AbstractId, ReviewerUserId, DeclaredAtUtc)
VALUES
    (42, 200, '2027-03-03T10:00:00'),
    (84, 201, '2027-03-03T10:05:00');

COMMIT;

SELECT
    (SELECT COUNT(*) FROM dbo.Abstract) AS AbstractCount,
    (SELECT COUNT(*) FROM dbo.UserAccount WHERE UserRole = 'Reviewer') AS ReviewerCount,
    (SELECT COUNT(*) FROM dbo.ReviewAssignment) AS AssignmentCount,
    (SELECT COUNT(*) FROM dbo.Review) AS ReviewRowCount;
GO

