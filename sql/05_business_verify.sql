USE CampusStoreDB;
GO
IF DB_NAME() NOT LIKE '%[_]Verify[_]%'
    THROW 51150, N'业务测试仅可在一次性验证数据库运行', 1;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
GO
SET XACT_ABORT OFF;
BEGIN TRY
    DECLARE @tag varchar(12) = LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),12);
    DECLARE @category bigint, @categoryChild bigint, @supplier bigint, @employee bigint, @product bigint, @product2 bigint;
    DECLARE @purchase bigint, @sale bigint, @saleTooLarge bigint;
    DECLARE @productUpdatedAt datetime2(0);

    INSERT dbo.Category(CategoryCode,CategoryName) VALUES ('TC'+@tag,N'测试分类');
    SET @category = SCOPE_IDENTITY();
    INSERT dbo.Category(CategoryCode,CategoryName,ParentID)
    VALUES ('TU'+@tag,N'测试子分类',@category);
    SET @categoryChild = SCOPE_IDENTITY();
    BEGIN TRY
        UPDATE dbo.Category SET ParentID=@categoryChild WHERE CategoryID=@category;
        THROW 51116, N'分类循环未拒绝', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51010 THROW;
    END CATCH;
    IF (SELECT ParentID FROM dbo.Category WHERE CategoryID=@category) IS NOT NULL
        THROW 51117, N'分类循环失败后父分类被修改', 1;
    INSERT dbo.Supplier(SupplierCode,SupplierName) VALUES ('TS'+@tag,N'测试供应商');
    SET @supplier = SCOPE_IDENTITY();
    INSERT dbo.Employee(EmployeeNo,EmployeeName,RoleName) VALUES ('TE'+@tag,N'测试员工','ADMIN');
    SET @employee = SCOPE_IDENTITY();
    INSERT dbo.Product(SKU,ProductName,CategoryID,SalePrice) VALUES ('TP'+@tag,N'测试商品',@category,3.50);
    SET @product = SCOPE_IDENTITY();
    INSERT dbo.Product(SKU,ProductName,CategoryID,SalePrice) VALUES ('TQ'+@tag,N'缺货商品',@category,5.00);
    SET @product2 = SCOPE_IDENTITY();
    IF (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@product) <> 0
        THROW 51100, N'商品建档后库存不为零', 1;

    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID)
    VALUES ('PO'+@tag,@supplier,@employee);
    SET @purchase = SCOPE_IDENTITY();
    INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost)
    VALUES (@purchase,@product,10,2.20);
    EXEC dbo.ConfirmPurchase @purchase;
    IF NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrder
                   WHERE PurchaseID=@purchase AND Status='RECEIVED' AND TotalAmount=22.00 AND ReceivedTime IS NOT NULL)
        THROW 51101, N'采购金额或状态错误', 1;
    IF (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@product) <> 10
        THROW 51102, N'采购后库存错误', 1;
    BEGIN TRY
        UPDATE dbo.Inventory SET Quantity=9 WHERE ProductID=@product;
        THROW 51118, N'直接修改库存数量未拒绝', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51011 THROW;
    END CATCH;
    IF (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@product) <> 10
        THROW 51119, N'直接修改库存失败后数量被改变', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.InventoryLog WHERE ProductID=@product
                   AND BusinessNo='PO'+@tag AND ChangeQuantity=10 AND BeforeQuantity=0 AND AfterQuantity=10)
        THROW 51103, N'采购流水错误', 1;
    BEGIN TRY
        EXEC dbo.ConfirmPurchase @purchase;
        THROW 51104, N'重复采购确认未拒绝', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51200 THROW;
    END CATCH;
    BEGIN TRY
        UPDATE dbo.PurchaseOrder SET Status='DRAFT' WHERE PurchaseID=@purchase;
        THROW 51114, N'已入库采购单可以退回草稿', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51220 THROW;
    END CATCH;
    BEGIN TRY
        UPDATE dbo.PurchaseItem SET Quantity=11 WHERE PurchaseID=@purchase;
        THROW 51112, N'已入库采购明细仍可修改', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51210 THROW;
    END CATCH;

    INSERT dbo.SaleOrder(SaleNo,EmployeeID,DiscountAmount,PaymentMethod)
    VALUES ('SO'+@tag,@employee,1.00,'CASH');
    SET @sale = SCOPE_IDENTITY();
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
    VALUES (@sale,@product,3,3.50);
    EXEC dbo.CompleteSale @sale;
    IF NOT EXISTS (SELECT 1 FROM dbo.SaleOrder WHERE SaleID=@sale
                   AND Status='COMPLETED' AND TotalAmount=10.50 AND PayableAmount=9.50)
        THROW 51105, N'销售金额或状态错误', 1;
    IF (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@product) <> 7
        THROW 51106, N'销售后库存错误', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.InventoryLog WHERE ProductID=@product
                   AND BusinessNo='SO'+@tag AND ChangeQuantity=-3 AND BeforeQuantity=10 AND AfterQuantity=7)
        THROW 51107, N'销售流水错误', 1;
    SELECT @productUpdatedAt=UpdatedAt FROM dbo.Product WHERE ProductID=@product;
    WAITFOR DELAY '00:00:01';
    UPDATE dbo.Product SET SalePrice=4.00 WHERE ProductID=@product;
    IF (SELECT UpdatedAt FROM dbo.Product WHERE ProductID=@product) <= @productUpdatedAt
        THROW 51120, N'商品更新时间未自动刷新', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.v_sale_detail
                   WHERE SaleNo='SO'+@tag AND UnitPrice=3.50 AND LineAmount=10.50)
        THROW 51111, N'商品改价后历史销售价格发生变化', 1;
    BEGIN TRY
        EXEC dbo.CompleteSale @sale;
        THROW 51108, N'重复销售结算未拒绝', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51300 THROW;
    END CATCH;
    BEGIN TRY
        UPDATE dbo.SaleOrder SET Status='DRAFT' WHERE SaleID=@sale;
        THROW 51115, N'已完成销售单可以退回草稿', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51320 THROW;
    END CATCH;
    BEGIN TRY
        UPDATE dbo.SaleItem SET Quantity=4 WHERE SaleID=@sale;
        THROW 51113, N'已完成销售明细仍可修改', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51310 THROW;
    END CATCH;

    INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod) VALUES ('SX'+@tag,@employee,'CASH');
    SET @saleTooLarge = SCOPE_IDENTITY();
    -- 第一项可扣减，第二项缺货，必须整单回滚。
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
    VALUES (@saleTooLarge,@product,1,3.50),(@saleTooLarge,@product2,1,5.00);
    BEGIN TRY
        EXEC dbo.CompleteSale @saleTooLarge;
        THROW 51109, N'超卖未拒绝', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51305 THROW;
    END CATCH;
    IF (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@product) <> 7
        OR (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@product2) <> 0
        OR EXISTS (SELECT 1 FROM dbo.InventoryLog WHERE BusinessNo='SX'+@tag)
        THROW 51110, N'超卖失败后库存或流水被修改', 1;

    PRINT N'采购、销售及整单回滚验证通过';
END TRY
BEGIN CATCH
    THROW;
END CATCH;
GO
