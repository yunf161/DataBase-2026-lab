/* 第六周：迁移后语义等价、约束、权限与业务流程回归。 */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET NOCOUNT ON;
SET XACT_ABORT OFF;

IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W6[_]%'
    THROW 51619, N'第六周回归只能在名称为 CampusStoreDB_W6_* 的数据库副本运行', 1;
IF COL_LENGTH(N'dbo.InventoryLog',N'BusinessNo') IS NOT NULL
    THROW 51620, N'回归前检查失败：旧 BusinessNo 列仍存在', 1;
IF OBJECT_ID(N'dbo.v_inventory_log_detail',N'V') IS NULL
    THROW 51621, N'回归前检查失败：缺少 v_inventory_log_detail', 1;
IF OBJECT_ID(N'week6.BaselineMetric',N'U') IS NULL
   OR OBJECT_ID(N'week6.BaselinePurchaseOrder',N'U') IS NULL
   OR OBJECT_ID(N'week6.BaselineSaleOrder',N'U') IS NULL
    THROW 51622, N'回归前检查失败：缺少完整迁移前基线', 1;

CREATE TABLE #Result(
    TestName nvarchar(100) NOT NULL,
    Expected nvarchar(200) NOT NULL,
    Actual nvarchar(200) NOT NULL,
    Passed bit NOT NULL,
    Explanation nvarchar(300) NOT NULL
);

DECLARE @diff bigint;
-- 统计视图对无销售商品做外连接聚合，关闭无害的 NULL 消除提示；写入测试前恢复。
SET ANSI_WARNINGS OFF;

;WITH CurrentMetric AS (
    SELECT N'CategoryRows' AS MetricName,CONVERT(decimal(38,2),COUNT_BIG(*)) AS MetricValue FROM dbo.Category UNION ALL
    SELECT N'SupplierRows',COUNT_BIG(*) FROM dbo.Supplier UNION ALL
    SELECT N'EmployeeRows',COUNT_BIG(*) FROM dbo.Employee UNION ALL
    SELECT N'ProductRows',COUNT_BIG(*) FROM dbo.Product UNION ALL
    SELECT N'InventoryRows',COUNT_BIG(*) FROM dbo.Inventory UNION ALL
    SELECT N'PurchaseOrderRows',COUNT_BIG(*) FROM dbo.PurchaseOrder UNION ALL
    SELECT N'PurchaseItemRows',COUNT_BIG(*) FROM dbo.PurchaseItem UNION ALL
    SELECT N'SaleOrderRows',COUNT_BIG(*) FROM dbo.SaleOrder UNION ALL
    SELECT N'SaleItemRows',COUNT_BIG(*) FROM dbo.SaleItem UNION ALL
    SELECT N'InventoryLogRows',COUNT_BIG(*) FROM dbo.InventoryLog
)
SELECT @diff=COUNT_BIG(*)
FROM week6.BaselineMetric AS b
FULL JOIN CurrentMetric AS c ON c.MetricName=b.MetricName
WHERE COALESCE(b.MetricName,c.MetricName) LIKE N'%Rows'
  AND (b.MetricValue IS NULL OR c.MetricValue IS NULL OR b.MetricValue<>c.MetricValue);
INSERT #Result VALUES(N'10张业务表行数等价',N'差异 0',CONCAT(N'差异 ',@diff),IIF(@diff=0,1,0),N'包括无明细草稿单和未参与业务的基础资料');

SELECT @diff=COUNT_BIG(*) FROM (
    SELECT * FROM (
        SELECT PurchaseNo,Status,TotalAmount FROM week6.BaselinePurchaseOrder
        EXCEPT SELECT PurchaseNo,Status,TotalAmount FROM dbo.PurchaseOrder
    ) AS left_diff
    UNION ALL
    SELECT * FROM (
        SELECT PurchaseNo,Status,TotalAmount FROM dbo.PurchaseOrder
        EXCEPT SELECT PurchaseNo,Status,TotalAmount FROM week6.BaselinePurchaseOrder
    ) AS right_diff
) AS d;
INSERT #Result VALUES(N'逐采购单状态及金额等价',N'差异 0',CONCAT(N'差异 ',@diff),IIF(@diff=0,1,0),N'逐单号比较状态和总额，不能由订单间金额抵消');

