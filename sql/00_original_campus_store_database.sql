/*
	校园小卖部经营管理数据库
	用途：创建数据库及第二周确定的 10 张核心表
	目标实例： (local)\SQLEXPRESS

	注意：本脚本会创建数据库和数据表。
	请在 SSMS 中确认目标实例后执行。
*/

CREATE DATABASE [CampusStoreDB];
GO

USE [CampusStoreDB];
GO

CREATE TABLE dbo.Category
(
	CategoryID   int IDENTITY(1, 1) NOT NULL,
	CategoryName nvarchar(50) NOT NULL,
	Description  nvarchar(200) NULL,
	CONSTRAINT PK_Category PRIMARY KEY (CategoryID),
	CONSTRAINT UQ_Category_CategoryName UNIQUE (CategoryName)
);
GO

CREATE TABLE dbo.Supplier
(
	SupplierID   int IDENTITY(1, 1) NOT NULL,
	SupplierName nvarchar(100) NOT NULL,
	ContactName  nvarchar(50) NULL,
	Phone        varchar(20) NULL,
	Address      nvarchar(200) NULL,
	IsActive     bit NOT NULL CONSTRAINT DF_Supplier_IsActive DEFAULT (1),
	CONSTRAINT PK_Supplier PRIMARY KEY (SupplierID)
);
GO

CREATE TABLE dbo.Employee
(
	EmployeeID   int IDENTITY(1, 1) NOT NULL,
	EmployeeName nvarchar(50) NOT NULL,
	RoleName     nvarchar(30) NOT NULL,
	Phone        varchar(20) NULL,
	HireDate     date NULL,
	IsActive     bit NOT NULL CONSTRAINT DF_Employee_IsActive DEFAULT (1),
	CONSTRAINT PK_Employee PRIMARY KEY (EmployeeID)
);
GO

CREATE TABLE dbo.Product
(
	ProductID       int IDENTITY(1, 1) NOT NULL,
	ProductName     nvarchar(100) NOT NULL,
	CategoryID      int NOT NULL,
	Barcode         varchar(50) NULL,
	Specification   nvarchar(50) NULL,
	PurchasePrice   decimal(10, 2) NOT NULL,
	SalePrice       decimal(10, 2) NOT NULL,
	Unit            nvarchar(20) NOT NULL,
	IsOnSale        bit NOT NULL CONSTRAINT DF_Product_IsOnSale DEFAULT (1),
	WarningQuantity int NOT NULL CONSTRAINT DF_Product_WarningQuantity DEFAULT (10),
	CONSTRAINT PK_Product PRIMARY KEY (ProductID),
	CONSTRAINT FK_Product_Category FOREIGN KEY (CategoryID)
		REFERENCES dbo.Category (CategoryID),
	CONSTRAINT CK_Product_PurchasePrice CHECK (PurchasePrice >= 0),
	CONSTRAINT CK_Product_SalePrice CHECK (SalePrice >= 0),
	CONSTRAINT CK_Product_WarningQuantity CHECK (WarningQuantity >= 0)
);
GO

CREATE UNIQUE INDEX UX_Product_Barcode
	ON dbo.Product (Barcode)
	WHERE Barcode IS NOT NULL;
GO

CREATE TABLE dbo.PurchaseOrder
(
	PurchaseID   int IDENTITY(1, 1) NOT NULL,
	SupplierID   int NOT NULL,
	EmployeeID   int NOT NULL,
	PurchaseDate datetime2(0) NOT NULL CONSTRAINT DF_PurchaseOrder_PurchaseDate DEFAULT (SYSDATETIME()),
	TotalAmount  decimal(12, 2) NOT NULL CONSTRAINT DF_PurchaseOrder_TotalAmount DEFAULT (0),
	Status       nvarchar(20) NOT NULL CONSTRAINT DF_PurchaseOrder_Status DEFAULT (N'已完成'),
	CONSTRAINT PK_PurchaseOrder PRIMARY KEY (PurchaseID),
	CONSTRAINT FK_PurchaseOrder_Supplier FOREIGN KEY (SupplierID)
		REFERENCES dbo.Supplier (SupplierID),
	CONSTRAINT FK_PurchaseOrder_Employee FOREIGN KEY (EmployeeID)
		REFERENCES dbo.Employee (EmployeeID),
	CONSTRAINT CK_PurchaseOrder_TotalAmount CHECK (TotalAmount >= 0)
);
GO

CREATE TABLE dbo.PurchaseDetail
(
	PurchaseDetailID int IDENTITY(1, 1) NOT NULL,
	PurchaseID       int NOT NULL,
	ProductID        int NOT NULL,
	Quantity         int NOT NULL,
	UnitPrice        decimal(10, 2) NOT NULL,
	Amount           AS (CONVERT(decimal(12, 2), Quantity * UnitPrice)) PERSISTED,
	CONSTRAINT PK_PurchaseDetail PRIMARY KEY (PurchaseDetailID),
	CONSTRAINT FK_PurchaseDetail_PurchaseOrder FOREIGN KEY (PurchaseID)
		REFERENCES dbo.PurchaseOrder (PurchaseID),
	CONSTRAINT FK_PurchaseDetail_Product FOREIGN KEY (ProductID)
		REFERENCES dbo.Product (ProductID),
	CONSTRAINT CK_PurchaseDetail_Quantity CHECK (Quantity > 0),
	CONSTRAINT CK_PurchaseDetail_UnitPrice CHECK (UnitPrice >= 0)
);
GO

