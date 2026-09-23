/* 演示数据，仅在新的 CampusStoreDB 上运行一次。 */
USE CampusStoreDB;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
GO
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRAN;
    IF EXISTS (SELECT 1 FROM dbo.Category WHERE CategoryCode IN ('DRINK','DAILY'))
        THROW 51400, N'演示数据已存在', 1;
    DECLARE @drink bigint, @daily bigint, @supplier bigint, @employee bigint;
    DECLARE @cola bigint, @paper bigint, @purchase bigint, @sale bigint;

    INSERT dbo.Category(CategoryCode,CategoryName) VALUES ('DRINK',N'饮料');
    SET @drink=SCOPE_IDENTITY();
    INSERT dbo.Category(CategoryCode,CategoryName) VALUES ('DAILY',N'日用品');
    SET @daily=SCOPE_IDENTITY();
    INSERT dbo.Supplier(SupplierCode,SupplierName,ContactName)
    VALUES ('S001',N'校园供货商',N'张经理');
    SET @supplier=SCOPE_IDENTITY();
    INSERT dbo.Employee(EmployeeNo,EmployeeName,RoleName)
    VALUES ('E001',N'演示员工','ADMIN');
    SET @employee=SCOPE_IDENTITY();
    INSERT dbo.Product(SKU,Barcode,ProductName,CategoryID,Specification,Unit,SalePrice)
    VALUES ('P0001','690000000001',N'可口可乐',@drink,N'500ml',N'瓶',3.50);
    SET @cola=SCOPE_IDENTITY();
    INSERT dbo.Product(SKU,Barcode,ProductName,CategoryID,Unit,SalePrice)
    VALUES ('P0002','690000000002',N'纸巾',@daily,N'包',5.00);
    SET @paper=SCOPE_IDENTITY();
    UPDATE dbo.Inventory SET MinQuantity=20 WHERE ProductID=@cola;
    UPDATE dbo.Inventory SET MinQuantity=10 WHERE ProductID=@paper;

    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID)
    VALUES ('PO-DEMO-001',@supplier,@employee);
    SET @purchase=SCOPE_IDENTITY();
    INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost)
    VALUES (@purchase,@cola,30,2.20),(@purchase,@paper,6,3.00);
    EXEC dbo.ConfirmPurchase @purchase;

    INSERT dbo.SaleOrder(SaleNo,EmployeeID,DiscountAmount,PaymentMethod)
    VALUES ('SO-DEMO-001',@employee,0.50,'CASH');
    SET @sale=SCOPE_IDENTITY();
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
    VALUES (@sale,@cola,3,3.50);
    EXEC dbo.CompleteSale @sale;
    COMMIT;
    PRINT N'演示数据已导入';
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;
GO