SELECT @diff=COUNT_BIG(*) FROM (
    SELECT * FROM (
        SELECT PurchaseNo,SKU,Quantity,UnitCost,LineAmount FROM week6.BaselinePurchaseItem
        EXCEPT SELECT po.PurchaseNo,p.SKU,pi.Quantity,pi.UnitCost,pi.LineAmount
               FROM dbo.PurchaseItem pi JOIN dbo.PurchaseOrder po ON po.PurchaseID=pi.PurchaseID
               JOIN dbo.Product p ON p.ProductID=pi.ProductID
    ) AS left_diff
    UNION ALL
    SELECT * FROM (
        SELECT po.PurchaseNo,p.SKU,pi.Quantity,pi.UnitCost,pi.LineAmount
        FROM dbo.PurchaseItem pi JOIN dbo.PurchaseOrder po ON po.PurchaseID=pi.PurchaseID
        JOIN dbo.Product p ON p.ProductID=pi.ProductID
        EXCEPT SELECT PurchaseNo,SKU,Quantity,UnitCost,LineAmount FROM week6.BaselinePurchaseItem
    ) AS right_diff
) AS d;
INSERT #Result VALUES(N'采购明细语义等价',N'差异 0',CONCAT(N'差异 ',@diff),IIF(@diff=0,1,0),N'正确计算两个方向的 EXCEPT，避免单向丢失漏报');

SELECT @diff=COUNT_BIG(*) FROM (
    SELECT * FROM (
        SELECT SaleNo,Status,TotalAmount,DiscountAmount,PayableAmount FROM week6.BaselineSaleOrder
        EXCEPT SELECT SaleNo,Status,TotalAmount,DiscountAmount,PayableAmount FROM dbo.SaleOrder
    ) AS left_diff
    UNION ALL
    SELECT * FROM (
        SELECT SaleNo,Status,TotalAmount,DiscountAmount,PayableAmount FROM dbo.SaleOrder
        EXCEPT SELECT SaleNo,Status,TotalAmount,DiscountAmount,PayableAmount FROM week6.BaselineSaleOrder
    ) AS right_diff
) AS d;
INSERT #Result VALUES(N'逐销售单状态及金额等价',N'差异 0',CONCAT(N'差异 ',@diff),IIF(@diff=0,1,0),N'逐单号比较状态、总额、优惠和应付金额');

SELECT @diff=COUNT_BIG(*) FROM (
    SELECT * FROM (
        SELECT SaleNo,SKU,Quantity,UnitPrice,LineAmount FROM week6.BaselineSaleItem
        EXCEPT SELECT so.SaleNo,p.SKU,si.Quantity,si.UnitPrice,si.LineAmount
               FROM dbo.SaleItem si JOIN dbo.SaleOrder so ON so.SaleID=si.SaleID
               JOIN dbo.Product p ON p.ProductID=si.ProductID
    ) AS left_diff
    UNION ALL
    SELECT * FROM (
        SELECT so.SaleNo,p.SKU,si.Quantity,si.UnitPrice,si.LineAmount
        FROM dbo.SaleItem si JOIN dbo.SaleOrder so ON so.SaleID=si.SaleID
        JOIN dbo.Product p ON p.ProductID=si.ProductID
        EXCEPT SELECT SaleNo,SKU,Quantity,UnitPrice,LineAmount FROM week6.BaselineSaleItem
    ) AS right_diff
) AS d;
INSERT #Result VALUES(N'销售明细语义等价',N'差异 0',CONCAT(N'差异 ',@diff),IIF(@diff=0,1,0),N'数量、成交价和行金额均未变化');

