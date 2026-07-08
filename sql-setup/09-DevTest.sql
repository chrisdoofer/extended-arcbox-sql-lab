-- ============================================================
-- SQL Server 09: DevTest/Staging Database Setup
-- Demonstrates: Multiple databases, mixed workloads, schema drift
-- ============================================================

USE master;
GO

-- Create multiple databases to simulate dev/test sprawl
IF DB_ID('AppDev_v1') IS NOT NULL DROP DATABASE AppDev_v1;
IF DB_ID('AppDev_v2') IS NOT NULL DROP DATABASE AppDev_v2;
IF DB_ID('StagingDB') IS NOT NULL DROP DATABASE StagingDB;
IF DB_ID('IntegrationTestDB') IS NOT NULL DROP DATABASE IntegrationTestDB;
GO

-- Dev database v1 (older schema)
CREATE DATABASE AppDev_v1;
GO
USE AppDev_v1;
GO

CREATE TABLE dbo.Users (
    ID INT IDENTITY(1,1) PRIMARY KEY,
    UserName NVARCHAR(50) NOT NULL,
    PasswordHash NVARCHAR(128),
    Email NVARCHAR(200),
    Created DATETIME DEFAULT GETDATE()
);
GO

CREATE TABLE dbo.Posts (
    ID INT IDENTITY(1,1) PRIMARY KEY,
    UserID INT REFERENCES dbo.Users(ID),
    Title NVARCHAR(200),
    Body NVARCHAR(MAX),
    Created DATETIME DEFAULT GETDATE()
);
GO

DECLARE @i INT = 1;
WHILE @i <= 200
BEGIN
    INSERT INTO dbo.Users (UserName, Email) VALUES ('devuser' + CAST(@i AS NVARCHAR(5)), 'dev' + CAST(@i AS NVARCHAR(5)) + '@test.local');
    SET @i = @i + 1;
END;
GO

-- Dev database v2 (newer schema with drift)
CREATE DATABASE AppDev_v2;
GO
USE AppDev_v2;
GO

CREATE TABLE dbo.Users (
    UserID INT IDENTITY(1,1) PRIMARY KEY,
    Username NVARCHAR(100) NOT NULL UNIQUE,
    PasswordHash NVARCHAR(256),
    Email NVARCHAR(200) NOT NULL UNIQUE,
    FirstName NVARCHAR(100),
    LastName NVARCHAR(100),
    IsActive BIT DEFAULT 1,
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME(),
    UpdatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE dbo.Posts (
    PostID INT IDENTITY(1,1) PRIMARY KEY,
    AuthorID INT REFERENCES dbo.Users(UserID),
    Title NVARCHAR(300) NOT NULL,
    Slug NVARCHAR(300),
    Content NVARCHAR(MAX),
    Status NVARCHAR(20) DEFAULT 'Draft',
    PublishedAt DATETIME2,
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME(),
    UpdatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE dbo.Comments (
    CommentID INT IDENTITY(1,1) PRIMARY KEY,
    PostID INT REFERENCES dbo.Posts(PostID),
    AuthorID INT REFERENCES dbo.Users(UserID),
    Content NVARCHAR(MAX),
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE dbo.Tags (
    TagID INT IDENTITY(1,1) PRIMARY KEY,
    TagName NVARCHAR(50) NOT NULL UNIQUE
);
GO

DECLARE @j INT = 1;
WHILE @j <= 500
BEGIN
    INSERT INTO dbo.Users (Username, Email, FirstName, LastName) VALUES ('user_v2_' + CAST(@j AS NVARCHAR(5)), 'userv2_' + CAST(@j AS NVARCHAR(5)) + '@test.local', 'First' + CAST(@j AS NVARCHAR(5)), 'Last' + CAST(@j AS NVARCHAR(5)));
    SET @j = @j + 1;
END;
GO

-- Staging Database
CREATE DATABASE StagingDB;
GO
USE StagingDB;
GO

CREATE TABLE dbo.ETL_SalesStaging (
    StagingID BIGINT IDENTITY(1,1) PRIMARY KEY,
    SourceSystem NVARCHAR(50),
    RawData NVARCHAR(MAX),
    ProcessedFlag BIT DEFAULT 0,
    LoadDate DATETIME2 DEFAULT SYSUTCDATETIME(),
    ErrorMessage NVARCHAR(500)
);
GO

CREATE TABLE dbo.ETL_CustomerStaging (
    StagingID BIGINT IDENTITY(1,1) PRIMARY KEY,
    SourceSystem NVARCHAR(50),
    CustomerData NVARCHAR(MAX),
    ProcessedFlag BIT DEFAULT 0,
    LoadDate DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Populate staging data
DECLARE @k INT = 1;
WHILE @k <= 5000
BEGIN
    INSERT INTO dbo.ETL_SalesStaging (SourceSystem, RawData, ProcessedFlag)
    VALUES (
        CHOOSE((@k % 3) + 1, 'ERP','CRM','POS'),
        '{"order_id": ' + CAST(@k AS NVARCHAR(10)) + ', "amount": ' + CAST(ROUND(10 + RAND() * 1000, 2) AS NVARCHAR(10)) + '}',
        CASE WHEN @k % 10 = 0 THEN 0 ELSE 1 END
    );
    SET @k = @k + 1;
END;
GO

-- Integration Test Database
CREATE DATABASE IntegrationTestDB;
GO
USE IntegrationTestDB;
GO

CREATE TABLE dbo.TestResults (
    TestID INT IDENTITY(1,1) PRIMARY KEY,
    TestSuite NVARCHAR(100),
    TestName NVARCHAR(200),
    Status NVARCHAR(20),
    Duration INT, -- ms
    ErrorMessage NVARCHAR(MAX),
    RunDate DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE dbo.TestData (
    DataID INT IDENTITY(1,1) PRIMARY KEY,
    TableName NVARCHAR(100),
    RecordCount INT,
    SeedData NVARCHAR(MAX),
    LastReset DATETIME2
);
GO

DECLARE @m INT = 1;
WHILE @m <= 3000
BEGIN
    INSERT INTO dbo.TestResults (TestSuite, TestName, Status, Duration)
    VALUES (
        'Suite-' + CAST((@m % 10) + 1 AS NVARCHAR(5)),
        'Test_' + CAST(@m AS NVARCHAR(10)),
        CHOOSE((ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 4) + 1, 'Passed','Passed','Passed','Failed'),
        50 + ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 5000
    );
    SET @m = @m + 1;
END;
GO

PRINT 'SQL09 - DevTest databases (AppDev_v1, AppDev_v2, StagingDB, IntegrationTestDB) setup complete.';
GO

