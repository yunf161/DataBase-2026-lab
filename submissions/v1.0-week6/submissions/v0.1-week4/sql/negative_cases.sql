/* 统一反例测试：在当前小卖部数据库运行，不清空已有数据。
   请先 USE 你的数据库；完整执行，不要只选中某一条非法语句。
   预期错误被捕获后继续；不符合预期的组记为失败，最后统一汇总。
   使用随机编号建立测试资料和订单，结束保留测试记录用于观察。
   请先截图正常样例和统计，再运行本脚本。事务反例需维护账号权限。 */
IF OBJECT_ID(N'tempdb..#NegativeResults') IS NOT NULL DROP TABLE #NegativeResults;
IF @@TRANCOUNT<>0 THROW 52901,N'请在没有未提交事务的新查询窗口执行反例测试',1;
IF OBJECT_ID(N'dbo.Product',N'U') IS NULL OR OBJECT_ID(N'dbo.CompleteSale',N'P') IS NULL
    THROW 52902,N'当前数据库尚未部署小卖部结构和业务过程',1;
CREATE TABLE #NegativeResults (
    Section nvarchar(40),TestCase nvarchar(100),Result nvarchar(20),Details nvarchar(1000));
GO
IF OBJECT_ID(N'tempdb..#NegativeResults') IS NULL
    THROW 52903,N'请完整执行反例脚本，前置检查未通过',1;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT OFF;
SET NOCOUNT ON;

PRINT N'开始反例组：基础完整性';
BEGIN TRY
DECLARE @tag varchar(12)=LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),12);
DECLARE @category bigint,@sku varchar(30)='NEG'+@tag;
INSERT dbo.Category(CategoryCode,CategoryName) VALUES('NEG'+@tag,N'反例专用分类');
SET @category=SCOPE_IDENTITY();
INSERT dbo.Product(SKU,ProductName,CategoryID,SalePrice) VALUES(@sku,N'反例基准商品',@category,1);
BEGIN TRY
    INSERT dbo.Product(SKU,ProductName,CategoryID,SalePrice)
    VALUES('NP'+@tag,N'负价反例',@category,-1);
    INSERT #NegativeResults VALUES(N'基础完整性',N'负售价',N'失败',N'非法插入竟然成功');
END TRY
BEGIN CATCH
    INSERT #NegativeResults VALUES(N'基础完整性',N'负售价',
        CASE WHEN ERROR_NUMBER()=547 THEN N'已拒绝' ELSE N'失败' END,ERROR_MESSAGE());
END CATCH;
BEGIN TRY
    INSERT dbo.Product(SKU,ProductName,CategoryID,SalePrice)
    VALUES('NF'+@tag,N'无效分类反例',-1,1);
    INSERT #NegativeResults VALUES(N'基础完整性',N'无效分类外键',N'失败',N'非法插入竟然成功');
END TRY
BEGIN CATCH
    INSERT #NegativeResults VALUES(N'基础完整性',N'无效分类外键',
        CASE WHEN ERROR_NUMBER()=547 THEN N'已拒绝' ELSE N'失败' END,ERROR_MESSAGE());
END CATCH;
BEGIN TRY
    INSERT dbo.Product(SKU,ProductName,CategoryID,SalePrice)
    VALUES(@sku,N'重复 SKU 反例',@category,1);
    INSERT #NegativeResults VALUES(N'基础完整性',N'重复 SKU',N'失败',N'非法插入竟然成功');
END TRY
BEGIN CATCH
    INSERT #NegativeResults VALUES(N'基础完整性',N'重复 SKU',
        CASE WHEN ERROR_NUMBER() IN (2601,2627) THEN N'已拒绝' ELSE N'失败' END,ERROR_MESSAGE());
END CATCH;
PRINT N'负售价、无效外键、重复 SKU 已逐项执行，预期错误不终止后续测试';
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    IF USER_NAME() IN (N'AuditPurchaser',N'AuditCashier',N'AuditAdmin',
        N'CourseDemoViewer',N'CourseDemoCashier',N'CourseDemoPurchaser') REVERT;
    INSERT #NegativeResults VALUES(N'基础完整性',N'组内校验异常',N'失败',ERROR_MESSAGE());
    PRINT N'该组出现非预期错误，已记录，继续后续组';
END CATCH;
GO
IF OBJECT_ID(N'tempdb..#NegativeResults') IS NULL
    THROW 52903,N'请完整执行反例脚本，前置检查未通过',1;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT OFF;
SET NOCOUNT ON;

PRINT N'开始反例组：基础角色';
BEGIN TRY
SET NOCOUNT ON;
IF DATABASE_PRINCIPAL_ID(N'CourseDemoViewer') IS NOT NULL
    OR DATABASE_PRINCIPAL_ID(N'CourseDemoCashier') IS NOT NULL
    OR DATABASE_PRINCIPAL_ID(N'CourseDemoPurchaser') IS NOT NULL
    THROW 51910,N'演示用户已存在，请先检查旧演示是否完整结束',1;

