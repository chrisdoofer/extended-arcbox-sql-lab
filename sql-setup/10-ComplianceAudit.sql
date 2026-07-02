-- ============================================================
-- SQL Server 10: Compliance/Audit Database Setup
-- Demonstrates: Temporal tables, data retention, auditing
-- ============================================================

USE master;
GO

IF DB_ID('ComplianceAudit') IS NOT NULL DROP DATABASE ComplianceAudit;
GO

CREATE DATABASE ComplianceAudit
ON PRIMARY (
    NAME = ComplianceAudit_Data,
    FILENAME = 'C:\SQLData\ComplianceAudit.mdf',
    SIZE = 100MB,
    FILEGROWTH = 50MB
)
LOG ON (
    NAME = ComplianceAudit_Log,
    FILENAME = 'C:\SQLData\ComplianceAudit_log.ldf',
    SIZE = 50MB,
    FILEGROWTH = 25MB
);
GO

USE ComplianceAudit;
GO

-- Regulatory Requirements tracking
CREATE TABLE dbo.RegulatoryFrameworks (
    FrameworkID INT IDENTITY(1,1) PRIMARY KEY,
    FrameworkName NVARCHAR(100) NOT NULL,
    Version NVARCHAR(20),
    Description NVARCHAR(500),
    EffectiveDate DATE,
    IsActive BIT DEFAULT 1
);
GO

-- Compliance Controls (system-versioned temporal)
CREATE TABLE dbo.ComplianceControls (
    ControlID INT IDENTITY(1,1) PRIMARY KEY,
    FrameworkID INT NOT NULL REFERENCES dbo.RegulatoryFrameworks(FrameworkID),
    ControlCode NVARCHAR(30) NOT NULL,
    ControlName NVARCHAR(200) NOT NULL,
    Description NVARCHAR(MAX),
    Category NVARCHAR(100),
    Severity NVARCHAR(20),
    Status NVARCHAR(30) DEFAULT 'Not Assessed',
    AssignedTo NVARCHAR(100),
    DueDate DATE,
    LastAssessedDate DATETIME2,
    ValidFrom DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
    ValidTo DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.ComplianceControlsHistory));
GO

-- Audit Events
CREATE TABLE dbo.AuditEvents (
    EventID BIGINT IDENTITY(1,1) PRIMARY KEY,
    EventType NVARCHAR(50) NOT NULL,
    Severity NVARCHAR(20) NOT NULL,
    Source NVARCHAR(100),
    UserPrincipal NVARCHAR(200),
    Action NVARCHAR(100) NOT NULL,
    Resource NVARCHAR(500),
    Result NVARCHAR(20),
    Details NVARCHAR(MAX),
    IPAddress NVARCHAR(45),
    Timestamp DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    INDEX IX_AuditEvents_Timestamp NONCLUSTERED (Timestamp DESC),
    INDEX IX_AuditEvents_Type NONCLUSTERED (EventType, Severity)
);
GO

