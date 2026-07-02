-- ============================================================
-- SQL Server 02: CRM Database Setup
-- Demonstrates: Full-text search, partitioning, change tracking
-- ============================================================

USE master;
GO

IF DB_ID('ContososCRM') IS NOT NULL DROP DATABASE ContososCRM;
GO

CREATE DATABASE ContososCRM
ON PRIMARY (
    NAME = ContososCRM_Data,
    FILENAME = 'C:\SQLData\ContososCRM.mdf',
    SIZE = 100MB,
    FILEGROWTH = 50MB
)
LOG ON (
    NAME = ContososCRM_Log,
    FILENAME = 'C:\SQLData\ContososCRM_log.ldf',
    SIZE = 50MB,
    FILEGROWTH = 25MB
);
GO

USE ContososCRM;
GO

-- Enable Change Tracking
ALTER DATABASE ContososCRM SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 7 DAYS, AUTO_CLEANUP = ON);
GO

-- Contacts
CREATE TABLE dbo.Contacts (
    ContactID INT IDENTITY(1,1) PRIMARY KEY,
    FirstName NVARCHAR(100) NOT NULL,
    LastName NVARCHAR(100) NOT NULL,
    Email NVARCHAR(200),
    Phone NVARCHAR(50),
    Company NVARCHAR(200),
    Title NVARCHAR(100),
    Address NVARCHAR(500),
    City NVARCHAR(100),
    State NVARCHAR(50),
    Country NVARCHAR(100),
    CreatedDate DATETIME2 DEFAULT SYSUTCDATETIME(),
    ModifiedDate DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO
ALTER TABLE dbo.Contacts ENABLE CHANGE_TRACKING;
GO

-- Opportunities/Deals
CREATE TABLE dbo.Opportunities (
    OpportunityID INT IDENTITY(1,1) PRIMARY KEY,
    OpportunityName NVARCHAR(200) NOT NULL,
    ContactID INT NOT NULL REFERENCES dbo.Contacts(ContactID),
    Stage NVARCHAR(50) NOT NULL DEFAULT 'Prospecting',
    Amount DECIMAL(18,2),
    Probability INT CHECK (Probability BETWEEN 0 AND 100),
    ExpectedCloseDate DATE,
    AssignedTo NVARCHAR(100),
    CreatedDate DATETIME2 DEFAULT SYSUTCDATETIME(),
    ModifiedDate DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO
ALTER TABLE dbo.Opportunities ENABLE CHANGE_TRACKING;
GO

-- Activities/Interactions
CREATE TABLE dbo.Activities (
    ActivityID INT IDENTITY(1,1) PRIMARY KEY,
    ContactID INT NOT NULL REFERENCES dbo.Contacts(ContactID),
    OpportunityID INT REFERENCES dbo.Opportunities(OpportunityID),
    ActivityType NVARCHAR(50) NOT NULL,
    Subject NVARCHAR(200),
    Notes NVARCHAR(MAX),
    ActivityDate DATETIME2 NOT NULL,
    Duration INT, -- minutes
    CreatedBy NVARCHAR(100)
);
GO

-- Cases/Support Tickets
CREATE TABLE dbo.Cases (
    CaseID INT IDENTITY(1,1) PRIMARY KEY,
    CaseNumber NVARCHAR(20) NOT NULL UNIQUE,
    ContactID INT NOT NULL REFERENCES dbo.Contacts(ContactID),
    Subject NVARCHAR(200) NOT NULL,
    Description NVARCHAR(MAX),
    Priority NVARCHAR(20) DEFAULT 'Medium',
    Status NVARCHAR(30) DEFAULT 'Open',
    AssignedTo NVARCHAR(100),
    CreatedDate DATETIME2 DEFAULT SYSUTCDATETIME(),
    ResolvedDate DATETIME2
);
GO

-- Populate sample contacts
DECLARE @i INT = 1;
WHILE @i <= 2000
BEGIN
    INSERT INTO dbo.Contacts (FirstName, LastName, Email, Phone, Company, City, Country)
    VALUES (
        'Contact' + CAST(@i AS NVARCHAR(10)),
        'Surname' + CAST(@i % 200 AS NVARCHAR(10)),
        'contact' + CAST(@i AS NVARCHAR(10)) + '@contoso.com',
        '+1-555-' + RIGHT('0000' + CAST(ABS(CHECKSUM(NEWID())) % 10000 AS NVARCHAR(4)), 4),
        'Company ' + CAST(@i % 100 AS NVARCHAR(10)),
        CHOOSE((@i % 5) + 1, 'Seattle','New York','Chicago','Dallas','Miami'),
        'United States'
    );
    SET @i = @i + 1;
END;
GO

-- Generate opportunities
DECLARE @j INT = 1;
WHILE @j <= 500
BEGIN
    INSERT INTO dbo.Opportunities (OpportunityName, ContactID, Stage, Amount, Probability, ExpectedCloseDate, AssignedTo)
    VALUES (
        'Deal-' + CAST(@j AS NVARCHAR(10)),
        (ABS(CHECKSUM(NEWID())) % 2000) + 1,
        CHOOSE((@j % 5) + 1, 'Prospecting','Qualification','Proposal','Negotiation','Closed Won'),
        ROUND(RAND() * 100000, 2),
        (ABS(CHECKSUM(NEWID())) % 100),
        DATEADD(DAY, ABS(CHECKSUM(NEWID())) % 180, GETDATE()),
        'Rep' + CAST((@j % 10) + 1 AS NVARCHAR(5))
    );
    SET @j = @j + 1;
END;
GO

PRINT 'SQL02 - ContososCRM database setup complete.';
GO
