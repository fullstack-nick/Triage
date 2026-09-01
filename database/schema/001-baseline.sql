SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_ID(N'Triage') IS NULL
BEGIN
    CREATE DATABASE Triage;
END;
GO

USE Triage;
GO

IF OBJECT_ID(N'dbo.SchemaVersion', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.SchemaVersion
    (
        VersionNumber int NOT NULL CONSTRAINT PK_SchemaVersion PRIMARY KEY,
        Description nvarchar(200) NOT NULL,
        AppliedAtUtc datetime2(3) NOT NULL CONSTRAINT DF_SchemaVersion_AppliedAtUtc DEFAULT SYSUTCDATETIME()
    );
END;
GO

IF OBJECT_ID(N'dbo.Conference', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Conference
    (
        ConferenceId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Conference PRIMARY KEY,
        Name nvarchar(160) NOT NULL,
        RequiredReviewCount tinyint NOT NULL,
        ReviewDeadlineUtc datetime2(3) NOT NULL,
        CONSTRAINT CK_Conference_RequiredReviewCount CHECK (RequiredReviewCount BETWEEN 1 AND 10)
    );
END;
GO

IF OBJECT_ID(N'dbo.UserAccount', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserAccount
    (
        UserId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_UserAccount PRIMARY KEY,
        Email nvarchar(254) NOT NULL,
        DisplayName nvarchar(120) NOT NULL,
        UserRole varchar(16) NOT NULL,
        IsActive bit NOT NULL CONSTRAINT DF_UserAccount_IsActive DEFAULT (1),
        CONSTRAINT UQ_UserAccount_Email UNIQUE (Email),
        CONSTRAINT CK_UserAccount_Role CHECK (UserRole IN ('Admin', 'Reviewer'))
    );
END;
GO

IF OBJECT_ID(N'dbo.Abstract', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Abstract
    (
        AbstractId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Abstract PRIMARY KEY,
        ConferenceId int NOT NULL,
        Title nvarchar(300) NOT NULL,
        Body nvarchar(max) NOT NULL,
        Track nvarchar(80) NOT NULL,
        Status varchar(20) NOT NULL,
        SubmittingAuthorName nvarchar(160) NOT NULL,
        SubmittingAuthorEmail nvarchar(254) NOT NULL,
        CONSTRAINT FK_Abstract_Conference FOREIGN KEY (ConferenceId) REFERENCES dbo.Conference(ConferenceId),
        CONSTRAINT CK_Abstract_Status CHECK (Status IN ('Active', 'Withdrawn'))
    );
END;
GO

IF OBJECT_ID(N'dbo.ReviewAssignment', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReviewAssignment
    (
        AssignmentId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ReviewAssignment PRIMARY KEY,
        AbstractId int NOT NULL,
        ReviewerUserId int NOT NULL,
        AssignedAtUtc datetime2(3) NOT NULL,
        DueAtUtc datetime2(3) NOT NULL,
        Status varchar(20) NOT NULL,
        ReassignedFromAssignmentId int NULL,
        RowVersion rowversion NOT NULL,
        CONSTRAINT FK_ReviewAssignment_Abstract FOREIGN KEY (AbstractId) REFERENCES dbo.Abstract(AbstractId),
        CONSTRAINT FK_ReviewAssignment_Reviewer FOREIGN KEY (ReviewerUserId) REFERENCES dbo.UserAccount(UserId),
        CONSTRAINT FK_ReviewAssignment_Predecessor FOREIGN KEY (ReassignedFromAssignmentId) REFERENCES dbo.ReviewAssignment(AssignmentId),
        CONSTRAINT CK_ReviewAssignment_Status CHECK (Status IN ('Assigned', 'Draft', 'Completed', 'Conflict', 'Reassigned'))
    );
END;
GO

IF OBJECT_ID(N'dbo.Review', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Review
    (
        ReviewId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Review PRIMARY KEY,
        AssignmentId int NOT NULL,
        Score tinyint NULL,
        Comment nvarchar(2000) NULL,
        IsFinal bit NOT NULL,
        CreatedAtUtc datetime2(3) NOT NULL CONSTRAINT DF_Review_CreatedAtUtc DEFAULT SYSUTCDATETIME(),
        UpdatedAtUtc datetime2(3) NOT NULL CONSTRAINT DF_Review_UpdatedAtUtc DEFAULT SYSUTCDATETIME(),
        RowVersion rowversion NOT NULL,
        CONSTRAINT FK_Review_Assignment FOREIGN KEY (AssignmentId) REFERENCES dbo.ReviewAssignment(AssignmentId),
        CONSTRAINT CK_Review_Score CHECK (Score IS NULL OR Score BETWEEN 1 AND 5),
        CONSTRAINT CK_Review_FinalScore CHECK (IsFinal = 0 OR Score IS NOT NULL)
    );
END;
GO

IF OBJECT_ID(N'dbo.ReviewerConflict', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ReviewerConflict
    (
        ReviewerConflictId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ReviewerConflict PRIMARY KEY,
        AbstractId int NOT NULL,
        ReviewerUserId int NOT NULL,
        DeclaredAtUtc datetime2(3) NOT NULL CONSTRAINT DF_ReviewerConflict_DeclaredAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_ReviewerConflict_Abstract FOREIGN KEY (AbstractId) REFERENCES dbo.Abstract(AbstractId),
        CONSTRAINT FK_ReviewerConflict_Reviewer FOREIGN KEY (ReviewerUserId) REFERENCES dbo.UserAccount(UserId),
        CONSTRAINT UQ_ReviewerConflict_AbstractReviewer UNIQUE (AbstractId, ReviewerUserId)
    );
END;
GO

IF OBJECT_ID(N'dbo.NotificationLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.NotificationLog
    (
        NotificationId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_NotificationLog PRIMARY KEY,
        AssignmentId int NOT NULL,
        IdempotencyKey nvarchar(100) NOT NULL,
        RequestStatus varchar(24) NOT NULL,
        AttemptCount int NOT NULL CONSTRAINT DF_NotificationLog_AttemptCount DEFAULT (0),
        LastAttemptAtUtc datetime2(3) NULL,
        ProviderResponse nvarchar(1000) NULL,
        RequestedByUserId int NOT NULL,
        CreatedAtUtc datetime2(3) NOT NULL CONSTRAINT DF_NotificationLog_CreatedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_NotificationLog_Assignment FOREIGN KEY (AssignmentId) REFERENCES dbo.ReviewAssignment(AssignmentId),
        CONSTRAINT FK_NotificationLog_Actor FOREIGN KEY (RequestedByUserId) REFERENCES dbo.UserAccount(UserId),
        CONSTRAINT CK_NotificationLog_Status CHECK (RequestStatus IN ('Pending', 'Succeeded', 'RetryableFailure', 'PermanentFailure'))
    );
END;
GO

IF OBJECT_ID(N'dbo.AuditEvent', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AuditEvent
    (
        AuditEventId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditEvent PRIMARY KEY,
        EntityType varchar(40) NOT NULL,
        EntityId bigint NOT NULL,
        Action varchar(60) NOT NULL,
        PerformedByUserId int NOT NULL,
        OccurredAtUtc datetime2(3) NOT NULL CONSTRAINT DF_AuditEvent_OccurredAtUtc DEFAULT SYSUTCDATETIME(),
        Details nvarchar(2000) NOT NULL,
        CONSTRAINT FK_AuditEvent_Actor FOREIGN KEY (PerformedByUserId) REFERENCES dbo.UserAccount(UserId),
        CONSTRAINT CK_AuditEvent_DetailsJson CHECK (ISJSON(Details) = 1)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = 1)
BEGIN
    INSERT dbo.SchemaVersion (VersionNumber, Description)
    VALUES (1, N'Intentional legacy baseline');
END;
GO

