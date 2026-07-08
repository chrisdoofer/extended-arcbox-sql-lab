-- ============================================================
-- SQL Server 06: Reporting/Analytics Database Setup
-- Demonstrates: Columnstore indexes, partitioning, aggregations
-- ============================================================

USE master;
GO

IF DB_ID('AnalyticsDB') IS NOT NULL DROP DATABASE AnalyticsDB;
GO

CREATE DATABASE AnalyticsDB
ON PRIMARY (
    NAME = AnalyticsDB_Data,
    FILENAME = 'C:\SQLData\AnalyticsDB.mdf',
    SIZE = 200MB,
    FILEGROWTH = 100MB
)
LOG ON (
    NAME = AnalyticsDB_Log,
    FILENAME = 'C:\SQLData\AnalyticsDB_log.ldf',
    SIZE = 50MB,
    FILEGROWTH = 25MB
);
GO

USE AnalyticsDB;
GO

-- Date Dimension
CREATE TABLE dbo.DimDate (
    DateKey INT PRIMARY KEY,
    FullDate DATE NOT NULL,
    DayOfWeek TINYINT,
    DayName NVARCHAR(10),
    DayOfMonth TINYINT,
    WeekOfYear TINYINT,
    MonthNumber TINYINT,
    MonthName NVARCHAR(10),
    Quarter TINYINT,
    Year SMALLINT,
    IsWeekend BIT,
    IsHoliday BIT DEFAULT 0
);
GO

-- Populate date dimension (3 years)
DECLARE @startDate DATE = '2023-01-01';
DECLARE @endDate DATE = '2025-12-31';
DECLARE @currentDate DATE = @startDate;

WHILE @currentDate <= @endDate
BEGIN
    INSERT INTO dbo.DimDate (DateKey, FullDate, DayOfWeek, DayName, DayOfMonth, WeekOfYear, MonthNumber, MonthName, Quarter, Year, IsWeekend)
    VALUES (
        CONVERT(INT, FORMAT(@currentDate, 'yyyyMMdd')),
        @currentDate,
        DATEPART(WEEKDAY, @currentDate),
        DATENAME(WEEKDAY, @currentDate),
        DAY(@currentDate),
        DATEPART(WEEK, @currentDate),
        MONTH(@currentDate),
        DATENAME(MONTH, @currentDate),
        DATEPART(QUARTER, @currentDate),
        YEAR(@currentDate),
        CASE WHEN DATEPART(WEEKDAY, @currentDate) IN (1,7) THEN 1 ELSE 0 END
    );
    SET @currentDate = DATEADD(DAY, 1, @currentDate);
END;
GO

-- Sales Fact Table with Columnstore Index
CREATE TABLE dbo.FactSales (
    SaleID BIGINT IDENTITY(1,1),
    DateKey INT NOT NULL,
    ProductKey INT NOT NULL,
    CustomerKey INT NOT NULL,
    StoreKey INT NOT NULL,
    Quantity INT NOT NULL,
    UnitPrice DECIMAL(10,2) NOT NULL,
    Discount DECIMAL(5,2) DEFAULT 0,
    TotalAmount DECIMAL(12,2) NOT NULL,
    CostAmount DECIMAL(12,2),
    ProfitAmount DECIMAL(12,2)
);
GO

-- Clustered columnstore for analytics workload
CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactSales ON dbo.FactSales;
GO

-- Web Traffic Fact Table
CREATE TABLE dbo.FactWebTraffic (
    TrafficID BIGINT IDENTITY(1,1),
    DateKey INT NOT NULL,
    PageKey INT,
    SessionID NVARCHAR(50),
    UserAgent NVARCHAR(200),
    Country NVARCHAR(50),
    City NVARCHAR(100),
    PageViews INT,
    Duration INT, -- seconds
    BounceFlag BIT
);
GO
CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactWebTraffic ON dbo.FactWebTraffic;
GO

-- Populate sales fact (large dataset for analytics demo)
DECLARE @i INT = 1;
WHILE @i <= 100000
BEGIN
    INSERT INTO dbo.FactSales (DateKey, ProductKey, CustomerKey, StoreKey, Quantity, UnitPrice, TotalAmount, CostAmount, ProfitAmount)
    VALUES (
        CONVERT(INT, FORMAT(DATEADD(DAY, -ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 1095, GETDATE()), 'yyyyMMdd')),
        (ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 500) + 1,
        (ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 3000) + 1,
        (ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 20) + 1,
        1 + ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 10,
        ROUND(5 + RAND() * 200, 2),
        ROUND(10 + RAND() * 2000, 2),
        ROUND(5 + RAND() * 1000, 2),
        ROUND(5 + RAND() * 1000, 2)
    );
    SET @i = @i + 1;
END;
GO

-- Populate web traffic
DECLARE @j INT = 1;
WHILE @j <= 50000
BEGIN
    INSERT INTO dbo.FactWebTraffic (DateKey, PageKey, SessionID, Country, City, PageViews, Duration, BounceFlag)
    VALUES (
        CONVERT(INT, FORMAT(DATEADD(DAY, -ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 365, GETDATE()), 'yyyyMMdd')),
        (ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 200) + 1,
        NEWID(),
        CHOOSE((ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 5) + 1, 'US','UK','Germany','France','Canada'),
        CHOOSE((ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 8) + 1, 'New York','London','Berlin','Paris','Toronto','Seattle','Chicago','Miami'),
        1 + ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 20,
        10 + ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 600,
        CASE WHEN ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 4 = 0 THEN 1 ELSE 0 END
    );
    SET @j = @j + 1;
END;
GO

PRINT 'SQL06 - AnalyticsDB database setup complete.';
GO

