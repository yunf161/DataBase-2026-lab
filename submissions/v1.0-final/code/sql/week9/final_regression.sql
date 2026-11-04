/* 第九周最终回归：在最终 W7 应用库上做只读核对，每项输出预期值与实际值。
   不修改任何业务数据、结构或权限；只读取数据和权限信息，并在结束时用 THROW 反映总体结果。
   用法：sqlcmd -S . -E -No -b -f 65001 -d CampusStoreDB_W7_Development -i sql\week9\final_regression.sql */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
SET XACT_ABORT OFF;

IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]%'
    THROW 51900, N'最终回归只能在名称为 CampusStoreDB_W7_* 的应用数据库运行', 1;
IF SCHEMA_ID(N'app') IS NULL OR OBJECT_ID(N'app.SaleOwner',N'U') IS NULL
   OR COL_LENGTH(N'app.SaleOwner',N'SubmittedAt') IS NULL
    THROW 51901, N'缺少第七周应用对象或第九周 SubmittedAt 列，请先运行 tools.upgrade_week9', 1;

CREATE TABLE #Result(
    Seq int IDENTITY(1,1) PRIMARY KEY,
    Category nvarchar(30) NOT NULL,
    TestName nvarchar(100) NOT NULL,
    Expected nvarchar(200) NOT NULL,
    Actual nvarchar(200) NOT NULL,
    Passed bit NOT NULL,
    Explanation nvarchar(300) NOT NULL
);
DECLARE @total bigint,@bad bigint;

-- 1. 库存等于最新一条流水的 AfterQuantity（只检查有流水的商品；最新以 LogID 最大为准）
;WITH Latest AS (
    SELECT l.ProductID,l.AfterQuantity,
           ROW_NUMBER() OVER (PARTITION BY l.ProductID ORDER BY l.LogID DESC) AS rn
    FROM dbo.InventoryLog AS l
)
SELECT @total=COUNT_BIG(*),
       @bad=COALESCE(SUM(CASE WHEN i.Quantity<>x.AfterQuantity THEN 1 ELSE 0 END),0)
FROM Latest AS x JOIN dbo.Inventory AS i ON i.ProductID=x.ProductID
WHERE x.rn=1;
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'库存',N'库存等于最新流水 AfterQuantity',CONCAT(@total,N' 个商品一致'),CONCAT(@total-@bad,N' 个商品一致'),IIF(@bad=0,1,0),
       N'有流水的商品，Inventory.Quantity 必须等于 LogID 最大那条流水的 AfterQuantity');

SELECT @total=COUNT_BIG(*) FROM dbo.InventoryLog AS l
WHERE NOT EXISTS(SELECT 1 FROM dbo.Inventory AS i WHERE i.ProductID=l.ProductID);
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'库存',N'流水所属商品均有库存行',N'0 条孤立流水',CONCAT(@total,N' 条孤立流水'),IIF(@total=0,1,0),N'逐条核对 InventoryLog.ProductID 在 Inventory 中存在');

-- 2. 已完成订单金额
SELECT @total=COUNT_BIG(*),
       @bad=COALESCE(SUM(CASE WHEN so.TotalAmount<>COALESCE(d.LineTotal,0) THEN 1 ELSE 0 END),0)
FROM dbo.SaleOrder AS so
OUTER APPLY (SELECT SUM(si.LineAmount) AS LineTotal FROM dbo.SaleItem AS si WHERE si.SaleID=so.SaleID) AS d
WHERE so.Status='COMPLETED';
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'订单金额',N'TotalAmount 等于明细合计',CONCAT(@total,N' 张已完成订单一致'),CONCAT(@total-@bad,N' 张已完成订单一致'),IIF(@bad=0,1,0),
       N'与 SUM(SaleItem.LineAmount) 逐单比较，不能由订单间差额相互抵消');

SELECT @total=COUNT_BIG(*),
       @bad=COALESCE(SUM(CASE WHEN so.PayableAmount<>so.TotalAmount-so.DiscountAmount THEN 1 ELSE 0 END),0)
