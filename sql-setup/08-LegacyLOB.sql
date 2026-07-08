-- ============================================================
-- SQL Server 08: Legacy LOB Application Database Setup
-- Demonstrates: Linked servers, cross-db queries, deprecated features
-- Great for Azure Migrate assessment (shows migration blockers)
-- ============================================================

USE master;
GO

IF DB_ID('LegacyLOB') IS NOT NULL DROP DATABASE LegacyLOB;
GO

CREATE DATABASE LegacyLOB
ON PRIMARY (
    NAME = LegacyLOB_Data,
    FILENAME = 'C:\SQLData\LegacyLOB.mdf',
    SIZE = 80MB,
    FILEGROWTH = 40MB
)
LOG ON (
    NAME = LegacyLOB_Log,
    FILENAME = 'C:\SQLData\LegacyLOB_log.ldf',
    SIZE = 40MB,
    FILEGROWTH = 20MB
);
GO

USE LegacyLOB;
GO

-- Legacy Customer Table (uses deprecated features for migration assessment demo)
CREATE TABLE dbo.Customers (
    CustomerID INT IDENTITY(1,1) PRIMARY KEY,
    CustomerCode NVARCHAR(20) NOT NULL,
    CompanyName NVARCHAR(200) NOT NULL,
    ContactName NVARCHAR(100),
    ContactTitle NVARCHAR(50),
    Address NVARCHAR(300),
    City NVARCHAR(100),
    Region NVARCHAR(50),
    PostalCode NVARCHAR(20),
    Country NVARCHAR(100),
    Phone NVARCHAR(50),
    Fax NVARCHAR(50), -- legacy field
    CreditRating INT
);
GO

-- Legacy Orders with cross-database reference pattern
CREATE TABLE dbo.Orders (
    OrderID INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID INT NOT NULL REFERENCES dbo.Customers(CustomerID),
    EmployeeID INT, -- would reference HR database
    OrderDate DATETIME NOT NULL DEFAULT GETDATE(),
    RequiredDate DATETIME,
    ShippedDate DATETIME,
    ShipVia INT,
    Freight MONEY, -- uses MONEY type (migration consideration)
    ShipName NVARCHAR(100),
    ShipAddress NVARCHAR(300),
    ShipCity NVARCHAR(100),
    ShipRegion NVARCHAR(50),
    ShipPostalCode NVARCHAR(20),
    ShipCountry NVARCHAR(100)
);
GO

-- Order Details
CREATE TABLE dbo.OrderDetails (
    OrderDetailID INT IDENTITY(1,1) PRIMARY KEY,
    OrderID INT NOT NULL REFERENCES dbo.Orders(OrderID),
    ProductName NVARCHAR(200),
    UnitPrice MONEY NOT NULL,
    Quantity SMALLINT NOT NULL,
    Discount REAL DEFAULT 0 -- uses REAL type
);
GO

-- Legacy stored procedure using deprecated syntax
CREATE PROCEDURE dbo.sp_GetCustomerOrders
    @CustomerID INT
AS
BEGIN
    SET NOCOUNT ON;

    -- Uses old-style join syntax (migration warning)
    SELECT
        c.CompanyName,
        o.OrderID,
        o.OrderDate,
        o.ShippedDate,
        SUM(od.UnitPrice * od.Quantity * (1 - od.Discount)) AS OrderTotal
    FROM dbo.Customers c, dbo.Orders o, dbo.OrderDetails od
    WHERE c.CustomerID = o.CustomerID
        AND o.OrderID = od.OrderID
        AND c.CustomerID = @CustomerID
    GROUP BY c.CompanyName, o.OrderID, o.OrderDate, o.ShippedDate
    ORDER BY o.OrderDate DESC;
END;
GO

-- Procedure using EXEC for dynamic SQL (security consideration)
CREATE PROCEDURE dbo.sp_SearchCustomers
    @SearchTerm NVARCHAR(100)
AS
BEGIN
    DECLARE @sql NVARCHAR(MAX);
    SET @sql = 'SELECT * FROM dbo.Customers WHERE CompanyName LIKE ''%' + @SearchTerm + '%''';
    EXEC(@sql); -- SQL injection vulnerability for assessment demo
END;
GO

-- CLR-dependent pattern (migration blocker indicator)
CREATE TABLE dbo.CustomFunctions (
    FunctionID INT IDENTITY(1,1) PRIMARY KEY,
    FunctionName NVARCHAR(100),
    Description NVARCHAR(500),
    AssemblyName NVARCHAR(200), -- Indicates CLR dependency
    IsEnabled BIT DEFAULT 1
);
GO