SELECT @diff=COUNT_BIG(*) FROM (
    SELECT * FROM (
        SELECT SKU,SoldQuantity,SalesAmount FROM week6.BaselineProductSales
        EXCEPT SELECT SKU,SoldQuantity,SalesAmount FROM dbo.v_product_sales
    ) AS left_diff
    UNION ALL
    SELECT * FROM (
        SELECT SKU,SoldQuantity,SalesAmount FROM dbo.v_product_sales
        EXCEPT SELECT SKU,SoldQuantity,SalesAmount FROM week6.BaselineProductSales
    ) AS right_diff
) AS d;
INSERT #Result VALUES(N'商品销售统计等价',N'差异 0',CONCAT(N'差异 ',@diff),IIF(@diff=0,1,0),N'迁移不改变已完成销售的销量与销售额');

SELECT @diff=COUNT_BIG(*) FROM (
    SELECT * FROM (
        SELECT SKU,Quantity,MinQuantity FROM week6.BaselineInventory
        EXCEPT SELECT p.SKU,i.Quantity,i.MinQuantity FROM dbo.Inventory i JOIN dbo.Product p ON p.ProductID=i.ProductID
    ) AS left_diff
    UNION ALL
    SELECT * FROM (
        SELECT p.SKU,i.Quantity,i.MinQuantity FROM dbo.Inventory i JOIN dbo.Product p ON p.ProductID=i.ProductID
        EXCEPT SELECT SKU,Quantity,MinQuantity FROM week6.BaselineInventory
    ) AS right_diff
) AS d;
INSERT #Result VALUES(N'当前库存等价',N'差异 0',CONCAT(N'差异 ',@diff),IIF(@diff=0,1,0),N'迁移只改变流水来源表示，不改库存快照');

SELECT @diff=COUNT_BIG(*) FROM (
    SELECT * FROM (
        SELECT LogID,SKU,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,BusinessNo,EmployeeNo,Remark,CreatedAt
        FROM week6.BaselineInventoryLog
        EXCEPT
        SELECT LogID,SKU,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,BusinessNo,EmployeeNo,Remark,CreatedAt
        FROM dbo.v_inventory_log_detail
    ) AS left_diff
    UNION ALL
    SELECT * FROM (
        SELECT LogID,SKU,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,BusinessNo,EmployeeNo,Remark,CreatedAt
        FROM dbo.v_inventory_log_detail
        EXCEPT
        SELECT LogID,SKU,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,BusinessNo,EmployeeNo,Remark,CreatedAt
        FROM week6.BaselineInventoryLog
    ) AS right_diff
) AS d;
INSERT #Result VALUES(N'库存流水展示等价',N'差异 0',CONCAT(N'差异 ',@diff),IIF(@diff=0,1,0),N'业务单号、员工、备注和数量语义均保持');

DECLARE @expectedAmount decimal(38,2),@actualAmount decimal(38,2);
SELECT @expectedAmount=MetricValue FROM week6.BaselineMetric WHERE MetricName=N'ReceivedPurchaseAmount';
SELECT @actualAmount=COALESCE(SUM(TotalAmount),0) FROM dbo.PurchaseOrder WHERE Status='RECEIVED';
INSERT #Result VALUES(N'已收货采购总额等价',CONVERT(nvarchar(50),@expectedAmount),CONVERT(nvarchar(50),@actualAmount),IIF(@expectedAmount=@actualAmount,1,0),N'汇总结果与逐单比较同时验证');
SELECT @expectedAmount=MetricValue FROM week6.BaselineMetric WHERE MetricName=N'CompletedSaleAmount';
SELECT @actualAmount=COALESCE(SUM(TotalAmount),0) FROM dbo.SaleOrder WHERE Status='COMPLETED';
INSERT #Result VALUES(N'已完成销售总额等价',CONVERT(nvarchar(50),@expectedAmount),CONVERT(nvarchar(50),@actualAmount),IIF(@expectedAmount=@actualAmount,1,0),N'汇总结果与逐单比较同时验证');