BEGIN TRY
    CREATE USER CourseDemoViewer WITHOUT LOGIN;
    CREATE USER CourseDemoCashier WITHOUT LOGIN;
    CREATE USER CourseDemoPurchaser WITHOUT LOGIN;
    ALTER ROLE CampusViewer ADD MEMBER CourseDemoViewer;
    ALTER ROLE CampusCashier ADD MEMBER CourseDemoCashier;
    ALTER ROLE CampusPurchaser ADD MEMBER CourseDemoPurchaser;

    EXECUTE AS USER=N'CourseDemoViewer';
    SELECT TOP (3) SKU,ProductName,Quantity FROM dbo.v_current_inventory ORDER BY SKU;
    BEGIN TRY
        SELECT TOP (1) ProductID FROM dbo.Product;
        THROW 51900,N'只读视图用户越权读取了商品表',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>229 THROW;
        PRINT N'只读视图用户直接查商品表被拒绝';
    END CATCH;
    REVERT;

    EXECUTE AS USER=N'CourseDemoCashier';
    IF HAS_PERMS_BY_NAME(N'dbo.CompleteSale',N'OBJECT',N'EXECUTE')<>1
        THROW 51901,N'收银员缺少销售结算权限',1;
    BEGIN TRY
        UPDATE dbo.Inventory SET Quantity=Quantity WHERE ProductID=-1;
        THROW 51902,N'收银员越权修改库存',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>229 THROW;
        PRINT N'收银员直接修改库存被拒绝';
    END CATCH;
    REVERT;

    EXECUTE AS USER=N'CourseDemoPurchaser';
    IF HAS_PERMS_BY_NAME(N'dbo.ConfirmPurchase',N'OBJECT',N'EXECUTE')<>1
        THROW 51903,N'采购员缺少采购确认权限',1;
    BEGIN TRY
        UPDATE dbo.Inventory SET Quantity=Quantity WHERE ProductID=-1;
        THROW 51904,N'采购员越权修改库存',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>229 THROW;
        PRINT N'采购员直接修改库存被拒绝';
    END CATCH;
    REVERT;

    ALTER ROLE CampusViewer DROP MEMBER CourseDemoViewer;
    ALTER ROLE CampusCashier DROP MEMBER CourseDemoCashier;
    ALTER ROLE CampusPurchaser DROP MEMBER CourseDemoPurchaser;
    DROP USER CourseDemoViewer;
    DROP USER CourseDemoCashier;
    DROP USER CourseDemoPurchaser;
    PRINT N'角色权限演示通过，临时用户已删除';
END TRY
BEGIN CATCH
    IF USER_NAME() IN (N'CourseDemoViewer',N'CourseDemoCashier',N'CourseDemoPurchaser')
        REVERT;
    IF DATABASE_PRINCIPAL_ID(N'CourseDemoViewer') IS NOT NULL
    BEGIN
        ALTER ROLE CampusViewer DROP MEMBER CourseDemoViewer;
        DROP USER CourseDemoViewer;
    END;
    IF DATABASE_PRINCIPAL_ID(N'CourseDemoCashier') IS NOT NULL
    BEGIN
        ALTER ROLE CampusCashier DROP MEMBER CourseDemoCashier;
        DROP USER CourseDemoCashier;
    END;
    IF DATABASE_PRINCIPAL_ID(N'CourseDemoPurchaser') IS NOT NULL
    BEGIN
        ALTER ROLE CampusPurchaser DROP MEMBER CourseDemoPurchaser;
        DROP USER CourseDemoPurchaser;
    END;
    THROW;
END CATCH;
INSERT #NegativeResults VALUES
(N'基础角色',N'只读用户直接查商品',N'已拒绝',N'仅能读取授权视图'),
(N'基础角色',N'采购员和收银员直接改库存',N'已拒绝',N'表更新权限被拒绝');
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    IF USER_NAME() IN (N'AuditPurchaser',N'AuditCashier',N'AuditAdmin',
        N'CourseDemoViewer',N'CourseDemoCashier',N'CourseDemoPurchaser') REVERT;
    INSERT #NegativeResults VALUES(N'基础角色',N'组内校验异常',N'失败',ERROR_MESSAGE());
    PRINT N'该组出现非预期错误，已记录，继续后续组';
END CATCH;
GO
IF OBJECT_ID(N'tempdb..#NegativeResults') IS NULL
    THROW 52903,N'请完整执行反例脚本，前置检查未通过',1;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT OFF;
SET NOCOUNT ON;

