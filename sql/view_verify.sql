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
    INSERT dbo.SaleOrder(SaleNo,EmployeeID)
    VALUES ('VIEW-'+LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),12),@employee);
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
    ROLLBACK;
    PRINT N'统计视图验证通过';
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;
GO