CREATE TABLE dbo.SalesOrder
(
	SalesOrderID  int IDENTITY(1, 1) NOT NULL,
	EmployeeID    int NOT NULL,
	SalesDate     datetime2(0) NOT NULL CONSTRAINT DF_SalesOrder_SalesDate DEFAULT (SYSDATETIME()),
	PaymentMethod nvarchar(20) NOT NULL,
	TotalAmount   decimal(12, 2) NOT NULL CONSTRAINT DF_SalesOrder_TotalAmount DEFAULT (0),
	Status        nvarchar(20) NOT NULL CONSTRAINT DF_SalesOrder_Status DEFAULT (N'已支付'),
	CONSTRAINT PK_SalesOrder PRIMARY KEY (SalesOrderID),
	CONSTRAINT FK_SalesOrder_Employee FOREIGN KEY (EmployeeID)
		REFERENCES dbo.Employee (EmployeeID),
	CONSTRAINT CK_SalesOrder_TotalAmount CHECK (TotalAmount >= 0)
);
GO

CREATE TABLE dbo.SalesDetail
(
	SalesDetailID int IDENTITY(1, 1) NOT NULL,
	SalesOrderID  int NOT NULL,
	ProductID     int NOT NULL,
	Quantity      int NOT NULL,
	UnitPrice     decimal(10, 2) NOT NULL,
	Amount        AS (CONVERT(decimal(12, 2), Quantity * UnitPrice)) PERSISTED,
	CONSTRAINT PK_SalesDetail PRIMARY KEY (SalesDetailID),
	CONSTRAINT FK_SalesDetail_SalesOrder FOREIGN KEY (SalesOrderID)
		REFERENCES dbo.SalesOrder (SalesOrderID),
	CONSTRAINT FK_SalesDetail_Product FOREIGN KEY (ProductID)
		REFERENCES dbo.Product (ProductID),
	CONSTRAINT CK_SalesDetail_Quantity CHECK (Quantity > 0),
	CONSTRAINT CK_SalesDetail_UnitPrice CHECK (UnitPrice >= 0)
);
GO

CREATE TABLE dbo.Inventory
(
	InventoryID     int IDENTITY(1, 1) NOT NULL,
	ProductID       int NOT NULL,
	CurrentQuantity int NOT NULL CONSTRAINT DF_Inventory_CurrentQuantity DEFAULT (0),
	LastUpdated     datetime2(0) NOT NULL CONSTRAINT DF_Inventory_LastUpdated DEFAULT (SYSDATETIME()),
	CONSTRAINT PK_Inventory PRIMARY KEY (InventoryID),
	CONSTRAINT UQ_Inventory_Product UNIQUE (ProductID),
	CONSTRAINT FK_Inventory_Product FOREIGN KEY (ProductID)
		REFERENCES dbo.Product (ProductID),
	CONSTRAINT CK_Inventory_CurrentQuantity CHECK (CurrentQuantity >= 0)
);
GO

CREATE TABLE dbo.InventoryTransaction
(
	TransactionID   int IDENTITY(1, 1) NOT NULL,
	ProductID       int NOT NULL,
	TransactionType nvarchar(20) NOT NULL,
	Quantity        int NOT NULL,
	ReferenceID     int NULL,
	TransactionDate datetime2(0) NOT NULL CONSTRAINT DF_InventoryTransaction_TransactionDate DEFAULT (SYSDATETIME()),
	EmployeeID      int NOT NULL,
	CONSTRAINT PK_InventoryTransaction PRIMARY KEY (TransactionID),
	CONSTRAINT FK_InventoryTransaction_Product FOREIGN KEY (ProductID)
		REFERENCES dbo.Product (ProductID),
	CONSTRAINT FK_InventoryTransaction_Employee FOREIGN KEY (EmployeeID)
		REFERENCES dbo.Employee (EmployeeID),
	CONSTRAINT CK_InventoryTransaction_Quantity CHECK (Quantity <> 0),
	CONSTRAINT CK_InventoryTransaction_Type CHECK
		(TransactionType IN (N'进货', N'销售', N'退货', N'盘盈', N'盘亏', N'报损'))
);
GO

/* 创建常用查询索引 */
CREATE INDEX IX_Product_CategoryID ON dbo.Product (CategoryID);
CREATE INDEX IX_PurchaseOrder_PurchaseDate ON dbo.PurchaseOrder (PurchaseDate);
CREATE INDEX IX_PurchaseDetail_ProductID ON dbo.PurchaseDetail (ProductID);
CREATE INDEX IX_SalesOrder_SalesDate ON dbo.SalesOrder (SalesDate);
CREATE INDEX IX_SalesDetail_ProductID ON dbo.SalesDetail (ProductID);
CREATE INDEX IX_InventoryTransaction_ProductDate
	ON dbo.InventoryTransaction (ProductID, TransactionDate);
GO