PRINT N'开始反例组：业务保护';
BEGIN TRY
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
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

    -- 回归测试：不能绕过业务过程，直接创建终态订单。
    BEGIN TRY
        INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID,Status)
        VALUES ('PI'+@tag,@supplier,@employee,'RECEIVED');
        THROW 51121, N'直接插入已收货采购单未拒绝', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51221 THROW;
    END CATCH;
    IF EXISTS (SELECT 1 FROM dbo.PurchaseOrder WHERE PurchaseNo='PI'+@tag)
        THROW 51122, N'被拒绝的采购单仍然存在', 1;
    PRINT N'直接 INSERT RECEIVED 被拒绝，采购单未落库';

    BEGIN TRY
        INSERT dbo.SaleOrder(SaleNo,EmployeeID,Status,PaymentMethod)
        VALUES ('SI'+@tag,@employee,'COMPLETED','CASH');
        THROW 51123, N'直接插入已完成销售单未拒绝', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51321 THROW;
    END CATCH;
    IF EXISTS (SELECT 1 FROM dbo.SaleOrder WHERE SaleNo='SI'+@tag)
        THROW 51124, N'被拒绝的销售单仍然存在', 1;
    PRINT N'直接 INSERT COMPLETED 被拒绝，销售单未落库';

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
        UPDATE dbo.PurchaseOrder SET TotalAmount=99 WHERE PurchaseID=@purchase;
        THROW 51129, N'已收货采购金额仍可改写', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51222 THROW;
    END CATCH;
    IF (SELECT TotalAmount FROM dbo.PurchaseOrder WHERE PurchaseID=@purchase)<>22.00
        THROW 51130, N'拒绝改写后采购金额发生变化', 1;
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
    BEGIN TRY
        UPDATE dbo.SaleOrder SET DiscountAmount=0 WHERE SaleID=@sale;
        THROW 51131, N'已完成销售优惠仍可改写', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51322 THROW;
    END CATCH;
    IF (SELECT PayableAmount FROM dbo.SaleOrder WHERE SaleID=@sale)<>9.50
        THROW 51132, N'拒绝改写后销售应付金额发生变化', 1;
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

    -- 回归测试：第二件商品缺少库存行时，不能沿用第一件商品的 @before。
    -- 此破坏性场景仅发生在本脚本开头限制的一次性验证数据库。
    DELETE dbo.Inventory WHERE ProductID=@product2;
    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID)
    VALUES ('PM'+@tag,@supplier,@employee);
    SET @purchase=SCOPE_IDENTITY();
    INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost)
    VALUES (@purchase,@product,1,2.20),(@purchase,@product2,1,1.00);
    BEGIN TRY
        EXEC dbo.ConfirmPurchase @purchase;
        THROW 51125, N'采购缺少第二件商品库存行未拒绝', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51202 THROW;
    END CATCH;
    IF (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@product)<>7
        OR EXISTS (SELECT 1 FROM dbo.InventoryLog WHERE BusinessNo='PM'+@tag)
        OR NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrder WHERE PurchaseID=@purchase AND Status='DRAFT')
        THROW 51126, N'缺少库存行的采购未完整回滚', 1;

    INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod)
    VALUES ('SM'+@tag,@employee,'CASH');
    SET @sale=SCOPE_IDENTITY();
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
    VALUES (@sale,@product,1,3.50),(@sale,@product2,1,5.00);
    BEGIN TRY
        EXEC dbo.CompleteSale @sale;
        THROW 51127, N'销售缺少第二件商品库存行未拒绝', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51305 THROW;
    END CATCH;
    IF (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@product)<>7
        OR EXISTS (SELECT 1 FROM dbo.InventoryLog WHERE BusinessNo='SM'+@tag)
        OR NOT EXISTS (SELECT 1 FROM dbo.SaleOrder WHERE SaleID=@sale AND Status='DRAFT')
        THROW 51128, N'缺少库存行的销售未完整回滚', 1;
    INSERT dbo.Inventory(ProductID,Quantity) VALUES (@product2,0);
    PRINT N'第二件商品缺少库存行时，采购和销售均被拒绝且完整回滚';
    -- 停用对象不能完成新业务；拒绝后不改变订单、库存和流水。
    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID)
    VALUES ('PD'+@tag,@supplier,@employee);
    SET @purchase=SCOPE_IDENTITY();
    INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost)
    VALUES (@purchase,@product,1,2.20);
    UPDATE dbo.Supplier SET Status=0 WHERE SupplierID=@supplier;
    BEGIN TRY
        EXEC dbo.ConfirmPurchase @purchase;
        THROW 51133, N'停用供应商仍可确认采购', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51204 THROW;
    END CATCH;
    UPDATE dbo.Supplier SET Status=1 WHERE SupplierID=@supplier;
    UPDATE dbo.Employee SET Status=0 WHERE EmployeeID=@employee;
    BEGIN TRY
        EXEC dbo.ConfirmPurchase @purchase;
        THROW 51134, N'停用员工仍可确认采购', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51203 THROW;
    END CATCH;
    INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod)
    VALUES ('SD'+@tag,@employee,'CASH');
    SET @sale=SCOPE_IDENTITY();
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
    VALUES (@sale,@product,1,3.50);
    BEGIN TRY
        EXEC dbo.CompleteSale @sale;
        THROW 51135, N'停用员工仍可完成销售', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51306 THROW;
    END CATCH;
    UPDATE dbo.Employee SET Status=1 WHERE EmployeeID=@employee;
    IF (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@product)<>7
       OR EXISTS (SELECT 1 FROM dbo.InventoryLog WHERE BusinessNo IN ('PD'+@tag,'SD'+@tag))
       OR NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrder WHERE PurchaseID=@purchase AND Status='DRAFT')
       OR NOT EXISTS (SELECT 1 FROM dbo.SaleOrder WHERE SaleID=@sale AND Status='DRAFT')
        THROW 51136, N'停用对象拒绝后业务数据发生变化', 1;
    PRINT N'停用供应商与员工业务被拒绝，订单、库存、流水保持不变';

    -- 草稿的总额尚未结算，保留优惠也应能取消，且不产生库存业务。
    INSERT dbo.SaleOrder(SaleNo,EmployeeID,DiscountAmount)
    VALUES ('SC'+@tag,@employee,1.00);
    SET @sale=SCOPE_IDENTITY();
    UPDATE dbo.SaleOrder SET Status='CANCELLED' WHERE SaleID=@sale;
    IF NOT EXISTS (SELECT 1 FROM dbo.SaleOrder WHERE SaleID=@sale
                   AND Status='CANCELLED' AND TotalAmount=0 AND DiscountAmount=1)
       OR (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@product)<>7
       OR EXISTS (SELECT 1 FROM dbo.InventoryLog WHERE BusinessNo='SC'+@tag)
        THROW 51137, N'带优惠草稿取消结果错误', 1;
    BEGIN TRY
        EXEC dbo.CompleteSale @sale;
        THROW 51138, N'取消单仍可结算', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51300 THROW;
    END CATCH;
    PRINT N'带优惠草稿取消成功，取消单不能结算且无库存流水';
    PRINT N'采购、销售及整单回滚验证通过';
    INSERT #NegativeResults(Section,TestCase,Result,Details)
    SELECT N'业务保护',TestCase,Result,Expected FROM (VALUES
        (N'分类循环',N'通过',N'父子分类不能形成循环'),
        (N'终态直接插入',N'通过',N'RECEIVED / COMPLETED 均被拒绝'),
        (N'正常采购和销售',N'通过',N'采购后库存 10，销售后库存 7'),
        (N'终态订单保护',N'通过',N'金额、优惠和明细改写被拒绝'),
        (N'重复确认与状态回退',N'通过',N'不能重复入库、结算或退回草稿'),
        (N'直接改库存',N'通过',N'无业务许可修改数量被拒绝'),
        (N'历史成交价',N'通过',N'商品改价不改变历史成交价 3.50'),
        (N'更新时间',N'通过',N'普通商品修改后 UpdatedAt 刷新'),
        (N'超卖与缺失库存',N'通过',N'整单失败，库存和流水回滚'),
        (N'停用员工和供应商',N'通过',N'业务被拒绝，订单仍为草稿'),
        (N'带优惠草稿取消',N'通过',N'取消成功且不能再次结算')
    ) AS r(TestCase,Result,Expected);
