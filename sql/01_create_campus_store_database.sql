/* 校园小卖部进销存；SQL Server Express；仅在新数据库运行一次。 */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
GO
USE master;
GO
IF DB_ID(N'CampusStoreDB') IS NOT NULL
    THROW 50000, N'CampusStoreDB 已存在，请勿重复运行建库脚本', 1;
GO
CREATE DATABASE CampusStoreDB;
GO
USE CampusStoreDB;
GO
CREATE TABLE dbo.Category (
 CategoryID bigint IDENTITY(1,1) PRIMARY KEY,
 CategoryCode varchar(20) NOT NULL UNIQUE,
 CategoryName nvarchar(50) NOT NULL,
 ParentID bigint NULL REFERENCES dbo.Category(CategoryID),
 Description nvarchar(255) NULL,
 Status bit NOT NULL DEFAULT 1,
 CreatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 UpdatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME()
);
CREATE INDEX IX_Category_Parent ON dbo.Category(ParentID);
CREATE TABLE dbo.Supplier (
 SupplierID bigint IDENTITY(1,1) PRIMARY KEY,
 SupplierCode varchar(20) NOT NULL UNIQUE,
 SupplierName nvarchar(100) NOT NULL,
 ContactName nvarchar(50) NULL,
 Phone varchar(30) NULL,
 Address nvarchar(255) NULL,
 Status bit NOT NULL DEFAULT 1,
 CreatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 UpdatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME()
);
CREATE TABLE dbo.Employee (
 EmployeeID bigint IDENTITY(1,1) PRIMARY KEY,
 EmployeeNo varchar(20) NOT NULL UNIQUE,
 EmployeeName nvarchar(50) NOT NULL,
 RoleName varchar(20) NOT NULL,
 Phone varchar(30) NULL,
 Status bit NOT NULL DEFAULT 1,
 CreatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 CONSTRAINT CK_Employee_Role CHECK (RoleName IN ('ADMIN','PURCHASER','CASHIER'))
);
CREATE TABLE dbo.Product (
 ProductID bigint IDENTITY(1,1) PRIMARY KEY,
 SKU varchar(30) NOT NULL UNIQUE,
 Barcode varchar(32) NULL,
 ProductName nvarchar(100) NOT NULL,
 CategoryID bigint NOT NULL REFERENCES dbo.Category(CategoryID),
 Specification nvarchar(100) NULL,
 Unit nvarchar(20) NOT NULL DEFAULT N'件',
 SalePrice decimal(10,2) NOT NULL,
 Status bit NOT NULL DEFAULT 1,
 CreatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 UpdatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 CONSTRAINT CK_Product_Price CHECK (SalePrice >= 0)
);
CREATE UNIQUE INDEX UX_Product_Barcode ON dbo.Product(Barcode) WHERE Barcode IS NOT NULL;
CREATE INDEX IX_Product_Category ON dbo.Product(CategoryID);
CREATE INDEX IX_Product_Name ON dbo.Product(ProductName);
CREATE TABLE dbo.Inventory (
 ProductID bigint NOT NULL PRIMARY KEY REFERENCES dbo.Product(ProductID),
 Quantity int NOT NULL DEFAULT 0,
 MinQuantity int NOT NULL DEFAULT 10,
 UpdatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 CONSTRAINT CK_Inventory_Quantity CHECK (Quantity >= 0),
 CONSTRAINT CK_Inventory_Min CHECK (MinQuantity >= 0)
);
GO
-- 多行插入商品时，也为每一件商品建立零库存记录。
CREATE TRIGGER dbo.tr_Product_CreateInventory ON dbo.Product AFTER INSERT AS
BEGIN
 SET NOCOUNT ON;
 INSERT dbo.Inventory(ProductID, Quantity) SELECT ProductID, 0 FROM inserted;
