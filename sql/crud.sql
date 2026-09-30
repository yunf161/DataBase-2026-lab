/* 第 3 周：可重复的增删改查。只操作本脚本创建、尚未产生订单的测试商品。 */
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
    DECLARE @tag varchar(12)=LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),12);
    DECLARE @categoryID bigint,@productID bigint;
    DECLARE @categoryCode varchar(20)='CR'+@tag,@sku varchar(30)='CP'+@tag;

    -- CREATE：商品插入后，触发器会同时建立数量为 0 的库存行。
    INSERT dbo.Category(CategoryCode,CategoryName) VALUES (@categoryCode,N'课堂测试分类');
    SET @categoryID=SCOPE_IDENTITY();
    INSERT dbo.Product(SKU,ProductName,CategoryID,Unit,SalePrice)
    VALUES (@sku,N'课堂测试商品',@categoryID,N'件',4.00);
    SET @productID=SCOPE_IDENTITY();

    -- READ：连接商品、分类和库存，现场能看到新记录。
    SELECT p.SKU,p.ProductName,c.CategoryName,p.SalePrice,i.Quantity
    FROM dbo.Product AS p
    JOIN dbo.Category AS c ON c.CategoryID=p.CategoryID
    JOIN dbo.Inventory AS i ON i.ProductID=p.ProductID
    WHERE p.ProductID=@productID;
    IF (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@productID)<>0
        THROW 51600,N'新增商品未生成零库存',1;

    -- UPDATE：修改现价；商品触发器会自动维护 UpdatedAt。
    UPDATE dbo.Product SET SalePrice=4.50
    WHERE ProductID=@productID;
    SELECT SKU,SalePrice FROM dbo.Product WHERE ProductID=@productID;
    IF (SELECT SalePrice FROM dbo.Product WHERE ProductID=@productID)<>4.50
        THROW 51601,N'商品改价失败',1;

    -- DELETE：仅删除没有订单引用的测试商品，先删库存再删商品。
    DELETE FROM dbo.Inventory WHERE ProductID=@productID;
    DELETE FROM dbo.Product WHERE ProductID=@productID;
    DELETE FROM dbo.Category WHERE CategoryID=@categoryID;
    IF EXISTS (SELECT 1 FROM dbo.Product WHERE SKU=@sku)
        OR EXISTS (SELECT 1 FROM dbo.Category WHERE CategoryCode=@categoryCode)
        THROW 51602,N'测试记录未清理',1;
    COMMIT;
    PRINT N'CRUD 演示通过，测试记录已删除';
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;
GO