END TRY
BEGIN CATCH
    THROW;
END CATCH;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    IF USER_NAME() IN (N'AuditPurchaser',N'AuditCashier',N'AuditAdmin',
        N'CourseDemoViewer',N'CourseDemoCashier',N'CourseDemoPurchaser') REVERT;
    INSERT #NegativeResults VALUES(N'业务保护',N'组内校验异常',N'失败',ERROR_MESSAGE());
    PRINT N'该组出现非预期错误，已记录，继续后续组';
END CATCH;
GO
IF OBJECT_ID(N'tempdb..#NegativeResults') IS NULL
    THROW 52903,N'请完整执行反例脚本，前置检查未通过',1;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT OFF;
SET NOCOUNT ON;

PRINT N'开始反例组：角色全流程';
BEGIN TRY
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT OFF;
SET NOCOUNT ON;

IF DATABASE_PRINCIPAL_ID(N'AuditPurchaser') IS NOT NULL
   OR DATABASE_PRINCIPAL_ID(N'AuditCashier') IS NOT NULL
   OR DATABASE_PRINCIPAL_ID(N'AuditAdmin') IS NOT NULL
    THROW 52101,N'权限测试用户已存在',1;
BEGIN TRY
    CREATE USER AuditPurchaser WITHOUT LOGIN;
    CREATE USER AuditCashier WITHOUT LOGIN;
    CREATE USER AuditAdmin WITHOUT LOGIN;
    ALTER ROLE CampusPurchaser ADD MEMBER AuditPurchaser;
    ALTER ROLE CampusCashier ADD MEMBER AuditCashier;
    ALTER ROLE CampusAdmin ADD MEMBER AuditAdmin;

    DECLARE @tag varchar(12)=LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),12);
    DECLARE @category bigint=(SELECT TOP(1) CategoryID FROM dbo.Category ORDER BY CategoryID);
    DECLARE @supplier bigint=(SELECT TOP(1) SupplierID FROM dbo.Supplier ORDER BY SupplierID);
    DECLARE @employee bigint=(SELECT TOP(1) EmployeeID FROM dbo.Employee ORDER BY EmployeeID);
    DECLARE @product bigint,@purchase bigint,@sale bigint,@cancelPurchase bigint,@cancelSale bigint;
    DECLARE @pq TABLE (PurchaseID bigint,PurchaseNo varchar(30),SupplierID bigint,
                      EmployeeID bigint,Status varchar(20),TotalAmount decimal(12,2),DraftAmount decimal(38,2));
    DECLARE @sq TABLE (SaleID bigint,SaleNo varchar(30),EmployeeID bigint,Status varchar(20),
                      PaymentMethod varchar(20),DiscountAmount decimal(12,2),
                      TotalAmount decimal(12,2),PayableAmount decimal(12,2),DraftAmount decimal(38,2));
    INSERT dbo.Product(SKU,ProductName,CategoryID,SalePrice)
    VALUES ('AU'+@tag,N'权限回归商品',@category,4.00);
    SET @product=SCOPE_IDENTITY();

    EXECUTE AS USER=N'AuditPurchaser';
    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID)
    VALUES ('AP'+@tag,@supplier,@employee);
    SET @purchase=SCOPE_IDENTITY();
    INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost)
    VALUES (@purchase,@product,5,2.00);
    INSERT @pq EXEC dbo.QueryPurchaseOrders @purchase;
    IF NOT EXISTS (SELECT 1 FROM @pq WHERE PurchaseID=@purchase AND Status='DRAFT' AND DraftAmount=10)
        THROW 52109,N'采购角色不能查询草稿及明细预估金额',1;
    EXEC dbo.ConfirmPurchase @purchase;
    DELETE @pq;
    INSERT @pq EXEC dbo.QueryPurchaseOrders @purchase;
    IF NOT EXISTS (SELECT 1 FROM @pq WHERE Status='RECEIVED' AND TotalAmount=10 AND DraftAmount IS NULL)
        THROW 52110,N'采购角色不能查询已收货结果',1;
    BEGIN TRY
        EXEC dbo.CancelPurchase @purchase;
        THROW 52111,N'已收货采购单仍可取消',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51410 THROW;
    END CATCH;
    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID)
    VALUES ('AC'+@tag,@supplier,@employee);
    SET @cancelPurchase=SCOPE_IDENTITY();
    INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost)
    VALUES (@cancelPurchase,@product,1,2.00);
    EXEC dbo.CancelPurchase @cancelPurchase;
    DELETE @pq;
    INSERT @pq EXEC dbo.QueryPurchaseOrders @cancelPurchase;
    IF NOT EXISTS (SELECT 1 FROM @pq WHERE Status='CANCELLED')
        THROW 52112,N'采购角色取消结果不可查询',1;
    BEGIN TRY
        EXEC dbo.ConfirmPurchase @cancelPurchase;
        THROW 52113,N'取消采购单仍可确认',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51200 THROW;
    END CATCH;
    -- 攻击者可设置自己的 SESSION_CONTEXT，但仍没有直接更新库存的表权限。
    EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite',@value=1;
    BEGIN TRY
        UPDATE dbo.Inventory SET Quantity=999 WHERE ProductID=@product;
        THROW 52102,N'采购员伪造会话标记后能够直接改库存',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (229,230) THROW;
    END CATCH;
    EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite',@value=NULL;
    REVERT;
    IF NOT EXISTS (SELECT 1 FROM dbo.Inventory WHERE ProductID=@product AND Quantity=5)
       OR NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrder WHERE PurchaseID=@purchase AND Status='RECEIVED' AND TotalAmount=10)
        THROW 52103,N'真实采购角色未完成正确入库',1;
    PRINT N'采购角色实际确认成功；伪造会话标记仍不能直接修改库存';

    EXECUTE AS USER=N'AuditCashier';
    INSERT dbo.SaleOrder(SaleNo,EmployeeID)
    VALUES ('AS'+@tag,@employee);
    SET @sale=SCOPE_IDENTITY();
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
    VALUES (@sale,@product,2,4.00);
    INSERT @sq EXEC dbo.QuerySaleOrders @sale;
    IF NOT EXISTS (SELECT 1 FROM @sq WHERE Status='DRAFT' AND PaymentMethod IS NULL
                   AND DraftAmount=8 AND PayableAmount IS NULL)
        THROW 52114,N'收银角色草稿查询错误',1;
    BEGIN TRY
        EXEC dbo.CompleteSale @sale;
        THROW 52125,N'未填写支付方式仍可结算',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51301 THROW;
    END CATCH;
    BEGIN TRY
        EXEC dbo.UpdateSaleDraft @sale,'INVALID',0;
        THROW 52126,N'非法支付方式未拒绝',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51402 THROW;
    END CATCH;
    BEGIN TRY
        EXEC dbo.UpdateSaleDraft @sale,'CASH',-1;
        THROW 52127,N'负优惠未拒绝',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51401 THROW;
    END CATCH;
    EXEC dbo.UpdateSaleDraft @sale,'WECHAT',1.00,N'权限测试补填支付及优惠';
    DELETE @sq;
    INSERT @sq EXEC dbo.QuerySaleOrders @sale;
    IF NOT EXISTS (SELECT 1 FROM @sq WHERE PaymentMethod='WECHAT' AND DiscountAmount=1)
        THROW 52115,N'收银角色不能修改草稿支付方式与优惠',1;
    BEGIN TRY
        UPDATE dbo.SaleOrder SET DiscountAmount=0 WHERE SaleID=@sale;
        THROW 52116,N'收银角色获得了直接修改订单头权限',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (229,230) THROW;
    END CATCH;
    EXEC dbo.CompleteSale @sale;
    DELETE @sq;
    INSERT @sq EXEC dbo.QuerySaleOrders @sale;
    IF NOT EXISTS (SELECT 1 FROM @sq WHERE Status='COMPLETED' AND TotalAmount=8
                   AND PayableAmount=7 AND DraftAmount IS NULL)
        THROW 52117,N'收银角色不能查询结算结果',1;
    BEGIN TRY
        EXEC dbo.UpdateSaleDraft @sale,'CASH',0;
        THROW 52118,N'已完成销售单仍可通过草稿过程修改',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51400 THROW;
    END CATCH;
    BEGIN TRY
        EXEC dbo.CancelSale @sale;
        THROW 52119,N'已完成销售单仍可取消',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51411 THROW;
    END CATCH;
    INSERT dbo.SaleOrder(SaleNo,EmployeeID,DiscountAmount)
    VALUES ('AX'+@tag,@employee,1.00);
    SET @cancelSale=SCOPE_IDENTITY();
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
    VALUES (@cancelSale,@product,1,4.00);
    EXEC dbo.CancelSale @cancelSale;
    DELETE @sq;
    INSERT @sq EXEC dbo.QuerySaleOrders @cancelSale;
    IF NOT EXISTS (SELECT 1 FROM @sq WHERE Status='CANCELLED' AND PayableAmount IS NULL)
        THROW 52120,N'收银角色取消结果错误',1;
    BEGIN TRY
        EXEC dbo.CompleteSale @cancelSale;
        THROW 52121,N'取消销售单仍可结算',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51300 THROW;
    END CATCH;
    BEGIN TRY
        EXEC dbo.UpdateSaleDraft @cancelSale,'CASH',0;
        THROW 52122,N'取消销售单仍可修改',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51400 THROW;
    END CATCH;
    BEGIN TRY
        EXEC dbo.CancelPurchase @cancelPurchase;
        THROW 52123,N'收银角色能调用采购取消过程',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (229,230) THROW;
    END CATCH;
    BEGIN TRY
        EXEC dbo.ConfirmPurchase @purchase;
        THROW 52104,N'收银员能够执行采购过程',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (229,230) THROW;
    END CATCH;
    REVERT;
    IF NOT EXISTS (SELECT 1 FROM dbo.Inventory WHERE ProductID=@product AND Quantity=3)
       OR NOT EXISTS (SELECT 1 FROM dbo.SaleOrder WHERE SaleID=@sale AND Status='COMPLETED' AND PayableAmount=7)
        THROW 52105,N'真实收银角色未完成正确销售',1;
    IF (SELECT COUNT(*) FROM dbo.InventoryLog WHERE ProductID=@product)<>2
        THROW 52106,N'真实角色业务的库存流水错误',1;
    PRINT N'收银角色实际结算成功；跨角色采购过程被拒绝';
    IF EXISTS (SELECT 1 FROM dbo.InventoryLog WHERE BusinessNo IN ('AC'+@tag,'AX'+@tag))
        THROW 52124,N'取消订单产生了库存流水',1;
    PRINT N'真实角色创建、查询、修改草稿、完成或取消全流程通过；取消无库存变动';

    EXECUTE AS USER=N'AuditAdmin';
    UPDATE dbo.Inventory SET MinQuantity=2 WHERE ProductID=@product;
    BEGIN TRY
        UPDATE dbo.Inventory SET Quantity=999 WHERE ProductID=@product;
        THROW 52107,N'业务管理员拥有库存数量修改权限',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (229,230) THROW;
    END CATCH;
    REVERT;
    IF NOT EXISTS (SELECT 1 FROM dbo.Inventory WHERE ProductID=@product AND Quantity=3 AND MinQuantity=2)
        THROW 52108,N'管理员库存阈值授权结果错误',1;
    PRINT N'业务管理员可以修改最低库存；库存数量修改被拒绝';

    DROP USER AuditPurchaser;
    DROP USER AuditCashier;
    DROP USER AuditAdmin;
    PRINT N'真实角色业务和权限回归验证通过';
    INSERT #NegativeResults(Section,TestCase,Result,Details)
    SELECT N'角色全流程',TestCase,Result,Expected FROM (VALUES
        (N'采购创建与查询',N'通过',N'草稿预估 10，确认后订单金额 10'),
        (N'收银草稿修改',N'通过',N'补填 WECHAT 和优惠 1 后可以结算'),
        (N'销售完成与查询',N'通过',N'原价 8，应付 7，最终库存 3'),
        (N'两类草稿取消',N'通过',N'取消无库存流水，不能再完成'),
        (N'终态修改和取消',N'通过',N'已完成、已取消订单不可通过草稿入口修改'),
        (N'输入校验',N'通过',N'无支付、非法支付和负优惠被拒绝'),
        (N'库存权限',N'通过',N'伪造会话标记仍不能直接改库存'),
        (N'跨角色调用',N'通过',N'收银角色不能确认或取消采购'),
        (N'管理员权限',N'通过',N'可改最低库存，不可改库存数量')
    ) AS r(TestCase,Result,Expected);
