-- ============================================================
-- SQL Server 05: E-Commerce Database Setup
-- Demonstrates: JSON support, computed columns, indexed views
-- ============================================================

USE master;
GO

IF DB_ID('ECommerceStore') IS NOT NULL DROP DATABASE ECommerceStore;
GO

CREATE DATABASE ECommerceStore
ON PRIMARY (
    NAME = ECommerceStore_Data,
    FILENAME = 'C:\SQLData\ECommerceStore.mdf',
    SIZE = 150MB,
    FILEGROWTH = 50MB
)
LOG ON (
    NAME = ECommerceStore_Log,
    FILENAME = 'C:\SQLData\ECommerceStore_log.ldf',
    SIZE = 75MB,
    FILEGROWTH = 25MB
);
GO

USE ECommerceStore;
GO

-- Customers
CREATE TABLE dbo.Customers (
    CustomerID INT IDENTITY(1,1) PRIMARY KEY,
    Email NVARCHAR(200) NOT NULL UNIQUE,
    PasswordHash NVARCHAR(256) NOT NULL,
    FirstName NVARCHAR(100),
    LastName NVARCHAR(100),
    Phone NVARCHAR(50),
    Preferences NVARCHAR(MAX), -- JSON column
    LoyaltyPoints INT DEFAULT 0,
    AccountStatus NVARCHAR(20) DEFAULT 'Active',
    CreatedDate DATETIME2 DEFAULT SYSUTCDATETIME(),
    LastLoginDate DATETIME2,
    CONSTRAINT CK_Preferences_JSON CHECK (ISJSON(Preferences) = 1 OR Preferences IS NULL)
);
GO