FROM dbo.SaleOrder AS so WHERE so.Status='COMPLETED';
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'订单金额',N'PayableAmount 等于合计减优惠',CONCAT(@total,N' 张已完成订单一致'),CONCAT(@total-@bad,N' 张已完成订单一致'),IIF(@bad=0,1,0),
       N'应付金额为计算列，同时核对优惠不超过合计');

SELECT @bad=COUNT_BIG(*) FROM dbo.SaleOrder AS so
WHERE so.Status='COMPLETED' AND (so.DiscountAmount>so.TotalAmount OR so.PayableAmount<0);
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'订单金额',N'已完成订单优惠不超过合计、应付不为负',N'0 张违规',CONCAT(@bad,N' 张违规'),IIF(@bad=0,1,0),N'对应 CK_SaleOrder_Amount 的结果核对');

-- 3. 商品销量统计与已完成订单明细一致
-- 统计视图对无销售商品做外连接聚合，关闭无害的 NULL 消除警告，查询后恢复。
SET ANSI_WARNINGS OFF;
DECLARE @expectedQuantity bigint,@viewQuantity bigint,@expectedAmount decimal(38,2),@viewAmount decimal(38,2);
SELECT @expectedQuantity=COALESCE(SUM(CONVERT(bigint,si.Quantity)),0),
       @expectedAmount=COALESCE(SUM(CONVERT(decimal(38,2),si.LineAmount)),0)
FROM dbo.SaleItem AS si JOIN dbo.SaleOrder AS so ON so.SaleID=si.SaleID WHERE so.Status='COMPLETED';
SELECT @viewQuantity=COALESCE(SUM(SoldQuantity),0),@viewAmount=COALESCE(SUM(SalesAmount),0) FROM dbo.v_product_sales;
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'销量统计',N'销量合计与已完成订单明细一致',CONCAT(N'数量 ',@expectedQuantity),CONCAT(N'数量 ',@viewQuantity),IIF(@expectedQuantity=@viewQuantity,1,0),
       N'预期值由 SaleItem 与已完成 SaleOrder 直接汇总；实际值来自 v_product_sales');
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'销量统计',N'销售额合计与已完成订单明细一致',CONCAT(N'金额 ',@expectedAmount),CONCAT(N'金额 ',@viewAmount),IIF(@expectedAmount=@viewAmount,1,0),
       N'同上，按 LineAmount 汇总');

;WITH Expected AS (
    SELECT si.ProductID,SUM(CONVERT(bigint,si.Quantity)) AS Quantity,SUM(CONVERT(decimal(38,2),si.LineAmount)) AS Amount
    FROM dbo.SaleItem AS si JOIN dbo.SaleOrder AS so ON so.SaleID=si.SaleID
    WHERE so.Status='COMPLETED' GROUP BY si.ProductID
)
SELECT @bad=COUNT_BIG(*)
FROM dbo.v_product_sales AS v LEFT JOIN Expected AS e ON e.ProductID=v.ProductID
WHERE v.SoldQuantity<>COALESCE(e.Quantity,0) OR v.SalesAmount<>COALESCE(e.Amount,0);
SELECT @total=COUNT_BIG(*) FROM dbo.v_product_sales;
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'销量统计',N'逐商品销量与销售额一致',CONCAT(@total,N' 个商品一致'),CONCAT(@total-@bad,N' 个商品一致'),IIF(@bad=0,1,0),
       N'逐商品比较，草稿和已取消订单不得计入');
SET ANSI_WARNINGS ON;

-- 4. 外键有效与流水来源约束
CREATE TABLE #Violation(TableName nvarchar(300),ConstraintName nvarchar(300),WhereClause nvarchar(1000));
INSERT #Violation EXEC(N'DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS, ALL_ERRORMSGS, NO_INFOMSGS');
SELECT @bad=COUNT_BIG(*) FROM #Violation;
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'完整性',N'全库外键与检查约束无违规行',N'0 行违规',CONCAT(@bad,N' 行违规'),IIF(@bad=0,1,0),N'DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS，只读取数据');

