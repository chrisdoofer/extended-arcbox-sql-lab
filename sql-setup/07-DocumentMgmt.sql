-- ============================================================
-- SQL Server 07: Document Management Database Setup
-- Demonstrates: FILESTREAM, full-text search, versioning
-- ============================================================

USE master;
GO

IF DB_ID('DocumentMgmt') IS NOT NULL DROP DATABASE DocumentMgmt;
GO

-- Enable FILESTREAM at instance level (if not already)
EXEC sp_configure 'filestream access level', 2;
RECONFIGURE;
GO

CREATE DATABASE DocumentMgmt
ON PRIMARY (
    NAME = DocumentMgmt_Data,
    FILENAME = 'C:\SQLData\DocumentMgmt.mdf',
    SIZE = 80MB,
    FILEGROWTH = 40MB
),
FILEGROUP FileStreamGroup CONTAINS FILESTREAM (
    NAME = DocumentMgmt_FS,
    FILENAME = 'C:\SQLData\DocMgmt_FileStream'
)
LOG ON (
    NAME = DocumentMgmt_Log,
    FILENAME = 'C:\SQLData\DocumentMgmt_log.ldf',
    SIZE = 40MB,
    FILEGROWTH = 20MB
);
GO

USE DocumentMgmt;
GO

-- Document Categories
CREATE TABLE dbo.Categories (
    CategoryID INT IDENTITY(1,1) PRIMARY KEY,
    CategoryName NVARCHAR(100) NOT NULL,
    ParentCategoryID INT REFERENCES dbo.Categories(CategoryID),
    Description NVARCHAR(500)
);
GO

-- Users
CREATE TABLE dbo.Users (
    UserID INT IDENTITY(1,1) PRIMARY KEY,
    Username NVARCHAR(50) NOT NULL UNIQUE,
    DisplayName NVARCHAR(100),
    Email NVARCHAR(200),
    Department NVARCHAR(100),
    IsActive BIT DEFAULT 1
);
GO

-- Documents (metadata)
CREATE TABLE dbo.Documents (
    DocumentID INT IDENTITY(1,1) PRIMARY KEY,
    DocumentGUID UNIQUEIDENTIFIER ROWGUIDCOL NOT NULL UNIQUE DEFAULT NEWSEQUENTIALID(),
    Title NVARCHAR(300) NOT NULL,
    Description NVARCHAR(MAX),
    CategoryID INT REFERENCES dbo.Categories(CategoryID),
    FileName NVARCHAR(260) NOT NULL,
    FileExtension NVARCHAR(10),
    FileSizeKB INT,
    MimeType NVARCHAR(100),
    Tags NVARCHAR(500),
    CreatedByUserID INT REFERENCES dbo.Users(UserID),
    CreatedDate DATETIME2 DEFAULT SYSUTCDATETIME(),
    ModifiedByUserID INT REFERENCES dbo.Users(UserID),
    ModifiedDate DATETIME2 DEFAULT SYSUTCDATETIME(),
    IsArchived BIT DEFAULT 0,
    IsDeleted BIT DEFAULT 0
);
GO

-- Document Versions
CREATE TABLE dbo.DocumentVersions (
    VersionID INT IDENTITY(1,1) PRIMARY KEY,
    DocumentID INT NOT NULL REFERENCES dbo.Documents(DocumentID),
    VersionNumber INT NOT NULL,
    ChangeNotes NVARCHAR(500),
    CreatedByUserID INT REFERENCES dbo.Users(UserID),
    CreatedDate DATETIME2 DEFAULT SYSUTCDATETIME(),
    FileSizeKB INT
);
GO

-- Document Permissions
CREATE TABLE dbo.DocumentPermissions (
    PermissionID INT IDENTITY(1,1) PRIMARY KEY,
    DocumentID INT NOT NULL REFERENCES dbo.Documents(DocumentID),
    UserID INT NOT NULL REFERENCES dbo.Users(UserID),
    PermissionLevel NVARCHAR(20) NOT NULL, -- Read, Write, Admin
    GrantedDate DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Audit Trail
CREATE TABLE dbo.AuditLog (
    AuditID BIGINT IDENTITY(1,1) PRIMARY KEY,
    DocumentID INT REFERENCES dbo.Documents(DocumentID),
    UserID INT REFERENCES dbo.Users(UserID),
    Action NVARCHAR(50) NOT NULL,
    Details NVARCHAR(500),
    IPAddress NVARCHAR(45),
    Timestamp DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Populate categories
INSERT INTO dbo.Categories (CategoryName, Description) VALUES
('Contracts', 'Legal contracts and agreements'),
('Policies', 'Company policies and procedures'),
('Reports', 'Monthly and quarterly reports'),
('Invoices', 'Vendor and customer invoices'),
('HR Documents', 'Employee-related documents'),
('Technical', 'Technical specifications and documentation'),
('Marketing', 'Marketing materials and campaigns'),
('Training', 'Training materials and certifications');
GO

-- Populate users
DECLARE @i INT = 1;
WHILE @i <= 100
BEGIN
    INSERT INTO dbo.Users (Username, DisplayName, Email, Department)
    VALUES (
        'user' + CAST(@i AS NVARCHAR(5)),
        'User ' + CAST(@i AS NVARCHAR(5)),
        'user' + CAST(@i AS NVARCHAR(5)) + '@contoso.com',
        CHOOSE((@i % 6) + 1, 'Engineering','HR','Finance','Legal','Marketing','Operations')
    );
    SET @i = @i + 1;
END;
GO

-- Populate documents
DECLARE @j INT = 1;
WHILE @j <= 2000
BEGIN
    INSERT INTO dbo.Documents (Title, CategoryID, FileName, FileExtension, FileSizeKB, MimeType, Tags, CreatedByUserID)
    VALUES (
        'Document-' + CAST(@j AS NVARCHAR(10)) + ' ' + CHOOSE((@j % 5) + 1, 'Report','Contract','Policy','Invoice','Spec'),
        (@j % 8) + 1,
        'doc_' + CAST(@j AS NVARCHAR(10)) + CHOOSE((@j % 4) + 1, '.pdf','.docx','.xlsx','.pptx'),
        CHOOSE((@j % 4) + 1, '.pdf','.docx','.xlsx','.pptx'),
        50 + ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 10000,
        CHOOSE((@j % 4) + 1, 'application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','application/vnd.openxmlformats-officedocument.presentationml.presentation'),
        CHOOSE((@j % 5) + 1, 'finance,quarterly','legal,contract','hr,policy','operations,report','technical,spec'),
        (ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 100) + 1
    );
    SET @j = @j + 1;
END;
GO

-- Generate audit log
DECLARE @k INT = 1;
WHILE @k <= 10000
BEGIN
    INSERT INTO dbo.AuditLog (DocumentID, UserID, Action, Details, Timestamp)
    VALUES (
        (ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 2000) + 1,
        (ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 100) + 1,
        CHOOSE((ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 6) + 1, 'View','Download','Edit','Share','Print','Delete'),
        'Action performed on document',
        DATEADD(MINUTE, -ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 525600, GETDATE())
    );
    SET @k = @k + 1;
END;
GO

PRINT 'SQL07 - DocumentMgmt database setup complete.';
GO


