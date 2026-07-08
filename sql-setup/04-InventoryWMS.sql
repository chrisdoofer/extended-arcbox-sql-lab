-- ============================================================
-- SQL Server 04: Inventory/Warehouse Database Setup
-- Demonstrates: Temporal tables, spatial data, XML columns
-- ============================================================

USE master;
GO

IF DB_ID('InventoryWMS') IS NOT NULL DROP DATABASE InventoryWMS;
GO

CREATE DATABASE InventoryWMS
ON PRIMARY (
    NAME = InventoryWMS_Data,
    FILENAME = 'C:\SQLData\InventoryWMS.mdf',
    SIZE = 100MB,
    FILEGROWTH = 50MB
)
LOG ON (
    NAME = InventoryWMS_Log,
    FILENAME = 'C:\SQLData\InventoryWMS_log.ldf',
    SIZE = 50MB,
    FILEGROWTH = 25MB
);
GO

USE InventoryWMS;
GO

-- Warehouses with spatial data
CREATE TABLE dbo.Warehouses (
    WarehouseID INT IDENTITY(1,1) PRIMARY KEY,
    WarehouseCode NVARCHAR(10) NOT NULL UNIQUE,
    WarehouseName NVARCHAR(100) NOT NULL,
    Address NVARCHAR(300),
    City NVARCHAR(100),
    State NVARCHAR(50),
    Country NVARCHAR(100),
    Location GEOGRAPHY,
    Capacity INT,
    IsActive BIT DEFAULT 1
);
GO

-- Products with temporal table (system-versioned)
CREATE TABLE dbo.Products (
    ProductID INT IDENTITY(1,1) PRIMARY KEY,
    SKU NVARCHAR(30) NOT NULL UNIQUE,
    ProductName NVARCHAR(200) NOT NULL,
    Category NVARCHAR(100),
    SubCategory NVARCHAR(100),
    UnitPrice DECIMAL(10,2),
    Weight DECIMAL(8,3),
    Dimensions NVARCHAR(50),
    Specifications XML,
    IsActive BIT DEFAULT 1,
    ValidFrom DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
    ValidTo DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.ProductsHistory));
GO

-- Inventory Levels
CREATE TABLE dbo.InventoryLevels (
    InventoryID BIGINT IDENTITY(1,1) PRIMARY KEY,
    ProductID INT NOT NULL REFERENCES dbo.Products(ProductID),
    WarehouseID INT NOT NULL REFERENCES dbo.Warehouses(WarehouseID),
    QuantityOnHand INT NOT NULL DEFAULT 0,
    QuantityReserved INT NOT NULL DEFAULT 0,
    ReorderPoint INT,
    ReorderQuantity INT,
    BinLocation NVARCHAR(20),
    LastCountDate DATETIME2,
    LastUpdated DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Shipments
CREATE TABLE dbo.Shipments (
    ShipmentID INT IDENTITY(1,1) PRIMARY KEY,
    ShipmentNumber NVARCHAR(30) NOT NULL UNIQUE,
    WarehouseID INT NOT NULL REFERENCES dbo.Warehouses(WarehouseID),
    ShipmentType NVARCHAR(20) NOT NULL, -- Inbound/Outbound
    Status NVARCHAR(30) DEFAULT 'Pending',
    CarrierName NVARCHAR(100),
    TrackingNumber NVARCHAR(100),
    ShipDate DATETIME2,
    DeliveryDate DATETIME2,
    TotalItems INT,
    TotalWeight DECIMAL(10,2)
);
GO

CREATE TABLE dbo.ShipmentItems (
    ShipmentItemID BIGINT IDENTITY(1,1) PRIMARY KEY,
    ShipmentID INT NOT NULL REFERENCES dbo.Shipments(ShipmentID),
    ProductID INT NOT NULL REFERENCES dbo.Products(ProductID),
    Quantity INT NOT NULL,
    UnitPrice DECIMAL(10,2)
);
GO

-- Populate warehouses
INSERT INTO dbo.Warehouses (WarehouseCode, WarehouseName, City, State, Country, Location, Capacity) VALUES
('WH-SEA', 'Seattle Distribution Center', 'Seattle', 'WA', 'US', GEOGRAPHY::Point(47.6062, -122.3321, 4326), 50000),
('WH-DAL', 'Dallas Fulfillment Center', 'Dallas', 'TX', 'US', GEOGRAPHY::Point(32.7767, -96.7970, 4326), 75000),
('WH-CHI', 'Chicago Warehouse', 'Chicago', 'IL', 'US', GEOGRAPHY::Point(41.8781, -87.6298, 4326), 60000),
('WH-MIA', 'Miami Port Warehouse', 'Miami', 'FL', 'US', GEOGRAPHY::Point(25.7617, -80.1918, 4326), 40000),
('WH-NYC', 'New York Metro Hub', 'Newark', 'NJ', 'US', GEOGRAPHY::Point(40.7357, -74.1724, 4326), 45000);
GO

-- Populate products
DECLARE @i INT = 1;
WHILE @i <= 1000
BEGIN
    INSERT INTO dbo.Products (SKU, ProductName, Category, SubCategory, UnitPrice, Weight, Specifications)
    VALUES (
        'SKU-' + RIGHT('00000' + CAST(@i AS NVARCHAR(5)), 5),
        'Product ' + CAST(@i AS NVARCHAR(10)),
        CHOOSE((@i % 5) + 1, 'Electronics','Furniture','Clothing','Food','Tools'),
        'SubCat-' + CAST(@i % 20 AS NVARCHAR(5)),
        ROUND(5 + RAND() * 500, 2),
        ROUND(0.1 + RAND() * 50, 3),
        '<specs><color>' + CHOOSE((@i % 4) + 1, 'Red','Blue','Green','Black') + '</color><size>' + CHOOSE((@i % 3) + 1, 'S','M','L') + '</size></specs>'
    );
    SET @i = @i + 1;
END;
GO

-- Populate inventory levels
DECLARE @j INT = 1;
WHILE @j <= 5000
BEGIN
    INSERT INTO dbo.InventoryLevels (ProductID, WarehouseID, QuantityOnHand, QuantityReserved, ReorderPoint, BinLocation)
    VALUES (
        (ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 1000) + 1,
        (ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 5) + 1,
        ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 1000,
        ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 100,
        50 + ABS(CAST(CHECKSUM(NEWID()) AS BIGINT)) % 200,
        'A' + CAST((@j % 50) + 1 AS NVARCHAR(3)) + '-' + CAST((@j % 10) + 1 AS NVARCHAR(2))
    );
    SET @j = @j + 1;
END;
GO

PRINT 'SQL04 - InventoryWMS database setup complete.';
GO