SELECT @total=COUNT_BIG(*),@bad=COALESCE(SUM(CASE WHEN is_disabled=1 OR is_not_trusted=1 THEN 1 ELSE 0 END),0) FROM sys.foreign_keys;
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'完整性',N'外键均启用且受信任',CONCAT(@total,N' 个外键有效'),CONCAT(@total-@bad,N' 个外键有效'),IIF(@bad=0,1,0),N'sys.foreign_keys 的 is_disabled 与 is_not_trusted');

SELECT @bad=COUNT_BIG(*) FROM dbo.InventoryLog AS l
WHERE NOT (
      (l.ChangeType IN ('PURCHASE_IN','PURCHASE_RETURN') AND l.PurchaseID IS NOT NULL AND l.SaleID IS NULL)
   OR (l.ChangeType IN ('SALE_OUT','SALE_RETURN') AND l.SaleID IS NOT NULL AND l.PurchaseID IS NULL)
   OR (l.ChangeType IN ('STOCKTAKE_IN','STOCKTAKE_OUT') AND l.PurchaseID IS NULL AND l.SaleID IS NULL));
SELECT @total=COUNT_BIG(*) FROM dbo.InventoryLog;
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'完整性',N'流水来源与业务类型匹配',CONCAT(@total,N' 条流水来源正确'),CONCAT(@total-@bad,N' 条流水来源正确'),IIF(@bad=0,1,0),
       N'采购类只引用采购单，销售类只引用销售单，盘点类不引用单据');

SELECT @total=COUNT_BIG(*),
       @bad=COALESCE(SUM(CASE WHEN so.SaleID IS NULL OR so.Status<>'COMPLETED' THEN 1 ELSE 0 END),0)
FROM dbo.InventoryLog AS l LEFT JOIN dbo.SaleOrder AS so ON so.SaleID=l.SaleID
WHERE l.ChangeType='SALE_OUT';
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'完整性',N'销售出库流水只来自已完成销售单',CONCAT(@total,N' 条来自已完成订单'),CONCAT(@total-@bad,N' 条来自已完成订单'),IIF(@bad=0,1,0),
       N'草稿、待受理和已取消订单不得产生库存流水');

SELECT @total=COUNT_BIG(*),
       @bad=COALESCE(SUM(CASE WHEN po.PurchaseID IS NULL OR po.Status<>'RECEIVED' THEN 1 ELSE 0 END),0)
FROM dbo.InventoryLog AS l LEFT JOIN dbo.PurchaseOrder AS po ON po.PurchaseID=l.PurchaseID
WHERE l.ChangeType='PURCHASE_IN';
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'完整性',N'采购入库流水只来自已入库采购单',CONCAT(@total,N' 条来自已入库订单'),CONCAT(@total-@bad,N' 条来自已入库订单'),IIF(@bad=0,1,0),
       N'与销售对称的来源核对');

SELECT @total=COUNT_BIG(*),@bad=COALESCE(SUM(CASE WHEN is_disabled=1 OR is_not_trusted=1 THEN 1 ELSE 0 END),0)
FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'dbo.InventoryLog')
  AND name IN (N'CK_InventoryLog_Source',N'CK_InventoryLog_Direction',N'CK_InventoryLog_Quantity');
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'完整性',N'流水来源、方向和数量检查约束存在且受信任',N'3 个约束有效',CONCAT(@total-@bad,N' 个约束有效'),IIF(@total=3 AND @bad=0,1,0),
       N'CK_InventoryLog_Source / Direction / Quantity');

-- 5. Web 受限角色权限（模拟各身份后读取有效权限，并真实尝试一次读取 AppUser；全程只读）
DECLARE @principals TABLE(Seq int IDENTITY(1,1),Name sysname);
INSERT @principals(Name) VALUES(N'WebAuth'),(N'WebAdmin'),(N'WebStaff'),(N'WebCustomer');
DECLARE @i int=1,@n int=(SELECT COUNT(*) FROM @principals),@name sysname,
        @isOwner int,@canQuantity int,@canTable int,@canHash int,@readError int,@readCount bigint;
