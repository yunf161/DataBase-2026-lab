/* 第六周：迁移前基线。仅在 CampusStoreDB 的副本中运行。 */
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W6[_]%'
    THROW 51602, N'第六周基线只能在名称为 CampusStoreDB_W6_* 的数据库副本运行', 1;

IF COL_LENGTH(N'dbo.InventoryLog', N'BusinessNo') IS NULL
    THROW 51600, N'当前数据库不是 v0.1 基线：InventoryLog.BusinessNo 不存在', 1;
IF COL_LENGTH(N'dbo.InventoryLog', N'PurchaseID') IS NOT NULL
    THROW 51601, N'当前数据库似乎已经迁移，请不要重复采集迁移前基线', 1;

IF SCHEMA_ID(N'week6') IS NULL EXEC(N'CREATE SCHEMA week6 AUTHORIZATION dbo');

DROP TABLE IF EXISTS week6.BaselineInventoryLog;
DROP TABLE IF EXISTS week6.BaselineInventory;
DROP TABLE IF EXISTS week6.BaselineProductSales;
DROP TABLE IF EXISTS week6.BaselineSaleItem;
DROP TABLE IF EXISTS week6.BaselineSaleOrder;
DROP TABLE IF EXISTS week6.BaselinePurchaseItem;
DROP TABLE IF EXISTS week6.BaselinePurchaseOrder;
DROP TABLE IF EXISTS week6.BaselineMetric;

CREATE TABLE week6.BaselineMetric (
    MetricName sysname NOT NULL PRIMARY KEY,
    MetricValue decimal(38,2) NOT NULL
);
CREATE TABLE week6.BaselinePurchaseItem (
    PurchaseNo varchar(30) NOT NULL,
    SKU varchar(30) NOT NULL,
    Quantity int NOT NULL,
    UnitCost decimal(10,2) NOT NULL,
    LineAmount decimal(12,2) NOT NULL,
    PRIMARY KEY(PurchaseNo, SKU)
);
CREATE TABLE week6.BaselinePurchaseOrder (
    PurchaseNo varchar(30) NOT NULL PRIMARY KEY,
    Status varchar(20) NOT NULL,
    TotalAmount decimal(12,2) NOT NULL
);
CREATE TABLE week6.BaselineSaleItem (
    SaleNo varchar(30) NOT NULL,
    SKU varchar(30) NOT NULL,
    Quantity int NOT NULL,
    UnitPrice decimal(10,2) NOT NULL,
    LineAmount decimal(12,2) NOT NULL,
    PRIMARY KEY(SaleNo, SKU)
);
CREATE TABLE week6.BaselineSaleOrder (
    SaleNo varchar(30) NOT NULL PRIMARY KEY,
    Status varchar(20) NOT NULL,
    TotalAmount decimal(12,2) NOT NULL,
    DiscountAmount decimal(12,2) NOT NULL,
    PayableAmount decimal(12,2) NOT NULL
);
CREATE TABLE week6.BaselineProductSales (
    SKU varchar(30) NOT NULL PRIMARY KEY,
    SoldQuantity bigint NOT NULL,
    SalesAmount decimal(38,2) NOT NULL
);
CREATE TABLE week6.BaselineInventory (
    SKU varchar(30) NOT NULL PRIMARY KEY,
    Quantity int NOT NULL,
    MinQuantity int NOT NULL
);
CREATE TABLE week6.BaselineInventoryLog (
    LogID bigint NOT NULL PRIMARY KEY,
    SKU varchar(30) NOT NULL,
    ChangeType varchar(30) NOT NULL,
    ChangeQuantity int NOT NULL,
    BeforeQuantity int NOT NULL,
    AfterQuantity int NOT NULL,
    BusinessNo varchar(30) NULL,
    EmployeeNo varchar(20) NULL,
    Remark nvarchar(255) NULL,
    CreatedAt datetime2(0) NOT NULL
);

