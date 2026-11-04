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
    IF EXISTS (SELECT 1 FROM dbo.Category
               WHERE CategoryCode IN ('FOOD','DRINK','SNACK','DAILY','STATIONERY'))
        THROW 51400, N'演示数据已存在', 1;
    DECLARE @food bigint, @drink bigint, @snack bigint, @daily bigint, @stationery bigint;
    DECLARE @supplier1 bigint, @supplier2 bigint;
    DECLARE @admin bigint, @purchaser bigint, @cashier bigint;
    DECLARE @cola bigint, @water bigint, @chips bigint, @noodle bigint, @paper bigint, @pen bigint;
    DECLARE @purchase bigint, @sale bigint;

    -- 分类既包含一级分类，也包含父子关系，便于展示 Category 的自关联。
    INSERT dbo.Category(CategoryCode,CategoryName) VALUES ('FOOD',N'食品');
    SET @food=SCOPE_IDENTITY();
    INSERT dbo.Category(CategoryCode,CategoryName,ParentID) VALUES ('DRINK',N'饮料',@food);
    SET @drink=SCOPE_IDENTITY();
    INSERT dbo.Category(CategoryCode,CategoryName,ParentID) VALUES ('SNACK',N'零食',@food);
    SET @snack=SCOPE_IDENTITY();
    INSERT dbo.Category(CategoryCode,CategoryName) VALUES ('DAILY',N'日用品');
    SET @daily=SCOPE_IDENTITY();
    INSERT dbo.Category(CategoryCode,CategoryName) VALUES ('STATIONERY',N'文具');
    SET @stationery=SCOPE_IDENTITY();

    -- 两个供应商和三类员工让采购、销售与权限角色更接近真实场景。
    INSERT dbo.Supplier(SupplierCode,SupplierName,ContactName)
    VALUES ('S001',N'校园供货商',N'张经理');
    SET @supplier1=SCOPE_IDENTITY();
    INSERT dbo.Supplier(SupplierCode,SupplierName,ContactName)
    VALUES ('S002',N'食品批发商',N'李经理');
    SET @supplier2=SCOPE_IDENTITY();
    INSERT dbo.Employee(EmployeeNo,EmployeeName,RoleName)
    VALUES ('E001',N'管理员','ADMIN');
    SET @admin=SCOPE_IDENTITY();
    INSERT dbo.Employee(EmployeeNo,EmployeeName,RoleName)
    VALUES ('E002',N'采购员','PURCHASER');
    SET @purchaser=SCOPE_IDENTITY();
    INSERT dbo.Employee(EmployeeNo,EmployeeName,RoleName)
    VALUES ('E003',N'收银员','CASHIER');
    SET @cashier=SCOPE_IDENTITY();

    -- 六种商品覆盖饮料、零食、日用品和文具，并保留一件零销量商品。
    INSERT dbo.Product(SKU,Barcode,ProductName,CategoryID,Specification,Unit,SalePrice)
    VALUES ('P0001','690000000001',N'可口可乐',@drink,N'500ml',N'瓶',3.50);
    SET @cola=SCOPE_IDENTITY();
    INSERT dbo.Product(SKU,Barcode,ProductName,CategoryID,Unit,SalePrice)
    VALUES ('P0002','690000000002',N'纸巾',@daily,N'包',5.00);
    SET @paper=SCOPE_IDENTITY();
    INSERT dbo.Product(SKU,Barcode,ProductName,CategoryID,Specification,Unit,SalePrice)
    VALUES ('P0003','690000000003',N'矿泉水',@drink,N'550ml',N'瓶',2.00);
    SET @water=SCOPE_IDENTITY();
    INSERT dbo.Product(SKU,Barcode,ProductName,CategoryID,Specification,Unit,SalePrice)
    VALUES ('P0004','690000000004',N'薯片',@snack,N'70g',N'袋',4.00);
    SET @chips=SCOPE_IDENTITY();
    INSERT dbo.Product(SKU,Barcode,ProductName,CategoryID,Specification,Unit,SalePrice)
    VALUES ('P0005','690000000005',N'方便面',@snack,N'桶装',N'桶',5.00);
    SET @noodle=SCOPE_IDENTITY();
    INSERT dbo.Product(SKU,Barcode,ProductName,CategoryID,Specification,Unit,SalePrice)
    VALUES ('P0006','690000000006',N'黑色中性笔',@stationery,N'0.5mm',N'支',2.00);
    SET @pen=SCOPE_IDENTITY();
    UPDATE dbo.Inventory SET MinQuantity=20 WHERE ProductID=@cola;
    UPDATE dbo.Inventory SET MinQuantity=15 WHERE ProductID=@water;
    UPDATE dbo.Inventory SET MinQuantity=8 WHERE ProductID=@chips;
    UPDATE dbo.Inventory SET MinQuantity=5 WHERE ProductID=@noodle;
    UPDATE dbo.Inventory SET MinQuantity=10 WHERE ProductID=@paper;
    UPDATE dbo.Inventory SET MinQuantity=5 WHERE ProductID=@pen;

    -- 三张采购单分属两个供应商，分别形成正常、低库存和缺货演示数据。
    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID,OrderTime)
    VALUES ('PO-DEMO-001',@supplier1,@purchaser,DATEADD(DAY,-4,SYSDATETIME()));
    SET @purchase=SCOPE_IDENTITY();
    INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost)
    VALUES (@purchase,@cola,30,2.20),(@purchase,@paper,6,3.00);
    EXEC dbo.ConfirmPurchase @purchase;
    UPDATE dbo.PurchaseOrder SET ReceivedTime=DATEADD(DAY,-4,SYSDATETIME())
    WHERE PurchaseID=@purchase;

    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID,OrderTime)
    VALUES ('PO-DEMO-002',@supplier2,@purchaser,DATEADD(DAY,-3,SYSDATETIME()));
    SET @purchase=SCOPE_IDENTITY();
    INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost)
    VALUES (@purchase,@water,40,1.00),(@purchase,@chips,20,2.50),(@purchase,@noodle,15,3.00);
    EXEC dbo.ConfirmPurchase @purchase;
    UPDATE dbo.PurchaseOrder SET ReceivedTime=DATEADD(DAY,-3,SYSDATETIME())
    WHERE PurchaseID=@purchase;

    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID,OrderTime)
    VALUES ('PO-DEMO-003',@supplier2,@purchaser,DATEADD(DAY,-2,SYSDATETIME()));
    SET @purchase=SCOPE_IDENTITY();
    INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost)
    VALUES (@purchase,@pen,3,1.00);
    EXEC dbo.ConfirmPurchase @purchase;
    UPDATE dbo.PurchaseOrder SET ReceivedTime=DATEADD(DAY,-2,SYSDATETIME())
    WHERE PurchaseID=@purchase;

    -- 三张销售单使用不同日期和支付方式，便于展示每日销售统计。
    INSERT dbo.SaleOrder(SaleNo,EmployeeID,SaleTime,DiscountAmount,PaymentMethod)
    VALUES ('SO-DEMO-001',@cashier,DATEADD(DAY,-2,SYSDATETIME()),0.50,'CASH');
    SET @sale=SCOPE_IDENTITY();
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
    VALUES (@sale,@cola,3,3.50);
    EXEC dbo.CompleteSale @sale;
    UPDATE dbo.SaleOrder SET SaleTime=DATEADD(DAY,-2,SYSDATETIME())
    WHERE SaleID=@sale;

    INSERT dbo.SaleOrder(SaleNo,EmployeeID,SaleTime,DiscountAmount,PaymentMethod)
    VALUES ('SO-DEMO-002',@cashier,DATEADD(DAY,-1,SYSDATETIME()),0.00,'WECHAT');
    SET @sale=SCOPE_IDENTITY();
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
    VALUES (@sale,@water,5,2.00),(@sale,@chips,2,4.00);
    EXEC dbo.CompleteSale @sale;
    UPDATE dbo.SaleOrder SET SaleTime=DATEADD(DAY,-1,SYSDATETIME())
    WHERE SaleID=@sale;

    INSERT dbo.SaleOrder(SaleNo,EmployeeID,SaleTime,DiscountAmount,PaymentMethod)
    VALUES ('SO-DEMO-003',@cashier,SYSDATETIME(),1.00,'ALIPAY');
    SET @sale=SCOPE_IDENTITY();
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
    VALUES (@sale,@noodle,2,5.00),(@sale,@pen,3,2.00);
    EXEC dbo.CompleteSale @sale;
    COMMIT;
    PRINT N'扩充后的演示数据已导入：5 个分类、6 个商品、2 个供应商、3 名员工、3 张采购单和 3 张销售单';
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;
GO
