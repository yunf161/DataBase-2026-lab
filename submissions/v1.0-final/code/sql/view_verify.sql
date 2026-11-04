USE CampusStoreDB;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
BEGIN TRY
    BEGIN TRAN;
    DECLARE @paper bigint=(SELECT ProductID FROM dbo.Product WHERE SKU='P0002');
    DECLARE @employee bigint=(SELECT EmployeeID FROM dbo.Employee WHERE EmployeeNo='E001');
    DECLARE @sale bigint;
    INSERT dbo.SaleOrder(SaleNo,EmployeeID,TotalAmount)
    VALUES ('VIEW-'+LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),12),@employee,999.00);
    SET @sale=SCOPE_IDENTITY();
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
    VALUES (@sale,@paper,1,5.00);
    -- 草稿销售不能进入统计；该商品仍需以零销量显示。
    IF NOT EXISTS (SELECT 1 FROM dbo.v_product_sales
                   WHERE ProductID=@paper AND SoldQuantity=0 AND SalesAmount=0)
        THROW 51700,N'草稿商品在统计视图中消失或被计入销量',1;
    IF NOT EXISTS (SELECT 1 FROM dbo.v_product_sales
                   WHERE SKU='P0001' AND SoldQuantity=3 AND SalesAmount=10.50)
        THROW 51701,N'已完成销售统计错误',1;
    IF NOT EXISTS (SELECT 1 FROM dbo.v_supplier_purchases
                   WHERE SupplierCode='S001' AND ReceivedOrderCount=1 AND PurchaseAmount=84.00)
        THROW 51702,N'采购统计错误',1;
    -- 草稿采购的非零金额不能污染供应商统计。
    DECLARE @supplier bigint=(SELECT SupplierID FROM dbo.Supplier WHERE SupplierCode='S001');
    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID,TotalAmount)
    VALUES ('VP-'+LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),12),@supplier,@employee,999.00);
    IF NOT EXISTS (SELECT 1 FROM dbo.v_supplier_purchases
                   WHERE SupplierCode='S001' AND ReceivedOrderCount=1 AND PurchaseAmount=84.00)
        THROW 51703,N'草稿采购污染供应商统计',1;
    IF (SELECT COUNT(*) FROM dbo.v_current_inventory)<>6
       OR NOT EXISTS (SELECT 1 FROM dbo.v_current_inventory WHERE SKU='P0002' AND Quantity=6 AND StockStatus='LOW_STOCK')
       OR NOT EXISTS (SELECT 1 FROM dbo.v_current_inventory WHERE SKU='P0006' AND Quantity=0 AND StockStatus='OUT_OF_STOCK')
        THROW 51704,N'库存视图数量或预警错误',1;
    IF (SELECT COUNT(*) FROM dbo.v_sale_detail)<>5
       OR (SELECT SUM(LineAmount) FROM dbo.v_sale_detail)<>44.50
        THROW 51705,N'销售明细视图数量或原价金额错误',1;
    IF (SELECT COUNT(*) FROM dbo.v_daily_sales)<>3
       OR (SELECT SUM(OrderCount) FROM dbo.v_daily_sales)<>3
       OR (SELECT SUM(OriginalAmount) FROM dbo.v_daily_sales)<>44.50
       OR (SELECT SUM(DiscountAmount) FROM dbo.v_daily_sales)<>1.50
       OR (SELECT SUM(SalesAmount) FROM dbo.v_daily_sales)<>43.00
        THROW 51706,N'每日销售统计或草稿排除错误',1;
    IF (SELECT COUNT(*) FROM dbo.v_product_sales)<>6
       OR (SELECT SUM(SoldQuantity) FROM dbo.v_product_sales)<>15
       OR (SELECT SUM(SalesAmount) FROM dbo.v_product_sales)<>44.50
        THROW 51707,N'商品销售汇总错误',1;
    ROLLBACK;
    PRINT N'统计视图验证通过';
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;
GO