SET ANSI_WARNINGS ON;
DECLARE @product bigint=(SELECT TOP(1) ProductID FROM dbo.Product WHERE Status=1 ORDER BY ProductID);
DECLARE @anyPurchase bigint=(SELECT TOP(1) PurchaseID FROM dbo.PurchaseOrder ORDER BY PurchaseID);

BEGIN TRY
    BEGIN TRAN;
    INSERT dbo.InventoryLog(ProductID,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,PurchaseID,SaleID)
    VALUES(@product,'PURCHASE_IN',1,0,1,-1,NULL);
    ROLLBACK;
    INSERT #Result VALUES(N'非法采购外键',N'被拒绝',N'意外成功',0,N'不存在的采购单不应被引用');
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    INSERT #Result VALUES(N'非法采购外键',N'被拒绝',IIF(ERROR_NUMBER()=547,N'被拒绝',ERROR_MESSAGE()),IIF(ERROR_NUMBER()=547,1,0),N'FK_InventoryLog_PurchaseOrder 生效');
END CATCH;

BEGIN TRY
    BEGIN TRAN;
    INSERT dbo.InventoryLog(ProductID,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,PurchaseID,SaleID)
    VALUES(@product,'STOCKTAKE_IN',1,0,1,@anyPurchase,NULL);
    ROLLBACK;
    INSERT #Result VALUES(N'流水类型与来源冲突',N'被拒绝',N'意外成功',0,N'盘点流水不应引用采购或销售单');
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    INSERT #Result VALUES(N'流水类型与来源冲突',N'被拒绝',IIF(ERROR_NUMBER()=547,N'被拒绝',ERROR_MESSAGE()),IIF(ERROR_NUMBER()=547,1,0),N'CK_InventoryLog_Source 生效');
END CATCH;

BEGIN TRY
    BEGIN TRAN;
    INSERT dbo.InventoryLog(ProductID,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,PurchaseID,SaleID)
    VALUES(@product,'PURCHASE_IN',-1,1,0,@anyPurchase,NULL);
    ROLLBACK;
    INSERT #Result VALUES(N'流水变化方向错误',N'被拒绝',N'意外成功',0,N'采购入库不允许负数');
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    INSERT #Result VALUES(N'流水变化方向错误',N'被拒绝',IIF(ERROR_NUMBER()=547,N'被拒绝',ERROR_MESSAGE()),IIF(ERROR_NUMBER()=547,1,0),N'CK_InventoryLog_Direction 生效');
END CATCH;

DECLARE @tag varchar(12)=RIGHT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),12);
DECLARE @purchaser bigint=(SELECT TOP(1) EmployeeID FROM dbo.Employee WHERE Status=1 AND RoleName IN ('PURCHASER','ADMIN') ORDER BY EmployeeID);
DECLARE @cashier bigint=(SELECT TOP(1) EmployeeID FROM dbo.Employee WHERE Status=1 AND RoleName IN ('CASHIER','ADMIN') ORDER BY EmployeeID);
DECLARE @wrongPurchaseEmployee bigint=(SELECT TOP(1) EmployeeID FROM dbo.Employee WHERE Status=1 AND RoleName='CASHIER' ORDER BY EmployeeID);
DECLARE @wrongSaleEmployee bigint=(SELECT TOP(1) EmployeeID FROM dbo.Employee WHERE Status=1 AND RoleName='PURCHASER' ORDER BY EmployeeID);
DECLARE @supplier bigint=(SELECT TOP(1) SupplierID FROM dbo.Supplier WHERE Status=1 ORDER BY SupplierID);
DECLARE @before int=(SELECT Quantity FROM dbo.Inventory WHERE ProductID=@product);
DECLARE @purchase bigint,@sale bigint,@caught int;

SET @caught=0;
BEGIN TRY
    BEGIN TRAN;
    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID) VALUES('W6R'+@tag,@supplier,@wrongPurchaseEmployee);
    SET @purchase=SCOPE_IDENTITY();
    INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost) VALUES(@purchase,@product,1,1.00);
    EXEC dbo.ConfirmPurchase @purchase;
    ROLLBACK;