-- Product Catalog
CREATE TABLE dbo.Products (
    ProductID INT IDENTITY(1,1) PRIMARY KEY,
    ProductName NVARCHAR(200) NOT NULL,
    Description NVARCHAR(MAX),
    Category NVARCHAR(100),
    Brand NVARCHAR(100),
    Price DECIMAL(10,2) NOT NULL,
    CompareAtPrice DECIMAL(10,2),
    CostPrice DECIMAL(10,2),
    Attributes NVARCHAR(MAX), -- JSON
    StockQuantity INT DEFAULT 0,
    IsPublished BIT DEFAULT 1,
    Margin AS (Price - ISNULL(CostPrice, 0)) PERSISTED,
    CreatedDate DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Orders
CREATE TABLE dbo.Orders (
    OrderID INT IDENTITY(1,1) PRIMARY KEY,
    OrderNumber NVARCHAR(20) NOT NULL UNIQUE,
    CustomerID INT NOT NULL REFERENCES dbo.Customers(CustomerID),
    OrderDate DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    Status NVARCHAR(30) DEFAULT 'Pending',
    SubTotal DECIMAL(12,2),
    TaxAmount DECIMAL(10,2),
    ShippingAmount DECIMAL(10,2),
    DiscountAmount DECIMAL(10,2) DEFAULT 0,
    TotalAmount AS (ISNULL(SubTotal,0) + ISNULL(TaxAmount,0) + ISNULL(ShippingAmount,0) - ISNULL(DiscountAmount,0)) PERSISTED,
    ShippingAddress NVARCHAR(MAX), -- JSON
    PaymentMethod NVARCHAR(50),
    Notes NVARCHAR(500)
);
GO

-- Order Items
CREATE TABLE dbo.OrderItems (
    OrderItemID BIGINT IDENTITY(1,1) PRIMARY KEY,
    OrderID INT NOT NULL REFERENCES dbo.Orders(OrderID),
    ProductID INT NOT NULL REFERENCES dbo.Products(ProductID),
    Quantity INT NOT NULL,
    UnitPrice DECIMAL(10,2) NOT NULL,
    LineTotal AS (Quantity * UnitPrice) PERSISTED,
    DiscountPercent DECIMAL(5,2) DEFAULT 0
);
GO

-- Reviews
CREATE TABLE dbo.ProductReviews (
    ReviewID INT IDENTITY(1,1) PRIMARY KEY,
    ProductID INT NOT NULL REFERENCES dbo.Products(ProductID),
    CustomerID INT NOT NULL REFERENCES dbo.Customers(CustomerID),
    Rating INT NOT NULL CHECK (Rating BETWEEN 1 AND 5),
    Title NVARCHAR(200),
    ReviewText NVARCHAR(MAX),
    IsVerifiedPurchase BIT DEFAULT 0,
    CreatedDate DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Shopping Cart
CREATE TABLE dbo.ShoppingCart (
    CartID INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID INT NOT NULL REFERENCES dbo.Customers(CustomerID),
    ProductID INT NOT NULL REFERENCES dbo.Products(ProductID),
    Quantity INT NOT NULL DEFAULT 1,
    AddedDate DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Indexed view for product stats
CREATE VIEW dbo.vw_ProductSalesStats WITH SCHEMABINDING
AS
SELECT
    oi.ProductID,
    COUNT_BIG(*) AS OrderCount,
    SUM(oi.Quantity) AS TotalQuantitySold,
    SUM(oi.Quantity * oi.UnitPrice) AS TotalRevenue
FROM dbo.OrderItems oi
GROUP BY oi.ProductID;
GO
CREATE UNIQUE CLUSTERED INDEX IX_ProductSalesStats ON dbo.vw_ProductSalesStats(ProductID);
GO

-- Populate customers
DECLARE @i INT = 1;
WHILE @i <= 3000
BEGIN
    INSERT INTO dbo.Customers (Email, PasswordHash, FirstName, LastName, Preferences, LoyaltyPoints)
    VALUES (
        'customer' + CAST(@i AS NVARCHAR(10)) + '@example.com',
        CONVERT(NVARCHAR(256), HASHBYTES('SHA2_256', 'password' + CAST(@i AS NVARCHAR(10))), 2),
        'Buyer' + CAST(@i AS NVARCHAR(10)),
        'Family' + CAST(@i % 300 AS NVARCHAR(10)),
        '{"newsletter": true, "theme": "' + CHOOSE((@i % 3) + 1, 'light','dark','auto') + '", "currency": "USD"}',
        ABS(CHECKSUM(NEWID())) % 5000
    );
    SET @i = @i + 1;
END;
GO

-- Populate products
DECLARE @j INT = 1;
WHILE @j <= 500
BEGIN
    INSERT INTO dbo.Products (ProductName, Category, Brand, Price, CostPrice, StockQuantity, Attributes)
    VALUES (
        'Product-' + CAST(@j AS NVARCHAR(10)),
        CHOOSE((@j % 8) + 1, 'Electronics','Clothing','Home','Sports','Beauty','Books','Toys','Garden'),
        'Brand-' + CAST(@j % 30 AS NVARCHAR(5)),
        ROUND(10 + RAND() * 500, 2),
        ROUND(5 + RAND() * 200, 2),
        ABS(CHECKSUM(NEWID())) % 500,
        '{"color": "' + CHOOSE((@j % 4) + 1, 'red','blue','green','black') + '", "weight_kg": ' + CAST(ROUND(0.5 + RAND() * 10, 1) AS NVARCHAR(10)) + '}'
    );
    SET @j = @j + 1;
END;
GO

-- Generate orders
DECLARE @k INT = 1;
WHILE @k <= 10000
BEGIN
    INSERT INTO dbo.Orders (OrderNumber, CustomerID, OrderDate, Status, SubTotal, TaxAmount, ShippingAmount, PaymentMethod)
    VALUES (
        'ORD-' + RIGHT('000000' + CAST(@k AS NVARCHAR(6)), 6),
        (ABS(CHECKSUM(NEWID())) % 3000) + 1,
        DATEADD(DAY, -ABS(CHECKSUM(NEWID())) % 730, GETDATE()),
        CHOOSE((ABS(CHECKSUM(NEWID())) % 5) + 1, 'Completed','Shipped','Processing','Pending','Cancelled'),
        ROUND(20 + RAND() * 500, 2),
        ROUND(2 + RAND() * 50, 2),
        ROUND(5 + RAND() * 25, 2),
        CHOOSE((@k % 3) + 1, 'CreditCard','PayPal','BankTransfer')
    );
    SET @k = @k + 1;
END;
GO

-- Generate order items
DECLARE @m INT = 1;
WHILE @m <= 25000
BEGIN
    INSERT INTO dbo.OrderItems (OrderID, ProductID, Quantity, UnitPrice)
    VALUES (
        (ABS(CHECKSUM(NEWID())) % 10000) + 1,
        (ABS(CHECKSUM(NEWID())) % 500) + 1,
        1 + ABS(CHECKSUM(NEWID())) % 5,
        ROUND(10 + RAND() * 200, 2)
    );
    SET @m = @m + 1;
END;
GO

PRINT 'SQL05 - ECommerceStore database setup complete.';
GO