END TRY
BEGIN CATCH
    IF USER_NAME() IN (N'AuditPurchaser',N'AuditCashier',N'AuditAdmin') REVERT;
    EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite',@value=NULL;
    IF DATABASE_PRINCIPAL_ID(N'AuditPurchaser') IS NOT NULL DROP USER AuditPurchaser;
    IF DATABASE_PRINCIPAL_ID(N'AuditCashier') IS NOT NULL DROP USER AuditCashier;
    IF DATABASE_PRINCIPAL_ID(N'AuditAdmin') IS NOT NULL DROP USER AuditAdmin;
    THROW;
END CATCH;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    IF USER_NAME() IN (N'AuditPurchaser',N'AuditCashier',N'AuditAdmin',
        N'CourseDemoViewer',N'CourseDemoCashier',N'CourseDemoPurchaser') REVERT;
    INSERT #NegativeResults VALUES(N'角色全流程',N'组内校验异常',N'失败',ERROR_MESSAGE());
    PRINT N'该组出现非预期错误，已记录，继续后续组';
END CATCH;
GO
IF OBJECT_ID(N'tempdb..#NegativeResults') IS NULL
    THROW 52903,N'请完整执行反例脚本，前置检查未通过',1;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT OFF;
SET NOCOUNT ON;