END TRY
BEGIN CATCH
    SET @caught=ERROR_NUMBER();
    IF XACT_STATE()<>0 ROLLBACK;
END CATCH;
INSERT #Result VALUES(N'收银员作为采购经办人',N'51203 拒绝',CONCAT(N'错误 ',@caught),IIF(@caught=51203,1,0),N'采购过程要求 PURCHASER 或 ADMIN');

SET @caught=0;
BEGIN TRY
    BEGIN TRAN;
    INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod) VALUES('W6R'+@tag,@wrongSaleEmployee,'CASH');
    SET @sale=SCOPE_IDENTITY();
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice) VALUES(@sale,@product,1,2.00);
    EXEC dbo.CompleteSale @sale;
    ROLLBACK;
END TRY
BEGIN CATCH
    SET @caught=ERROR_NUMBER();
    IF XACT_STATE()<>0 ROLLBACK;
END CATCH;
INSERT #Result VALUES(N'采购员作为销售经办人',N'51306 拒绝',CONCAT(N'错误 ',@caught),IIF(@caught=51306,1,0),N'销售过程要求 CASHIER 或 ADMIN');

DECLARE @flowOk bit=0,@flowActual nvarchar(200)=N'未执行';
BEGIN TRY
    BEGIN TRAN;
    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID) VALUES('W6P'+@tag,@supplier,@purchaser);
    SET @purchase=SCOPE_IDENTITY();
    INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost) VALUES(@purchase,@product,2,1.00);
    EXEC dbo.ConfirmPurchase @purchase;
    INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod) VALUES('W6S'+@tag,@cashier,'CASH');
    SET @sale=SCOPE_IDENTITY();
    INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice) VALUES(@sale,@product,1,2.00);
    EXEC dbo.CompleteSale @sale;
    SET @flowOk=IIF(EXISTS(SELECT 1 FROM dbo.InventoryLog WHERE PurchaseID=@purchase AND SaleID IS NULL AND ChangeType='PURCHASE_IN')
        AND EXISTS(SELECT 1 FROM dbo.InventoryLog WHERE SaleID=@sale AND PurchaseID IS NULL AND ChangeType='SALE_OUT')
        AND (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@product)=@before+1,1,0);
    SET @flowActual=IIF(@flowOk=1,N'引用正确且库存净增 1',N'引用或库存结果错误');
    ROLLBACK;
END TRY
BEGIN CATCH
    SET @flowActual=ERROR_MESSAGE();
    IF XACT_STATE()<>0 ROLLBACK;
END CATCH;
INSERT #Result VALUES(N'迁移后采购销售流程',N'两类流水正确引用订单，库存净增 1',@flowActual,@flowOk,N'分别使用采购员和收银员，测试数据随后回滚');

IF DATABASE_PRINCIPAL_ID(N'Week6ViewerProbe') IS NOT NULL DROP USER Week6ViewerProbe;
IF DATABASE_PRINCIPAL_ID(N'Week6PurchaserProbe') IS NOT NULL DROP USER Week6PurchaserProbe;
IF DATABASE_PRINCIPAL_ID(N'Week6CashierProbe') IS NOT NULL DROP USER Week6CashierProbe;
IF DATABASE_PRINCIPAL_ID(N'Week6AdminProbe') IS NOT NULL DROP USER Week6AdminProbe;
CREATE USER Week6ViewerProbe WITHOUT LOGIN;
CREATE USER Week6PurchaserProbe WITHOUT LOGIN;
CREATE USER Week6CashierProbe WITHOUT LOGIN;
CREATE USER Week6AdminProbe WITHOUT LOGIN;
ALTER ROLE CampusViewer ADD MEMBER Week6ViewerProbe;
ALTER ROLE CampusPurchaser ADD MEMBER Week6PurchaserProbe;
ALTER ROLE CampusCashier ADD MEMBER Week6CashierProbe;
ALTER ROLE CampusAdmin ADD MEMBER Week6AdminProbe;
DECLARE @permissionLogID bigint;