-- Data Access Logs
CREATE TABLE dbo.DataAccessLog (
    LogID BIGINT IDENTITY(1,1) PRIMARY KEY,
    DatabaseName NVARCHAR(128),
    SchemaName NVARCHAR(128),
    TableName NVARCHAR(128),
    Operation NVARCHAR(20),
    UserPrincipal NVARCHAR(200),
    RowsAffected INT,
    QueryHash NVARCHAR(128),
    ExecutionTime INT, -- ms
    Timestamp DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- Policy Violations
CREATE TABLE dbo.PolicyViolations (
    ViolationID INT IDENTITY(1,1) PRIMARY KEY,
    ControlID INT REFERENCES dbo.ComplianceControls(ControlID),
    ViolationType NVARCHAR(100),
    Description NVARCHAR(MAX),
    DetectedBy NVARCHAR(100),
    DetectedDate DATETIME2 DEFAULT SYSUTCDATETIME(),
    Severity NVARCHAR(20),
    Status NVARCHAR(30) DEFAULT 'Open',
    AssignedTo NVARCHAR(100),
    ResolvedDate DATETIME2,
    ResolutionNotes NVARCHAR(MAX)
);
GO

-- Data Retention Policies
CREATE TABLE dbo.RetentionPolicies (
    PolicyID INT IDENTITY(1,1) PRIMARY KEY,
    PolicyName NVARCHAR(100) NOT NULL,
    DataClassification NVARCHAR(50),
    RetentionDays INT NOT NULL,
    ArchiveAfterDays INT,
    DeleteAfterDays INT,
    IsActive BIT DEFAULT 1,
    LastEnforced DATETIME2
);
GO

-- Risk Register
CREATE TABLE dbo.RiskRegister (
    RiskID INT IDENTITY(1,1) PRIMARY KEY,
    RiskTitle NVARCHAR(200) NOT NULL,
    Description NVARCHAR(MAX),
    Category NVARCHAR(100),
    Likelihood INT CHECK (Likelihood BETWEEN 1 AND 5),
    Impact INT CHECK (Impact BETWEEN 1 AND 5),
    RiskScore AS (Likelihood * Impact) PERSISTED,
    Mitigation NVARCHAR(MAX),
    Owner NVARCHAR(100),
    Status NVARCHAR(30) DEFAULT 'Open',
    IdentifiedDate DATE DEFAULT GETDATE(),
    ReviewDate DATE
);
GO

-- Populate frameworks
INSERT INTO dbo.RegulatoryFrameworks (FrameworkName, Version, Description, EffectiveDate) VALUES
('SOC 2 Type II', '2024', 'Service Organization Controls', '2024-01-01'),
('GDPR', '2018', 'General Data Protection Regulation', '2018-05-25'),
('HIPAA', '2013', 'Health Insurance Portability and Accountability Act', '2013-09-23'),
('PCI DSS', '4.0', 'Payment Card Industry Data Security Standard', '2024-03-31'),
('ISO 27001', '2022', 'Information Security Management', '2022-10-25'),
('NIST CSF', '2.0', 'Cybersecurity Framework', '2024-02-26');
GO

-- Populate controls
DECLARE @i INT = 1;
WHILE @i <= 200
BEGIN
    INSERT INTO dbo.ComplianceControls (FrameworkID, ControlCode, ControlName, Category, Severity, Status, AssignedTo)
    VALUES (
        ((@i - 1) % 6) + 1,
        'CTL-' + RIGHT('000' + CAST(@i AS NVARCHAR(3)), 3),
        'Control ' + CAST(@i AS NVARCHAR(5)) + ' - ' + CHOOSE((@i % 5) + 1, 'Access Control','Encryption','Logging','Network','Physical'),
        CHOOSE((@i % 5) + 1, 'Access Management','Data Protection','Monitoring','Network Security','Physical Security'),
        CHOOSE((@i % 3) + 1, 'Critical','High','Medium'),
        CHOOSE((@i % 4) + 1, 'Compliant','Non-Compliant','Partially Compliant','Not Assessed'),
        'Auditor' + CAST((@i % 5) + 1 AS NVARCHAR(2))
    );
    SET @i = @i + 1;
END;
GO

-- Populate audit events (large volume)
DECLARE @j INT = 1;
WHILE @j <= 50000
BEGIN
    INSERT INTO dbo.AuditEvents (EventType, Severity, Source, UserPrincipal, Action, Resource, Result, Timestamp)
    VALUES (
        CHOOSE((ABS(CHECKSUM(NEWID())) % 6) + 1, 'Authentication','Authorization','DataAccess','Configuration','Network','System'),
        CHOOSE((ABS(CHECKSUM(NEWID())) % 4) + 1, 'Info','Warning','Error','Critical'),
        CHOOSE((ABS(CHECKSUM(NEWID())) % 4) + 1, 'ActiveDirectory','SQLServer','WebApp','Firewall'),
        'user' + CAST(ABS(CHECKSUM(NEWID())) % 100 AS NVARCHAR(5)) + '@contoso.com',
        CHOOSE((ABS(CHECKSUM(NEWID())) % 5) + 1, 'Login','Query','Modify','Delete','Export'),
        '/resources/' + CHOOSE((ABS(CHECKSUM(NEWID())) % 4) + 1, 'database','server','application','network') + '/' + CAST(ABS(CHECKSUM(NEWID())) % 50 AS NVARCHAR(5)),
        CHOOSE((ABS(CHECKSUM(NEWID())) % 3) + 1, 'Success','Failure','Denied'),
        DATEADD(MINUTE, -ABS(CHECKSUM(NEWID())) % 525600, GETDATE())
    );
    SET @j = @j + 1;
END;
GO

-- Insert retention policies
INSERT INTO dbo.RetentionPolicies (PolicyName, DataClassification, RetentionDays, ArchiveAfterDays, DeleteAfterDays) VALUES
('Financial Records', 'Confidential', 2555, 365, 2920),
('Audit Logs', 'Internal', 365, 180, 730),
('Customer PII', 'Restricted', 1095, 365, 1460),
('System Logs', 'Public', 90, 30, 180),
('Email Archives', 'Internal', 1825, 365, 2555);
GO

-- Insert risk register items
INSERT INTO dbo.RiskRegister (RiskTitle, Category, Likelihood, Impact, Mitigation, Owner, Status) VALUES
('Unpatched SQL Servers', 'Vulnerability Management', 4, 5, 'Implement automated patching via Arc', 'IT Security', 'Open'),
('Data exfiltration via unmonitored queries', 'Data Protection', 3, 5, 'Enable SQL Auditing and Defender for SQL', 'DBA Team', 'Mitigating'),
('Insider threat - privileged access abuse', 'Access Management', 3, 4, 'Implement least-privilege and JIT access', 'Identity Team', 'Open'),
('Ransomware targeting SQL backups', 'Business Continuity', 2, 5, 'Immutable backups with Azure Arc automated backup', 'Infrastructure', 'Mitigating'),
('Compliance drift across SQL estate', 'Governance', 4, 3, 'Azure Policy + Arc SQL BPA', 'Compliance', 'Open'),
('Shadow SQL instances', 'Asset Management', 4, 3, 'Arc-enabled SQL discovery and onboarding', 'IT Operations', 'Open');
GO

PRINT 'SQL10 - ComplianceAudit database setup complete.';
GO
