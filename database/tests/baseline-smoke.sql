USE Triage;
GO

SET NOCOUNT ON;

IF (SELECT COUNT(*) FROM dbo.Abstract) <> 10000
    THROW 52001, 'Expected 10,000 abstracts.', 1;

IF (SELECT COUNT(*) FROM dbo.UserAccount WHERE UserRole = 'Reviewer') <> 250
    THROW 52002, 'Expected 250 reviewers.', 1;

IF (SELECT COUNT(*) FROM dbo.ReviewAssignment) <> 20000
    THROW 52003, 'Expected 20,000 assignments.', 1;

IF NOT EXISTS
(
    SELECT AssignmentId
    FROM dbo.Review
    GROUP BY AssignmentId
    HAVING COUNT(*) > 1
)
    THROW 52004, 'Intentional duplicate baseline fixture is missing.', 1;

PRINT 'BASELINE_SMOKE_OK';
GO