INSERT week6.BaselinePurchaseOrder
SELECT PurchaseNo,Status,TotalAmount FROM dbo.PurchaseOrder;

INSERT week6.BaselinePurchaseItem
SELECT po.PurchaseNo,p.SKU,pi.Quantity,pi.UnitCost,pi.LineAmount
FROM dbo.PurchaseItem AS pi
JOIN dbo.PurchaseOrder AS po ON po.PurchaseID=pi.PurchaseID
JOIN dbo.Product AS p ON p.ProductID=pi.ProductID;

INSERT week6.BaselineSaleItem
SELECT so.SaleNo,p.SKU,si.Quantity,si.UnitPrice,si.LineAmount
FROM dbo.SaleItem AS si
JOIN dbo.SaleOrder AS so ON so.SaleID=si.SaleID
JOIN dbo.Product AS p ON p.ProductID=si.ProductID;

INSERT week6.BaselineSaleOrder
SELECT SaleNo,Status,TotalAmount,DiscountAmount,PayableAmount FROM dbo.SaleOrder;

-- v_product_sales 对“尚无销售的商品”做外连接聚合；临时关闭警告避免输出无害的 NULL 消除提示。
SET ANSI_WARNINGS OFF;
INSERT week6.BaselineProductSales
SELECT SKU,SoldQuantity,SalesAmount FROM dbo.v_product_sales;
SET ANSI_WARNINGS ON;

INSERT week6.BaselineInventory
SELECT p.SKU,i.Quantity,i.MinQuantity
FROM dbo.Inventory AS i JOIN dbo.Product AS p ON p.ProductID=i.ProductID;

INSERT week6.BaselineInventoryLog
SELECT il.LogID,p.SKU,il.ChangeType,il.ChangeQuantity,il.BeforeQuantity,
       il.AfterQuantity,il.BusinessNo,e.EmployeeNo,il.Remark,il.CreatedAt
FROM dbo.InventoryLog AS il
JOIN dbo.Product AS p ON p.ProductID=il.ProductID
LEFT JOIN dbo.Employee AS e ON e.EmployeeID=il.EmployeeID;

INSERT week6.BaselineMetric(MetricName,MetricValue)
SELECT N'CategoryRows',COUNT_BIG(*) FROM dbo.Category UNION ALL
SELECT N'SupplierRows',COUNT_BIG(*) FROM dbo.Supplier UNION ALL
SELECT N'EmployeeRows',COUNT_BIG(*) FROM dbo.Employee UNION ALL
SELECT N'ProductRows',COUNT_BIG(*) FROM dbo.Product UNION ALL
SELECT N'InventoryRows',COUNT_BIG(*) FROM dbo.Inventory UNION ALL
SELECT N'PurchaseOrderRows',COUNT_BIG(*) FROM dbo.PurchaseOrder UNION ALL
SELECT N'PurchaseItemRows',COUNT_BIG(*) FROM dbo.PurchaseItem UNION ALL
SELECT N'SaleOrderRows',COUNT_BIG(*) FROM dbo.SaleOrder UNION ALL
SELECT N'SaleItemRows',COUNT_BIG(*) FROM dbo.SaleItem UNION ALL
SELECT N'InventoryLogRows',COUNT_BIG(*) FROM dbo.InventoryLog UNION ALL
SELECT N'ReceivedPurchaseAmount',COALESCE(SUM(TotalAmount),0) FROM dbo.PurchaseOrder WHERE Status='RECEIVED' UNION ALL
SELECT N'CompletedSaleAmount',COALESCE(SUM(TotalAmount),0) FROM dbo.SaleOrder WHERE Status='COMPLETED';

SELECT MetricName,MetricValue FROM week6.BaselineMetric ORDER BY MetricName;
SELECT TOP (20) * FROM week6.BaselineInventoryLog ORDER BY LogID;
PRINT N'第六周迁移前基线已保存到 week6 架构';
GO