-- Service Broker queue (migration consideration)
CREATE TABLE dbo.MessageQueue (
    MessageID INT IDENTITY(1,1) PRIMARY KEY,
    MessageType NVARCHAR(50),
    MessageBody NVARCHAR(MAX),
    Status NVARCHAR(20) DEFAULT 'Pending',
    Priority INT DEFAULT 5,
    CreatedDate DATETIME DEFAULT GETDATE(),
    ProcessedDate DATETIME
);
GO

-- Database Mail configuration reference (migration consideration)
CREATE TABLE dbo.NotificationConfig (
    ConfigID INT IDENTITY(1,1) PRIMARY KEY,
    NotificationType NVARCHAR(50),
    Recipients NVARCHAR(500),
    MailProfile NVARCHAR(100),
    IsActive BIT DEFAULT 1
);
GO

-- Agent Jobs reference table (migration blocker)
CREATE TABLE dbo.ScheduledJobs (
    JobID INT IDENTITY(1,1) PRIMARY KEY,
    JobName NVARCHAR(200) NOT NULL,
    Description NVARCHAR(500),
    Schedule NVARCHAR(100),
    LastRunDate DATETIME,
    LastRunStatus NVARCHAR(20),
    IsEnabled BIT DEFAULT 1
);
GO

-- Populate customers
DECLARE @i INT = 1;
WHILE @i <= 1000
BEGIN
    INSERT INTO dbo.Customers (CustomerCode, CompanyName, ContactName, City, Country, Phone, CreditRating)
    VALUES (
        'CUST' + RIGHT('0000' + CAST(@i AS NVARCHAR(4)), 4),
        'Company ' + CAST(@i AS NVARCHAR(10)) + ' Ltd',
        'Contact ' + CAST(@i AS NVARCHAR(10)),
        CHOOSE((@i % 6) + 1, 'London','New York','Tokyo','Paris','Sydney','Berlin'),
        CHOOSE((@i % 6) + 1, 'UK','USA','Japan','France','Australia','Germany'),
        '+1-555-' + RIGHT('0000' + CAST(ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 10000 AS NVARCHAR(4)), 4),
        (ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 5) + 1
    );
    SET @i = @i + 1;
END;
GO

-- Populate orders
DECLARE @j INT = 1;
WHILE @j <= 20000
BEGIN
    INSERT INTO dbo.Orders (CustomerID, OrderDate, RequiredDate, Freight, ShipCity, ShipCountry)
    VALUES (
        (ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 1000) + 1,
        DATEADD(DAY, -ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 1825, GETDATE()),
        DATEADD(DAY, -ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 1800, GETDATE()),
        CAST(ROUND(5 + RAND() * 200, 2) AS MONEY),
        CHOOSE((ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 6) + 1, 'London','New York','Tokyo','Paris','Sydney','Berlin'),
        CHOOSE((ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 6) + 1, 'UK','USA','Japan','France','Australia','Germany')
    );
    SET @j = @j + 1;
END;
GO

-- Populate order details
DECLARE @k INT = 1;
WHILE @k <= 50000
BEGIN
    INSERT INTO dbo.OrderDetails (OrderID, ProductName, UnitPrice, Quantity, Discount)
    VALUES (
        (ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 20000) + 1,
        'Product-' + CAST(ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 200 AS NVARCHAR(5)),
        CAST(ROUND(5 + RAND() * 300, 2) AS MONEY),
        1 + ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 20,
        CAST(CASE WHEN ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 3 = 0 THEN ROUND(RAND() * 0.25, 2) ELSE 0 END AS REAL)
    );
    SET @k = @k + 1;
END;
GO

-- Insert scheduled jobs (for assessment visibility)
INSERT INTO dbo.ScheduledJobs (JobName, Description, Schedule, IsEnabled) VALUES
('DailyBackup', 'Full database backup', 'Daily at 2:00 AM', 1),
('HourlyLogShip', 'Transaction log shipping', 'Every hour', 1),
('WeeklyIndexMaint', 'Rebuild fragmented indexes', 'Sunday at 3:00 AM', 1),
('DailyETL', 'Extract/Transform/Load from ERP', 'Daily at 6:00 AM', 1),
('MonthlyArchive', 'Archive old orders to history', 'First of month', 1),
('RealtimeSync', 'Sync with CRM system', 'Every 5 minutes', 1);
GO

PRINT 'SQL08 - LegacyLOB database setup complete (with migration assessment blockers).';
GO