END;
GO
CREATE TABLE dbo.PurchaseOrder (
 PurchaseID bigint IDENTITY(1,1) PRIMARY KEY,
 PurchaseNo varchar(30) NOT NULL UNIQUE,
 SupplierID bigint NOT NULL REFERENCES dbo.Supplier(SupplierID),
 EmployeeID bigint NOT NULL REFERENCES dbo.Employee(EmployeeID),
 OrderTime datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 ReceivedTime datetime2(0) NULL,
 Status varchar(20) NOT NULL DEFAULT 'DRAFT',
 TotalAmount decimal(12,2) NOT NULL DEFAULT 0,
 Remark nvarchar(255) NULL,
 CreatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 UpdatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 CONSTRAINT CK_PurchaseOrder_Status CHECK (Status IN ('DRAFT','RECEIVED','CANCELLED')),
 CONSTRAINT CK_PurchaseOrder_Total CHECK (TotalAmount >= 0)
);
CREATE INDEX IX_PurchaseOrder_Supplier ON dbo.PurchaseOrder(SupplierID);
CREATE INDEX IX_PurchaseOrder_Time ON dbo.PurchaseOrder(OrderTime);
CREATE TABLE dbo.PurchaseItem (
 PurchaseItemID bigint IDENTITY(1,1) PRIMARY KEY,
 PurchaseID bigint NOT NULL REFERENCES dbo.PurchaseOrder(PurchaseID),
 ProductID bigint NOT NULL REFERENCES dbo.Product(ProductID),
 Quantity int NOT NULL,
 UnitCost decimal(10,2) NOT NULL,
 LineAmount AS CONVERT(decimal(12,2), Quantity * UnitCost) PERSISTED,
 CONSTRAINT UQ_PurchaseItem_Product UNIQUE(PurchaseID,ProductID),
 CONSTRAINT CK_PurchaseItem_Quantity CHECK (Quantity > 0),
 CONSTRAINT CK_PurchaseItem_Cost CHECK (UnitCost >= 0)
);
CREATE INDEX IX_PurchaseItem_Product ON dbo.PurchaseItem(ProductID);
CREATE TABLE dbo.SaleOrder (
 SaleID bigint IDENTITY(1,1) PRIMARY KEY,
 SaleNo varchar(30) NOT NULL UNIQUE,
 EmployeeID bigint NOT NULL REFERENCES dbo.Employee(EmployeeID),
 SaleTime datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 Status varchar(20) NOT NULL DEFAULT 'DRAFT',
 TotalAmount decimal(12,2) NOT NULL DEFAULT 0,
 DiscountAmount decimal(12,2) NOT NULL DEFAULT 0,
 PayableAmount AS CONVERT(decimal(12,2), TotalAmount - DiscountAmount) PERSISTED,
 PaymentMethod varchar(20) NULL,
 Remark nvarchar(255) NULL,
 CreatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 CONSTRAINT CK_SaleOrder_Status CHECK (Status IN ('DRAFT','COMPLETED','CANCELLED')),
 CONSTRAINT CK_SaleOrder_Payment CHECK (PaymentMethod IS NULL OR PaymentMethod IN ('CASH','WECHAT','ALIPAY','BANK_CARD')),
 CONSTRAINT CK_SaleOrder_Amount CHECK
  (TotalAmount >= 0 AND DiscountAmount >= 0
   AND (Status='DRAFT' OR DiscountAmount <= TotalAmount))
);
CREATE INDEX IX_SaleOrder_Time ON dbo.SaleOrder(SaleTime);
CREATE INDEX IX_SaleOrder_Employee ON dbo.SaleOrder(EmployeeID);
CREATE TABLE dbo.SaleItem (
 SaleItemID bigint IDENTITY(1,1) PRIMARY KEY,
 SaleID bigint NOT NULL REFERENCES dbo.SaleOrder(SaleID),
 ProductID bigint NOT NULL REFERENCES dbo.Product(ProductID),
 Quantity int NOT NULL,
 UnitPrice decimal(10,2) NOT NULL,
 LineAmount AS CONVERT(decimal(12,2), Quantity * UnitPrice) PERSISTED,
 CONSTRAINT UQ_SaleItem_Product UNIQUE(SaleID,ProductID),
 CONSTRAINT CK_SaleItem_Quantity CHECK (Quantity > 0),
 CONSTRAINT CK_SaleItem_Price CHECK (UnitPrice >= 0)
);
CREATE INDEX IX_SaleItem_Product ON dbo.SaleItem(ProductID);
CREATE TABLE dbo.InventoryLog (
 LogID bigint IDENTITY(1,1) PRIMARY KEY,
 ProductID bigint NOT NULL REFERENCES dbo.Product(ProductID),
 ChangeType varchar(30) NOT NULL,
 ChangeQuantity int NOT NULL,
 BeforeQuantity int NOT NULL,
 AfterQuantity int NOT NULL,
 BusinessNo varchar(30) NULL,
 EmployeeID bigint NULL REFERENCES dbo.Employee(EmployeeID),
 Remark nvarchar(255) NULL,
 CreatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 CONSTRAINT CK_InventoryLog_Type CHECK (ChangeType IN
  ('PURCHASE_IN','SALE_OUT','SALE_RETURN','PURCHASE_RETURN','STOCKTAKE_IN','STOCKTAKE_OUT')),
 CONSTRAINT CK_InventoryLog_Quantity CHECK
  (ChangeQuantity <> 0 AND BeforeQuantity >= 0 AND AfterQuantity >= 0
   AND AfterQuantity = BeforeQuantity + ChangeQuantity)
);
CREATE INDEX IX_InventoryLog_ProductTime ON dbo.InventoryLog(ProductID,CreatedAt);
CREATE INDEX IX_InventoryLog_BusinessNo ON dbo.InventoryLog(BusinessNo);
GO
CREATE VIEW dbo.v_current_inventory AS
SELECT p.ProductID, p.SKU, p.Barcode, p.ProductName, c.CategoryName,
 p.Specification, p.Unit, p.SalePrice, i.Quantity, i.MinQuantity,
 CASE WHEN i.Quantity = 0 THEN 'OUT_OF_STOCK'
      WHEN i.Quantity < i.MinQuantity THEN 'LOW_STOCK' ELSE 'NORMAL' END AS StockStatus,
 i.UpdatedAt
FROM dbo.Product AS p
JOIN dbo.Category AS c ON c.CategoryID = p.CategoryID
JOIN dbo.Inventory AS i ON i.ProductID = p.ProductID;
GO
CREATE VIEW dbo.v_sale_detail AS
SELECT so.SaleNo, so.SaleTime, e.EmployeeName, p.SKU, p.ProductName,
 si.Quantity, si.UnitPrice, si.LineAmount, so.PaymentMethod
FROM dbo.SaleOrder AS so
JOIN dbo.Employee AS e ON e.EmployeeID = so.EmployeeID
JOIN dbo.SaleItem AS si ON si.SaleID = so.SaleID
JOIN dbo.Product AS p ON p.ProductID = si.ProductID
WHERE so.Status = 'COMPLETED';
GO
CREATE VIEW dbo.v_daily_sales AS
SELECT CONVERT(date,SaleTime) AS SaleDate, COUNT(*) AS OrderCount,
 SUM(TotalAmount) AS OriginalAmount, SUM(DiscountAmount) AS DiscountAmount,
 SUM(PayableAmount) AS SalesAmount
FROM dbo.SaleOrder WHERE Status = 'COMPLETED'
GROUP BY CONVERT(date,SaleTime);
GO
