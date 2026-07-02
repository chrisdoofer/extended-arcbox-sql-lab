-- ============================================================
-- SQL Server 03: HR/Payroll Database Setup
-- Demonstrates: Row-level security, data masking, encryption
-- ============================================================

USE master;
GO

IF DB_ID('HRPayroll') IS NOT NULL DROP DATABASE HRPayroll;
GO

CREATE DATABASE HRPayroll
ON PRIMARY (
    NAME = HRPayroll_Data,
    FILENAME = 'C:\SQLData\HRPayroll.mdf',
    SIZE = 80MB,
    FILEGROWTH = 40MB
)
LOG ON (
    NAME = HRPayroll_Log,
    FILENAME = 'C:\SQLData\HRPayroll_log.ldf',
    SIZE = 40MB,
    FILEGROWTH = 20MB
);
GO

USE HRPayroll;
GO

-- Departments
CREATE TABLE dbo.Departments (
    DepartmentID INT IDENTITY(1,1) PRIMARY KEY,
    DepartmentName NVARCHAR(100) NOT NULL,
    ManagerID INT NULL,
    CostCenter NVARCHAR(20),
    IsActive BIT DEFAULT 1
);
GO

-- Employees with data masking
CREATE TABLE dbo.Employees (
    EmployeeID INT IDENTITY(1,1) PRIMARY KEY,
    EmployeeNumber NVARCHAR(20) NOT NULL UNIQUE,
    FirstName NVARCHAR(100) NOT NULL,
    LastName NVARCHAR(100) NOT NULL,
    SSN NVARCHAR(11) MASKED WITH (FUNCTION = 'partial(0,"XXX-XX-",4)'),
    Email NVARCHAR(200) MASKED WITH (FUNCTION = 'email()'),
    Phone NVARCHAR(50) MASKED WITH (FUNCTION = 'default()'),
    DateOfBirth DATE,
    HireDate DATE NOT NULL,
    TerminationDate DATE,
    DepartmentID INT REFERENCES dbo.Departments(DepartmentID),
    JobTitle NVARCHAR(100),
    ManagerID INT REFERENCES dbo.Employees(EmployeeID),
    Salary DECIMAL(18,2) MASKED WITH (FUNCTION = 'random(30000, 200000)'),
    IsActive BIT DEFAULT 1,
    CreatedDate DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Payroll Records
CREATE TABLE dbo.PayrollRecords (
    PayrollID BIGINT IDENTITY(1,1) PRIMARY KEY,
    EmployeeID INT NOT NULL REFERENCES dbo.Employees(EmployeeID),
    PayPeriodStart DATE NOT NULL,
    PayPeriodEnd DATE NOT NULL,
    GrossPay DECIMAL(18,2) NOT NULL,
    FederalTax DECIMAL(18,2),
    StateTax DECIMAL(18,2),
    SocialSecurity DECIMAL(18,2),
    Medicare DECIMAL(18,2),
    HealthInsurance DECIMAL(18,2),
    Retirement401k DECIMAL(18,2),
    NetPay DECIMAL(18,2),
    PayDate DATE NOT NULL,
    ProcessedDate DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Benefits Enrollment
CREATE TABLE dbo.BenefitsEnrollment (
    EnrollmentID INT IDENTITY(1,1) PRIMARY KEY,
    EmployeeID INT NOT NULL REFERENCES dbo.Employees(EmployeeID),
    BenefitType NVARCHAR(50) NOT NULL,
    PlanName NVARCHAR(100),
    Coverage NVARCHAR(50),
    EmployeeCost DECIMAL(10,2),
    EmployerCost DECIMAL(10,2),
    EffectiveDate DATE NOT NULL,
    EndDate DATE,
    IsActive BIT DEFAULT 1
);
GO

-- Time Off Requests
CREATE TABLE dbo.TimeOffRequests (
    RequestID INT IDENTITY(1,1) PRIMARY KEY,
    EmployeeID INT NOT NULL REFERENCES dbo.Employees(EmployeeID),
    RequestType NVARCHAR(30) NOT NULL,
    StartDate DATE NOT NULL,
    EndDate DATE NOT NULL,
    Hours DECIMAL(5,2),
    Status NVARCHAR(20) DEFAULT 'Pending',
    ApproverID INT REFERENCES dbo.Employees(EmployeeID),
    Notes NVARCHAR(500)
);
GO

-- Populate departments
INSERT INTO dbo.Departments (DepartmentName, CostCenter) VALUES
('Engineering', 'CC-100'), ('Sales', 'CC-200'), ('Marketing', 'CC-300'),
('Finance', 'CC-400'), ('HR', 'CC-500'), ('Operations', 'CC-600'),
('Legal', 'CC-700'), ('IT', 'CC-800'), ('Support', 'CC-900'),
('Executive', 'CC-001');
GO

-- Populate employees
DECLARE @i INT = 1;
WHILE @i <= 500
BEGIN
    INSERT INTO dbo.Employees (EmployeeNumber, FirstName, LastName, SSN, Email, HireDate, DepartmentID, JobTitle, Salary)
    VALUES (
        'EMP' + RIGHT('0000' + CAST(@i AS NVARCHAR(4)), 4),
        'Employee' + CAST(@i AS NVARCHAR(10)),
        'Last' + CAST(@i % 100 AS NVARCHAR(10)),
        CAST(100 + (@i % 900) AS NVARCHAR(3)) + '-' + RIGHT('00' + CAST(@i % 100 AS NVARCHAR(2)), 2) + '-' + RIGHT('0000' + CAST(@i AS NVARCHAR(4)), 4),
        'emp' + CAST(@i AS NVARCHAR(10)) + '@contoso.com',
        DATEADD(DAY, -ABS(CHECKSUM(NEWID())) % 3650, GETDATE()),
        (@i % 10) + 1,
        CHOOSE((@i % 6) + 1, 'Engineer','Analyst','Manager','Director','Specialist','Coordinator'),
        50000 + (ABS(CHECKSUM(NEWID())) % 150000)
    );
    SET @i = @i + 1;
END;
GO

-- Generate payroll history
DECLARE @j INT = 1;
WHILE @j <= 6000
BEGIN
    INSERT INTO dbo.PayrollRecords (EmployeeID, PayPeriodStart, PayPeriodEnd, GrossPay, FederalTax, StateTax, NetPay, PayDate)
    VALUES (
        (ABS(CHECKSUM(NEWID())) % 500) + 1,
        DATEADD(DAY, -(@j * 14), GETDATE()),
        DATEADD(DAY, -((@j * 14) - 13), GETDATE()),
        ROUND(3000 + RAND() * 7000, 2),
        ROUND(500 + RAND() * 2000, 2),
        ROUND(200 + RAND() * 800, 2),
        ROUND(2000 + RAND() * 5000, 2),
        DATEADD(DAY, -((@j * 14) - 14), GETDATE())
    );
    SET @j = @j + 1;
END;
GO

PRINT 'SQL03 - HRPayroll database setup complete.';
GO