SET @caught=0;
BEGIN TRY
    EXECUTE AS USER=N'Week6CashierProbe';
    UPDATE dbo.Inventory SET Quantity=Quantity WHERE ProductID=@product;
    REVERT;
END TRY
BEGIN CATCH
    SET @caught=ERROR_NUMBER();
    IF USER_NAME()=N'Week6CashierProbe' REVERT;
END CATCH;
INSERT #Result VALUES(N'收银员直接修改库存',N'229 拒绝',CONCAT(N'错误 ',@caught),IIF(@caught=229,1,0),N'原有 DENY UPDATE 继续生效');

SET @caught=0;
BEGIN TRY
    EXECUTE AS USER=N'Week6ViewerProbe';
    SELECT TOP(1) @permissionLogID=LogID FROM dbo.v_inventory_log_detail;
    REVERT;
END TRY
BEGIN CATCH
    SET @caught=ERROR_NUMBER();
    IF USER_NAME()=N'Week6ViewerProbe' REVERT;
END CATCH;
INSERT #Result VALUES(N'浏览者读取全部库存流水',N'229 拒绝',CONCAT(N'错误 ',@caught),IIF(@caught=229,1,0),N'汇总浏览权限不包含完整业务流水');

SET @caught=0;
BEGIN TRY
    EXECUTE AS USER=N'Week6PurchaserProbe';
    SELECT TOP(1) @permissionLogID=LogID FROM dbo.v_inventory_log_detail;
    REVERT;
END TRY
BEGIN CATCH
    SET @caught=ERROR_NUMBER();
    IF USER_NAME()=N'Week6PurchaserProbe' REVERT;
END CATCH;
INSERT #Result VALUES(N'采购员读取全部库存流水',N'229 拒绝',CONCAT(N'错误 ',@caught),IIF(@caught=229,1,0),N'采购角色不能跨域读取销售流水');

SET @caught=0;
BEGIN TRY
    EXECUTE AS USER=N'Week6CashierProbe';
    SELECT TOP(1) @permissionLogID=LogID FROM dbo.v_inventory_log_detail;
    REVERT;
END TRY
BEGIN CATCH
    SET @caught=ERROR_NUMBER();
    IF USER_NAME()=N'Week6CashierProbe' REVERT;
END CATCH;
INSERT #Result VALUES(N'收银员读取全部库存流水',N'229 拒绝',CONCAT(N'错误 ',@caught),IIF(@caught=229,1,0),N'收银角色不能跨域读取采购流水');

SET @caught=0;
BEGIN TRY
    EXECUTE AS USER=N'Week6AdminProbe';
    SELECT TOP(1) @permissionLogID=LogID FROM dbo.v_inventory_log_detail;
    REVERT;
END TRY
BEGIN CATCH
    SET @caught=ERROR_NUMBER();
    IF USER_NAME()=N'Week6AdminProbe' REVERT;
END CATCH;
INSERT #Result VALUES(N'管理员读取全部库存流水',N'允许',IIF(@caught=0,N'允许',CONCAT(N'错误 ',@caught)),IIF(@caught=0,1,0),N'管理员沿用 dbo 架构查询权限');

DROP USER Week6ViewerProbe;
DROP USER Week6PurchaserProbe;
DROP USER Week6CashierProbe;
DROP USER Week6AdminProbe;

SELECT TestName AS 测试项,Expected AS 预期,Actual AS 实际,
       IIF(Passed=1,N'通过',N'失败') AS 结论,Explanation AS 说明
FROM #Result ORDER BY TestName;

IF EXISTS(SELECT 1 FROM #Result WHERE Passed=0)
    THROW 51629, N'第六周回归存在失败项', 1;
DECLARE @passedCount int=(SELECT COUNT(*) FROM #Result);
PRINT CONCAT(N'第六周迁移回归全部通过，共 ',@passedCount,N' 项');
