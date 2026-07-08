-- ============================================================
-- SQL Server 01: ERP/Finance Database Setup
-- Demonstrates: Filestream, TDE, complex schemas, stored procs
-- ============================================================

USE master;
GO

-- Create ERP Finance Database
IF DB_ID('FinanceERP') IS NOT NULL DROP DATABASE FinanceERP;
GO

CREATE DATABASE FinanceERP
ON PRIMARY (
    NAME = FinanceERP_Data,
    FILENAME = 'C:\SQLData\FinanceERP.mdf',
    SIZE = 100MB,
    FILEGROWTH = 50MB
)
LOG ON (
    NAME = FinanceERP_Log,
    FILENAME = 'C:\SQLData\FinanceERP_log.ldf',
    SIZE = 50MB,
    FILEGROWTH = 25MB
);
GO

USE FinanceERP;
GO

-- Chart of Accounts
CREATE TABLE dbo.ChartOfAccounts (
    AccountID INT IDENTITY(1,1) PRIMARY KEY,
    AccountCode NVARCHAR(20) NOT NULL UNIQUE,
    AccountName NVARCHAR(100) NOT NULL,
    AccountType NVARCHAR(20) NOT NULL CHECK (AccountType IN ('Asset','Liability','Equity','Revenue','Expense')),
    ParentAccountID INT NULL REFERENCES dbo.ChartOfAccounts(AccountID),
    IsActive BIT DEFAULT 1,
    CreatedDate DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- General Ledger
CREATE TABLE dbo.GeneralLedger (
    EntryID BIGINT IDENTITY(1,1) PRIMARY KEY,
    TransactionDate DATE NOT NULL,
    PostingDate DATE NOT NULL,
    AccountID INT NOT NULL REFERENCES dbo.ChartOfAccounts(AccountID),
    DebitAmount DECIMAL(18,2) DEFAULT 0,
    CreditAmount DECIMAL(18,2) DEFAULT 0,
    Description NVARCHAR(500),
    ReferenceNumber NVARCHAR(50),
    PostedBy NVARCHAR(100),
    CreatedDate DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Accounts Payable
CREATE TABLE dbo.Vendors (
    VendorID INT IDENTITY(1,1) PRIMARY KEY,
    VendorCode NVARCHAR(20) NOT NULL UNIQUE,
    VendorName NVARCHAR(200) NOT NULL,
    TaxID NVARCHAR(20),
    PaymentTerms NVARCHAR(50),
    CreditLimit DECIMAL(18,2),
    Address NVARCHAR(500),
    IsActive BIT DEFAULT 1
);
GO

CREATE TABLE dbo.PurchaseOrders (
    POID INT IDENTITY(1,1) PRIMARY KEY,
    PONumber NVARCHAR(20) NOT NULL UNIQUE,
    VendorID INT NOT NULL REFERENCES dbo.Vendors(VendorID),
    OrderDate DATE NOT NULL,
    ExpectedDelivery DATE,
    TotalAmount DECIMAL(18,2),
    Status NVARCHAR(20) DEFAULT 'Pending',
    ApprovedBy NVARCHAR(100)
);
GO

CREATE TABLE dbo.Invoices (
    InvoiceID INT IDENTITY(1,1) PRIMARY KEY,
    InvoiceNumber NVARCHAR(30) NOT NULL,
    VendorID INT NOT NULL REFERENCES dbo.Vendors(VendorID),
    POID INT REFERENCES dbo.PurchaseOrders(POID),
    InvoiceDate DATE NOT NULL,
    DueDate DATE NOT NULL,
    Amount DECIMAL(18,2) NOT NULL,
    PaidAmount DECIMAL(18,2) DEFAULT 0,
    Status NVARCHAR(20) DEFAULT 'Unpaid'
);
GO

-- Stored Procedures for financial reporting
CREATE PROCEDURE dbo.sp_GetTrialBalance
    @AsOfDate DATE
AS
BEGIN
    SELECT
        ca.AccountCode,
        ca.AccountName,
        ca.AccountType,
        SUM(gl.DebitAmount) AS TotalDebits,
        SUM(gl.CreditAmount) AS TotalCredits,
        SUM(gl.DebitAmount) - SUM(gl.CreditAmount) AS Balance
    FROM dbo.GeneralLedger gl
    INNER JOIN dbo.ChartOfAccounts ca ON gl.AccountID = ca.AccountID
    WHERE gl.PostingDate <= @AsOfDate
    GROUP BY ca.AccountCode, ca.AccountName, ca.AccountType
    ORDER BY ca.AccountCode;
END;
GO

-- Populate sample data
INSERT INTO dbo.ChartOfAccounts (AccountCode, AccountName, AccountType) VALUES
('1000', 'Cash', 'Asset'), ('1100', 'Accounts Receivable', 'Asset'),
('1200', 'Inventory', 'Asset'), ('1500', 'Fixed Assets', 'Asset'),
('2000', 'Accounts Payable', 'Liability'), ('2100', 'Accrued Expenses', 'Liability'),
('3000', 'Retained Earnings', 'Equity'), ('4000', 'Revenue', 'Revenue'),
('5000', 'Cost of Goods Sold', 'Expense'), ('6000', 'Operating Expenses', 'Expense');
GO

-- Generate sample transactions
DECLARE @i INT = 1;
WHILE @i <= 5000
BEGIN
    INSERT INTO dbo.GeneralLedger (TransactionDate, PostingDate, AccountID, DebitAmount, CreditAmount, Description, ReferenceNumber, PostedBy)
    VALUES (
        DATEADD(DAY, -ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 365, GETDATE()),
        DATEADD(DAY, -ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 365, GETDATE()),
        (ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 10) + 1,
        CASE WHEN @i % 2 = 0 THEN ROUND(RAND() * 10000, 2) ELSE 0 END,
        CASE WHEN @i % 2 = 1 THEN ROUND(RAND() * 10000, 2) ELSE 0 END,
        'Transaction ' + CAST(@i AS NVARCHAR(10)),
        'REF-' + RIGHT('000000' + CAST(@i AS NVARCHAR(6)), 6),
        'system'
    );
    SET @i = @i + 1;
END;
GO

PRINT 'SQL01 - FinanceERP database setup complete.';
GO