WHILE @i<=@n
BEGIN
    SELECT @name=Name FROM @principals WHERE Seq=@i;
    SELECT @readError=0,@readCount=NULL;
    EXECUTE AS USER=@name;
    SELECT @isOwner=COALESCE(IS_MEMBER(N'db_owner'),-1),
           @canQuantity=COALESCE(HAS_PERMS_BY_NAME(N'dbo.Inventory',N'OBJECT',N'UPDATE',N'Quantity',N'COLUMN'),-1),
           @canTable=COALESCE(HAS_PERMS_BY_NAME(N'app.AppUser',N'OBJECT',N'SELECT'),-1),
           @canHash=COALESCE(HAS_PERMS_BY_NAME(N'app.AppUser',N'OBJECT',N'SELECT',N'PasswordHash',N'COLUMN'),-1);
    BEGIN TRY
        SELECT @readCount=COUNT_BIG(*) FROM app.AppUser;
    END TRY
    BEGIN CATCH
        SET @readError=ERROR_NUMBER();
    END CATCH;
    REVERT;
    INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
    VALUES(N'权限',CONCAT(@name,N'：不是 db_owner'),N'0（否）',CAST(@isOwner AS nvarchar(10)),IIF(@isOwner=0,1,0),N'IS_MEMBER(N''db_owner'')');
    INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
    VALUES(N'权限',CONCAT(@name,N'：不能直接改 Inventory.Quantity'),N'0（无 UPDATE 权限）',CAST(@canQuantity AS nvarchar(10)),IIF(@canQuantity=0,1,0),
           N'HAS_PERMS_BY_NAME(Inventory, UPDATE, Quantity)；库存只能经受控过程修改');
    IF @name=N'WebAuth'
        INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
        VALUES(N'权限',N'WebAuth：仅认证读取 AppUser（设计如此）',N'1（可读，错误 0）',CONCAT(@canTable,N'（错误 ',@readError,N'）'),
               IIF(@canTable=1 AND @readError=0,1,0),N'登录认证需要读取密码哈希；该身份没有任何业务写权限');
    ELSE
    BEGIN
        INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
        VALUES(N'权限',CONCAT(@name,N'：不能读 AppUser'),N'0（无 SELECT 权限）',CAST(@canTable AS nvarchar(10)),IIF(@canTable=0 AND @canHash=0,1,0),
               N'表级与 PasswordHash 列级 SELECT 均为 0');
        INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
        VALUES(N'权限',CONCAT(@name,N'：实际读取 AppUser 被拒绝'),N'错误 229',CONCAT(N'错误 ',@readError),IIF(@readError=229,1,0),
               N'真实执行 SELECT COUNT(*)，只统计行数，不返回任何账号数据');
    END;
    SET @i+=1;
END;

SELECT @bad=COUNT_BIG(*)
FROM sys.database_role_members AS m
JOIN sys.database_principals AS r ON r.principal_id=m.role_principal_id AND r.name=N'db_owner'
JOIN sys.database_principals AS u ON u.principal_id=m.member_principal_id
WHERE u.name LIKE N'Web%';
INSERT #Result(Category,TestName,Expected,Actual,Passed,Explanation)
VALUES(N'权限',N'db_owner 成员中没有 Web* 用户或角色',N'0 个',CONCAT(@bad,N' 个'),IIF(@bad=0,1,0),N'sys.database_role_members');

SELECT Seq AS 序号,Category AS 类别,TestName AS 检查项,Expected AS 预期值,Actual AS 实际值,
       IIF(Passed=1,N'通过',N'失败') AS 结果,Explanation AS 说明
FROM #Result ORDER BY Seq;

SELECT @total=COUNT_BIG(*),@bad=COALESCE(SUM(CASE WHEN Passed=0 THEN 1 ELSE 0 END),0) FROM #Result;
SELECT DB_NAME() AS 数据库,@total AS 检查项,@total-@bad AS 通过,@bad AS 失败;
IF @bad>0
    THROW 51902, N'最终回归存在失败项，请查看上方结果', 1;
PRINT N'最终回归全部通过（只读）';