PRINT N'开始反例组：事务边界';
BEGIN TRY
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT OFF;
SET NOCOUNT ON;
CREATE TABLE #EarlierWork(Value int);
BEGIN TRY
    DECLARE @case int=1,@expected int;
    WHILE @case<=5
    BEGIN
        BEGIN TRAN;
        INSERT #EarlierWork VALUES(@case);
        SET @expected=CASE @case WHEN 1 THEN 51200 WHEN 2 THEN 51300
            WHEN 3 THEN 51400 WHEN 4 THEN 51410 WHEN 5 THEN 51411 END;
        BEGIN TRY
            IF @case=1 EXEC dbo.ConfirmPurchase -1;
            IF @case=2 EXEC dbo.CompleteSale -1;
            IF @case=3 EXEC dbo.UpdateSaleDraft -1,'CASH',0;
            IF @case=4 EXEC dbo.CancelPurchase -1;
            IF @case=5 EXEC dbo.CancelSale -1;
            THROW 52201,N'不存在的订单未拒绝',1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER()<>@expected THROW;
        END CATCH;
        IF @@TRANCOUNT<>1 OR XACT_STATE()<>1 OR NOT EXISTS (SELECT 1 FROM #EarlierWork WHERE Value=@case)
            THROW 52202,N'业务校验失败破坏外层事务或之前操作',1;
        ROLLBACK;
        SET @case+=1;
    END;
    PRINT N'5 个写入过程业务校验失败后，外层事务和之前操作保留';

    DECLARE @tag varchar(12)=LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),12);
    DECLARE @category bigint=(SELECT TOP(1) CategoryID FROM dbo.Category ORDER BY CategoryID);
    DECLARE @supplier bigint=(SELECT TOP(1) SupplierID FROM dbo.Supplier WHERE Status=1 ORDER BY SupplierID);
    DECLARE @employee bigint=(SELECT TOP(1) EmployeeID FROM dbo.Employee WHERE Status=1 ORDER BY EmployeeID);
    DECLARE @p1 bigint,@p2 bigint,@purchase bigint,@sale bigint;
    INSERT dbo.Product(SKU,ProductName,CategoryID,SalePrice) VALUES ('TX1'+@tag,N'事务商品一',@category,2);
    SET @p1=SCOPE_IDENTITY();
    INSERT dbo.Product(SKU,ProductName,CategoryID,SalePrice) VALUES ('TX2'+@tag,N'事务商品二',@category,2);
    SET @p2=SCOPE_IDENTITY();
    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID) VALUES ('TXP'+@tag,@supplier,@employee);
    SET @purchase=SCOPE_IDENTITY();
    INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost)
    VALUES (@purchase,@p1,2,1),(@purchase,@p2,1,1);
    DELETE dbo.Inventory WHERE ProductID=@p2;
    BEGIN TRAN;
    INSERT #EarlierWork VALUES(10);
    BEGIN TRY
        EXEC dbo.ConfirmPurchase @purchase;
        THROW 52203,N'缺失库存行未拒绝',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51202 THROW;
    END CATCH;
    IF @@TRANCOUNT<>1 OR XACT_STATE()<>1 OR NOT EXISTS (SELECT 1 FROM #EarlierWork WHERE Value=10)
       OR (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@p1)<>0
       OR EXISTS (SELECT 1 FROM dbo.InventoryLog WHERE BusinessNo='TXP'+@tag)
       OR NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrder WHERE PurchaseID=@purchase AND Status='DRAFT')
        THROW 52204,N'采购保存点未完整撤销当前过程操作',1;
    ROLLBACK;
    INSERT dbo.Inventory(ProductID,Quantity) VALUES(@p2,0);

    BEGIN TRAN;
    INSERT #EarlierWork VALUES(11);
    EXEC dbo.ConfirmPurchase @purchase;
    IF @@TRANCOUNT<>1 OR XACT_STATE()<>1
        THROW 52205,N'成功采购提前提交了调用者事务',1;
    ROLLBACK;
    IF (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@p1)<>0
       OR EXISTS (SELECT 1 FROM dbo.InventoryLog WHERE BusinessNo='TXP'+@tag)
       OR NOT EXISTS (SELECT 1 FROM dbo.PurchaseOrder WHERE PurchaseID=@purchase AND Status='DRAFT')
        THROW 52206,N'外层回滚不能撤销成功采购',1;
    EXEC dbo.ConfirmPurchase @purchase;

    INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod) VALUES ('TXS'+@tag,@employee,'CASH');
    SET @sale=SCOPE_IDENTITY();
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
    VALUES (@sale,@p1,1,2),(@sale,@p2,2,2);
    BEGIN TRAN;
    INSERT #EarlierWork VALUES(12);
    BEGIN TRY
        EXEC dbo.CompleteSale @sale;
        THROW 52207,N'库存不足未拒绝',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>51305 THROW;
    END CATCH;
    IF @@TRANCOUNT<>1 OR XACT_STATE()<>1 OR NOT EXISTS (SELECT 1 FROM #EarlierWork WHERE Value=12)
       OR (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@p1)<>2
       OR (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@p2)<>1
       OR EXISTS (SELECT 1 FROM dbo.InventoryLog WHERE BusinessNo='TXS'+@tag)
       OR NOT EXISTS (SELECT 1 FROM dbo.SaleOrder WHERE SaleID=@sale AND Status='DRAFT')
        THROW 52208,N'销售保存点未完整撤销当前过程操作',1;
    ROLLBACK;
    -- 引擎将事务标记为不可提交时，过程不得擅自清除调用者的事务。
    -- 此测试触发器仅在隔离库存在，结束后删除。
    EXEC(N'CREATE TRIGGER dbo.tr_TransactionAuditFatal ON dbo.SaleOrder AFTER UPDATE AS
          BEGIN SET NOCOUNT ON;
          IF EXISTS (SELECT 1 FROM inserted WHERE Remark=N''__TransactionAuditFatal__'')
              THROW 52209,N''隔离测试模拟不可提交事务'',1;
          END;');
    BEGIN TRAN;
    INSERT #EarlierWork VALUES(13);
    BEGIN TRY
        EXEC dbo.UpdateSaleDraft @sale,'CASH',0,N'__TransactionAuditFatal__';
        THROW 52210,N'不可提交事务测试未触发',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>52209 THROW;
    END CATCH;
    IF @@TRANCOUNT<>1 OR XACT_STATE()<>-1
        THROW 52211,N'过程没有将不可提交外层事务交回调用者',1;
    ROLLBACK;
    DROP TRIGGER dbo.tr_TransactionAuditFatal;
    PRINT N'不可提交外层事务保留并由调用者整体回滚，未错误回滚保存点';
    DROP TABLE #EarlierWork;
    PRINT N'采购与销售部分库存写入失败回到保存点；成功采购由外层事务决定提交';
    INSERT #NegativeResults(Section,TestCase,Result,Details)
    SELECT N'事务边界',TestCase,Result,Expected FROM (VALUES
        (N'5 个过程失败保留外层事务',N'通过',N'事务数 1，之前记录保留'),
        (N'采购部分写入回滚',N'通过',N'库存行缺失时第一商品与流水恢复'),
        (N'成功不提前提交',N'通过',N'外层回滚可撤销成功采购'),
        (N'销售部分写入回滚',N'通过',N'第二商品缺货时库存和流水恢复'),
        (N'不可提交事务边界',N'通过',N'状态 -1，由调用者整体回滚')
    ) AS r(TestCase,Result,Expected);
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    IF USER_NAME() IN (N'AuditPurchaser',N'AuditCashier',N'AuditAdmin',
        N'CourseDemoViewer',N'CourseDemoCashier',N'CourseDemoPurchaser') REVERT;
    INSERT #NegativeResults VALUES(N'事务边界',N'组内校验异常',N'失败',ERROR_MESSAGE());
    PRINT N'该组出现非预期错误，已记录，继续后续组';
END CATCH;
GO
SELECT Section AS 测试组,TestCase AS 测试项,Result AS 结果,Details AS 预期或错误说明
FROM #NegativeResults ORDER BY Section,TestCase;
SELECT COUNT(*) AS 总测试项,
       SUM(CASE WHEN Result=N'失败' THEN 1 ELSE 0 END) AS 失败项
FROM #NegativeResults;
IF EXISTS (SELECT 1 FROM #NegativeResults WHERE Result=N'失败')
    THROW 52999,N'反例测试已全部结束，但存在非预期失败，请查看汇总表',1;
PRINT N'统一反例测试完成：预期非法操作均已拒绝，后续测试正常继续';
GO

