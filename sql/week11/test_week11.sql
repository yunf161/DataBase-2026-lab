/* 第十一周验证：库存审计触发器、订单完成规则触发器、三类窗口查询。
   覆盖单条插入、单条修改、多条修改、正常操作、非法数据和触发器拒绝操作；保存审计记录、订单状态和窗口查询结果。
   只在随机测试库运行：python -m tools.verify_week12。 */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET XACT_ABORT OFF;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]Test[_]%'
    THROW 51700,N'验证脚本只在随机测试库运行，请使用 python -m tools.verify_week12',1;
IF @@TRANCOUNT<>0 THROW 51700,N'请在没有外层事务的连接上运行',1;
IF OBJECT_ID(N'tempdb..#Result') IS NOT NULL DROP TABLE #Result;
CREATE TABLE #Result(Seq int IDENTITY PRIMARY KEY, CaseNo varchar(10), Area nvarchar(20), CaseName nvarchar(60),
                     Action nvarchar(300), Expected nvarchar(400), Actual nvarchar(800), Passed bit);
IF OBJECT_ID(N'tempdb..#Rec') IS NOT NULL DROP PROCEDURE #Rec;
IF OBJECT_ID(N'tempdb..#NewProduct') IS NOT NULL DROP PROCEDURE #NewProduct;
IF OBJECT_ID(N'tempdb..#NewDraft') IS NOT NULL DROP PROCEDURE #NewDraft;
IF OBJECT_ID(N'tempdb..#FakeSaleOut') IS NOT NULL DROP PROCEDURE #FakeSaleOut;
GO
CREATE PROCEDURE #Rec @No varchar(10),@Area nvarchar(20),@Case nvarchar(60),@Act nvarchar(300),
    @Exp nvarchar(400),@Actual nvarchar(800),@Ok bit
AS INSERT #Result(CaseNo,Area,CaseName,Action,Expected,Actual,Passed) VALUES(@No,@Area,@Case,@Act,@Exp,@Actual,ISNULL(@Ok,0));
GO
CREATE PROCEDURE #NewProduct @SKU varchar(30),@Name nvarchar(100),@Price decimal(10,2),@ProductID bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.Product(SKU,ProductName,CategoryID,Unit,SalePrice)
    SELECT @SKU,@Name,CategoryID,N'件',@Price FROM dbo.Category WHERE CategoryCode='DRINK';
    SET @ProductID=SCOPE_IDENTITY();
END;
GO
-- 草稿订单：一件商品 @Qty 个（@Qty=0 时没有明细），草稿的总额为 0。
CREATE PROCEDURE #NewDraft @ProductID bigint,@Qty int,@SaleID bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @no varchar(30)='T11S'+LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),20);
    INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod)
    SELECT @no,EmployeeID,'CASH' FROM dbo.Employee WHERE EmployeeNo='E003';
    SET @SaleID=SCOPE_IDENTITY();
    IF @Qty>0 INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
              SELECT @SaleID,ProductID,@Qty,SalePrice FROM dbo.Product WHERE ProductID=@ProductID;
END;
GO
-- 模拟“有缺陷的过程”只写了销售出库流水、没有真正改库存，用来单独检验完成规则触发器（只在事务中使用并回滚）。
CREATE PROCEDURE #FakeSaleOut @SaleID bigint
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.InventoryLog(ProductID,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,PurchaseID,SaleID,EmployeeID)
    SELECT si.ProductID,'SALE_OUT',-si.Quantity,si.Quantity+100,100,NULL,@SaleID,NULL
    FROM dbo.SaleItem si WHERE si.SaleID=@SaleID;
END;
GO
DECLARE @tag varchar(8)=LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),8);
DECLARE @P bigint,@Q bigint,@R bigint,@S bigint,@sale bigint,@sale2 bigint,@done bigint;
DECLARE @err int,@msg nvarchar(400),@ok bit,@n int,@n2 int,@actual nvarchar(800),@maxAudit bigint;
DECLARE @admin bigint=(SELECT EmployeeID FROM dbo.Employee WHERE EmployeeNo='E001');
DECLARE @cashier bigint=(SELECT EmployeeID FROM dbo.Employee WHERE EmployeeNo='E003');
DECLARE @skuP varchar(30)='TP'+@tag,@skuQ varchar(30)='TQ'+@tag,@skuR varchar(30)='TR'+@tag,@skuS varchar(30)='TS'+@tag;

/* ================= 库存审计触发器 dbo.tr_Inventory_Audit ================= */
-- T-01 单条插入：新增商品时 tr_Product_CreateInventory 插入一行库存，审计记录一条 INSERT
SET @maxAudit=COALESCE((SELECT MAX(AuditID) FROM dbo.InventoryAudit),0);
EXEC #NewProduct @skuP,N'审计测试P',10.00,@P OUTPUT;
SET @ok=0;
SELECT @ok=IIF(COUNT(*)=1 AND MAX(OperationType)='INSERT' AND MAX(AfterQuantity)=0 AND COUNT(BeforeQuantity)=0,1,0),
       @actual=CONCAT(N'新增审计 ',COUNT(*),N' 条：',MAX(OperationType),N'，调整前 ',COALESCE(CONVERT(nvarchar(20),MAX(BeforeQuantity)),N'NULL'),
                      N'，调整后 ',MAX(AfterQuantity),N'，数据库用户 ',MAX(DatabaseUser),N'，登录名 ',MAX(LoginName))
FROM dbo.InventoryAudit WHERE AuditID>@maxAudit AND ProductID=@P;
EXEC #Rec 'T-01',N'库存审计',N'单条插入',N'INSERT 一件新商品（触发器自动建零库存行）',
    N'1 条 INSERT 审计：调整前 NULL、调整后 0，记下数据库用户和登录名',@actual,@ok;

-- T-02 单条修改（经过程）：盘盈 +10，操作人员为过程写入的员工 E001
SET @maxAudit=(SELECT MAX(AuditID) FROM dbo.InventoryAudit);
EXEC dbo.usp_AdjustInventory @ProductCode=@skuP,@ChangeQuantity=10,@Reason=N'审计测试',@EmployeeNo='E001',@Quiet=1;
SELECT @ok=IIF(COUNT(*)=1 AND MAX(OperationType)='INCREASE' AND MAX(BeforeQuantity)=0 AND MAX(AfterQuantity)=10
               AND MAX(ChangeQuantity)=10 AND MAX(OperatorEmployeeID)=@admin AND MAX(OperatedAt) IS NOT NULL,1,0),
       @actual=CONCAT(N'新增审计 ',COUNT(*),N' 条：',MAX(OperationType),N' ',MAX(BeforeQuantity),N'→',MAX(AfterQuantity),
                      N'（变化 ',MAX(ChangeQuantity),N'），操作员工 ID ',MAX(OperatorEmployeeID),N'，时间 ',CONVERT(varchar(23),MAX(OperatedAt),121))
FROM dbo.InventoryAudit WHERE AuditID>@maxAudit;
EXEC #Rec 'T-02',N'库存审计',N'单条修改（增加）',N'EXEC dbo.usp_AdjustInventory P +10，员工 E001',
    N'1 条 INCREASE 审计：0→10，变化 10，操作人员为 E001，有操作时间',@actual,@ok;

-- T-03 单条修改（只改预警下限）
SET @maxAudit=(SELECT MAX(AuditID) FROM dbo.InventoryAudit);
UPDATE dbo.Inventory SET MinQuantity=8 WHERE ProductID=@P;
SELECT @ok=IIF(COUNT(*)=1 AND MAX(OperationType)='MODIFY' AND MAX(BeforeMinQuantity)=10 AND MAX(AfterMinQuantity)=8 AND MAX(ChangeQuantity)=0,1,0),
       @actual=CONCAT(N'新增审计 ',COUNT(*),N' 条：',MAX(OperationType),N'，下限 ',MAX(BeforeMinQuantity),N'→',MAX(AfterMinQuantity),N'，数量变化 ',MAX(ChangeQuantity))
FROM dbo.InventoryAudit WHERE AuditID>@maxAudit;
EXEC #Rec 'T-03',N'库存审计',N'单条修改（预警下限）',N'UPDATE MinQuantity 10→8',N'1 条 MODIFY 审计，下限 10→8，数量变化 0',@actual,@ok;

-- T-04 多条修改：一条 UPDATE 同时改 3 件商品的数量（模拟业务过程，先写入会话授权标记和操作员工）
EXEC #NewProduct @skuQ,N'审计测试Q',10.00,@Q OUTPUT;
EXEC #NewProduct @skuR,N'审计测试R',10.00,@R OUTPUT;
SET @maxAudit=(SELECT MAX(AuditID) FROM dbo.InventoryAudit);
EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite',@value=1;
EXEC sys.sp_set_session_context @key=N'CampusStoreOperator',@value=@admin;
UPDATE dbo.Inventory SET Quantity=Quantity+3 WHERE ProductID IN (@P,@Q,@R);
EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite',@value=NULL;
EXEC sys.sp_set_session_context @key=N'CampusStoreOperator',@value=NULL;
SELECT @ok=IIF(COUNT(*)=3 AND SUM(IIF(OperationType='INCREASE' AND ChangeQuantity=3 AND AfterQuantity=BeforeQuantity+3,1,0))=3
               AND SUM(IIF(ProductID=@P AND BeforeQuantity=10 AND AfterQuantity=13,1,0))=1
               AND SUM(IIF(ProductID=@Q AND BeforeQuantity=0 AND AfterQuantity=3,1,0))=1,1,0),
       @actual=CONCAT(N'新增审计 ',COUNT(*),N' 条：',STRING_AGG(CONCAT(ProductID,N':',OperationType,N' ',BeforeQuantity,N'→',AfterQuantity),N'；'))
FROM dbo.InventoryAudit WHERE AuditID>@maxAudit;
EXEC #Rec 'T-04',N'库存审计',N'多条修改（数量）',N'一条 UPDATE 把 P、Q、R 的库存各加 3',
    N'3 条 INCREASE 审计，每件商品一条，前后数量各自正确（P 10→13，Q 0→3，R 0→3）',@actual,@ok;

-- T-05 多条修改：一条 UPDATE 同时改 3 件商品的预警下限
SET @maxAudit=(SELECT MAX(AuditID) FROM dbo.InventoryAudit);
UPDATE dbo.Inventory SET MinQuantity=MinQuantity+1 WHERE ProductID IN (@P,@Q,@R);
SELECT @ok=IIF(COUNT(*)=3 AND SUM(IIF(OperationType='MODIFY' AND AfterMinQuantity=BeforeMinQuantity+1,1,0))=3,1,0),
       @actual=CONCAT(N'新增审计 ',COUNT(*),N' 条：',STRING_AGG(CONCAT(ProductID,N':',OperationType,N' 下限 ',BeforeMinQuantity,N'→',AfterMinQuantity),N'；'))
FROM dbo.InventoryAudit WHERE AuditID>@maxAudit;
EXEC #Rec 'T-05',N'库存审计',N'多条修改（下限）',N'一条 UPDATE 把 P、Q、R 的下限各加 1',N'3 条 MODIFY 审计',@actual,@ok;

-- T-06 正常业务：订单完成扣库存，审计记录减少，操作人员为结算员工
SET @maxAudit=(SELECT MAX(AuditID) FROM dbo.InventoryAudit);
EXEC #NewDraft @P,2,@done OUTPUT;
INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice) VALUES(@done,@Q,1,10.00);
EXEC dbo.usp_CompleteOrder @SaleID=@done,@Quiet=1;
SELECT @ok=IIF(COUNT(*)=2 AND SUM(IIF(OperationType='DECREASE' AND OperatorEmployeeID=@cashier,1,0))=2
               AND SUM(IIF(ProductID=@P AND BeforeQuantity=13 AND AfterQuantity=11,1,0))=1,1,0),
       @actual=CONCAT(N'新增审计 ',COUNT(*),N' 条：',STRING_AGG(CONCAT(ProductID,N':',OperationType,N' ',BeforeQuantity,N'→',AfterQuantity,N' 员工',OperatorEmployeeID),N'；'))
FROM dbo.InventoryAudit WHERE AuditID>@maxAudit;
EXEC #Rec 'T-06',N'库存审计',N'正常业务（订单完成）',N'EXEC dbo.usp_CompleteOrder：P×2、Q×1',
    N'2 条 DECREASE 审计（P 13→11、Q 3→2），操作人员为结算员工 E003',@actual,@ok;

-- T-07 删除：安全删除一件从未使用的商品，审计记录 DELETE
EXEC #NewProduct @skuS,N'审计测试S',10.00,@S OUTPUT;
SET @maxAudit=(SELECT MAX(AuditID) FROM dbo.InventoryAudit);
EXEC app.DeleteUnusedProduct @ProductID=@S;
SELECT @ok=IIF(COUNT(*)=1 AND MAX(OperationType)='DELETE' AND MAX(BeforeQuantity)=0 AND COUNT(AfterQuantity)=0
               AND NOT EXISTS(SELECT 1 FROM dbo.Product WHERE ProductID=@S),1,0),
       @actual=CONCAT(N'新增审计 ',COUNT(*),N' 条：',MAX(OperationType),N'，调整前 ',MAX(BeforeQuantity),N'，调整后 ',
                      COALESCE(CONVERT(nvarchar(20),MAX(AfterQuantity)),N'NULL'),N'；商品已删除，审计仍保留')
FROM dbo.InventoryAudit WHERE AuditID>@maxAudit AND ProductID=@S;
EXEC #Rec 'T-07',N'库存审计',N'删除',N'EXEC app.DeleteUnusedProduct 删除未使用的商品 S',N'1 条 DELETE 审计（调整后为 NULL），商品删除后审计记录仍在',@actual,@ok;

-- T-08 非法数据：数量改成负数被检查约束拒绝，审计不留记录
SET @n=(SELECT COUNT(*) FROM dbo.InventoryAudit);
SET @err=0; SET @msg=NULL;
EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite',@value=1;
BEGIN TRY UPDATE dbo.Inventory SET Quantity=-1 WHERE ProductID=@P; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite',@value=NULL;
SET @n2=(SELECT COUNT(*) FROM dbo.InventoryAudit);
SET @ok=IIF(@err=547 AND @n=@n2 AND (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P)=11,1,0);
SET @actual=CONCAT(N'错误 ',@err,N'；审计条数 ',@n,N'→',@n2,N'；P 库存 ',(SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P));
EXEC #Rec 'T-08',N'库存审计',N'非法数据',N'把 P 的库存改为 -1',N'检查约束拒绝（错误 547），审计不增加，库存仍为 11',@actual,@ok;

-- T-09 触发器拒绝：没有业务授权直接改数量，被 tr_Inventory_QuantityGuard 拒绝，审计随之回滚
SET @n=(SELECT COUNT(*) FROM dbo.InventoryAudit);
SET @err=0; SET @msg=NULL;
BEGIN TRY UPDATE dbo.Inventory SET Quantity=99 WHERE ProductID=@P; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
IF XACT_STATE()<>0 ROLLBACK;
SET @n2=(SELECT COUNT(*) FROM dbo.InventoryAudit);
SET @ok=IIF(@err=51011 AND @n=@n2 AND (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P)=11,1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；审计条数 ',@n,N'→',@n2);
EXEC #Rec 'T-09',N'库存审计',N'触发器拒绝操作',N'不经过业务过程直接 UPDATE 库存数量',N'错误 51011；审计不增加（与被拒绝的修改一起回滚）',@actual,@ok;

-- T-10 多行中有一行非法：整条语句回滚，3 件商品都不变、都不留审计
SET @n=(SELECT COUNT(*) FROM dbo.InventoryAudit);
SET @err=0;
EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite',@value=1;
BEGIN TRY UPDATE dbo.Inventory SET Quantity=Quantity-3 WHERE ProductID IN (@P,@Q,@R); END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); END CATCH;
EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite',@value=NULL;
SET @n2=(SELECT COUNT(*) FROM dbo.InventoryAudit);
SET @ok=IIF(@err=547 AND @n=@n2 AND (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@Q)=2
            AND (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P)=11,1,0);
SET @actual=CONCAT(N'错误 ',@err,N'；审计条数 ',@n,N'→',@n2,N'；P=',(SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P),
                   N' Q=',(SELECT Quantity FROM dbo.Inventory WHERE ProductID=@Q),N' R=',(SELECT Quantity FROM dbo.Inventory WHERE ProductID=@R));
EXEC #Rec 'T-10',N'库存审计',N'多行中有一行非法',N'一条 UPDATE 把 P、Q、R 各减 3（Q 只有 2）',
    N'整条语句被拒绝（错误 547），三件商品都不变，没有任何审计记录',@actual,@ok;

PRINT N'库存审计记录（本脚本的测试商品）：';
SELECT a.AuditID AS audit_id, p.SKU AS sku, a.OperationType AS operation_type, a.BeforeQuantity AS before_quantity,
       a.AfterQuantity AS after_quantity, a.ChangeQuantity AS change_quantity, a.BeforeMinQuantity AS before_min,
       a.AfterMinQuantity AS after_min, e.EmployeeNo AS operator_no, a.DatabaseUser AS database_user,
       CONVERT(varchar(23),a.OperatedAt,121) AS operated_at
FROM dbo.InventoryAudit a LEFT JOIN dbo.Product p ON p.ProductID=a.ProductID
LEFT JOIN dbo.Employee e ON e.EmployeeID=a.OperatorEmployeeID
WHERE a.ProductID IN (@P,@Q,@R,@S) ORDER BY a.AuditID;

/* ================= 订单完成规则触发器 dbo.tr_SaleOrder_CompleteRule ================= */
-- C-01 正常完成（T-06 的订单）
SELECT @ok=IIF(Status='COMPLETED' AND TotalAmount=30.00,1,0), @actual=CONCAT(N'订单 ',Status,N'，总额 ',TotalAmount)
FROM dbo.SaleOrder WHERE SaleID=@done;
EXEC #Rec 'C-01',N'完成规则',N'正常完成',N'T-06 经 dbo.usp_CompleteOrder 完成的订单',N'规则检查全部通过，订单已完成，总额 30.00',@actual,@ok;

-- C-02 已完成的订单不能重复完成
SET @err=0; SET @msg=NULL;
BEGIN TRY UPDATE dbo.SaleOrder SET Status='COMPLETED' WHERE SaleID=@done; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
IF XACT_STATE()<>0 ROLLBACK;
SET @ok=IIF(@err=51751 AND (SELECT COUNT(*) FROM dbo.InventoryLog WHERE SaleID=@done)=2,1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg);
EXEC #Rec 'C-02',N'完成规则',N'重复完成',N'对已完成订单再执行 UPDATE Status=''COMPLETED''',N'错误 51751，流水仍为 2 条',@actual,@ok;

/* C-03～C-07：模拟绕过 usp_CompleteOrder 直接改状态（写入过程用的会话标记），每个用例都在事务中执行并回滚，
   用来证明即使有缺陷的代码设置了标记，完成规则触发器也会按具体原因拒绝。 */
DECLARE @k TABLE(No varchar(10),CaseName nvarchar(60),Qty int,Fake bit,Total decimal(12,2),Rate decimal(5,4) NULL,
                 Discount decimal(12,2),DisableProduct bit,ExpectErr int,ActionText nvarchar(200),ExpText nvarchar(200));
INSERT @k VALUES
 ('C-03',N'没有明细',0,0,0.00,NULL,0.00,0,51750,N'空草稿直接改为已完成',N'错误 51750'),
 ('C-04',N'库存没有扣减',2,0,20.00,NULL,0.00,0,51753,N'有明细但没有扣库存就改为已完成',N'错误 51753'),
 ('C-05',N'订单金额不符',2,1,99.00,NULL,0.00,0,51754,N'已写出库流水，但总额写成 99.00（应为 20.00）',N'错误 51754'),
 ('C-06',N'折扣金额与折扣率不符',2,1,20.00,0.0500,5.00,0,51755,N'折扣率 5%，折扣金额却写 5.00（应为 1.00）',N'错误 51755'),
 ('C-07',N'含停用商品',2,1,20.00,NULL,0.00,1,51752,N'明细中的商品已停用',N'错误 51752');
DECLARE @no varchar(10),@case nvarchar(60),@qty int,@fake bit,@total decimal(12,2),@rate decimal(5,4),@discount decimal(12,2),
        @disable bit,@expect int,@act nvarchar(200),@expText nvarchar(200);
DECLARE kc CURSOR LOCAL FAST_FORWARD FOR SELECT No,CaseName,Qty,Fake,Total,Rate,Discount,DisableProduct,ExpectErr,ActionText,ExpText FROM @k ORDER BY No;
OPEN kc;
FETCH NEXT FROM kc INTO @no,@case,@qty,@fake,@total,@rate,@discount,@disable,@expect,@act,@expText;
WHILE @@FETCH_STATUS=0
BEGIN
    EXEC #NewDraft @R,@qty,@sale OUTPUT;
    SET @err=0; SET @msg=NULL;
    BEGIN TRY
        BEGIN TRAN;
        IF @fake=1 EXEC #FakeSaleOut @sale;
        IF @disable=1 UPDATE dbo.Product SET Status=0 WHERE ProductID=@R;
        EXEC sys.sp_set_session_context @key=N'CampusStoreSaleComplete',@value=@sale;
        UPDATE dbo.SaleOrder SET Status='COMPLETED',TotalAmount=@total,DiscountRate=@rate,DiscountAmount=@discount WHERE SaleID=@sale;
        ROLLBACK;
    END TRY
    BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
    IF XACT_STATE()<>0 ROLLBACK;
    EXEC sys.sp_set_session_context @key=N'CampusStoreSaleComplete',@value=NULL;
    SET @ok=IIF(@err=@expect AND (SELECT Status FROM dbo.SaleOrder WHERE SaleID=@sale)='DRAFT'
                AND (SELECT Status FROM dbo.Product WHERE ProductID=@R)=1,1,0);
    SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；订单仍为 ',(SELECT Status FROM dbo.SaleOrder WHERE SaleID=@sale));
    SET @expText=CONCAT(@expText,N'；订单仍为草稿');
    EXEC #Rec @no,N'完成规则',@case,@act,@expText,@actual,@ok;
    EXEC dbo.CancelSale @sale;
    FETCH NEXT FROM kc INTO @no,@case,@qty,@fake,@total,@rate,@discount,@disable,@expect,@act,@expText;
END;
CLOSE kc; DEALLOCATE kc;

-- C-08 多行：一条 UPDATE 同时完成两张订单，其中一张合格、一张没扣库存，整条语句被拒绝
EXEC #NewDraft @R,1,@sale OUTPUT;
EXEC #NewDraft @R,1,@sale2 OUTPUT;
SET @err=0; SET @msg=NULL;
BEGIN TRY
    BEGIN TRAN;
    EXEC #FakeSaleOut @sale;
    EXEC sys.sp_set_session_context @key=N'CampusStoreSaleComplete',@value=@sale;
    UPDATE dbo.SaleOrder SET Status='COMPLETED',TotalAmount=10.00 WHERE SaleID IN (@sale,@sale2);
    ROLLBACK;
END TRY
BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
IF XACT_STATE()<>0 ROLLBACK;
EXEC sys.sp_set_session_context @key=N'CampusStoreSaleComplete',@value=NULL;
SET @ok=IIF(@err=51753 AND (SELECT COUNT(*) FROM dbo.SaleOrder WHERE SaleID IN (@sale,@sale2) AND Status='DRAFT')=2,1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；两张订单中草稿 ',(SELECT COUNT(*) FROM dbo.SaleOrder WHERE SaleID IN (@sale,@sale2) AND Status='DRAFT'),N' 张');
EXEC #Rec 'C-08',N'完成规则',N'多行同时完成',N'一条 UPDATE 完成两张订单（一张合格、一张没扣库存）',N'错误 51753；两张订单都保持草稿',@actual,@ok;

-- C-09 条件都满足但没有经过结算过程：完成规则通过，状态保护触发器拒绝
SET @err=0; SET @msg=NULL;
BEGIN TRY
    BEGIN TRAN;
    EXEC #FakeSaleOut @sale;
    UPDATE dbo.SaleOrder SET Status='COMPLETED',TotalAmount=10.00 WHERE SaleID=@sale;
    ROLLBACK;
END TRY
BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
IF XACT_STATE()<>0 ROLLBACK;
SET @ok=IIF(@err=51320 AND (SELECT Status FROM dbo.SaleOrder WHERE SaleID=@sale)='DRAFT',1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg);
EXEC #Rec 'C-09',N'完成规则',N'绕过结算过程',N'条件都满足，但没有结算过程的会话标记',N'完成规则通过，tr_SaleOrder_StatusGuard 拒绝（错误 51320）',@actual,@ok;
EXEC dbo.CancelSale @sale;
EXEC dbo.CancelSale @sale2;

PRINT N'订单状态（本脚本创建的订单）：';
SELECT SaleID AS sale_id, SaleNo AS sale_no, Status AS status, TotalAmount AS total_amount,
       DiscountRate AS discount_rate, DiscountAmount AS discount_amount
FROM dbo.SaleOrder WHERE SaleNo LIKE 'T11S%' AND SaleID>=@done ORDER BY SaleID;

/* ================= 窗口查询结果核对 ================= */
DECLARE @today date=CONVERT(date,SYSDATETIME());
DECLARE @first date=(SELECT MIN(CONVERT(date,SaleTime)) FROM dbo.SaleOrder WHERE Status='COMPLETED');

-- W-01 排名：RANK 第 1 名的销售额最大；DENSE_RANK 不跳号；ROW_NUMBER 是 1..n 的唯一序号
SELECT @ok=IIF(MAX(IIF(sales_rank=1,sales_amount,NULL))=MAX(sales_amount)
               AND MAX(dense_sales_rank)=COUNT(DISTINCT sales_amount)
               AND MAX(row_no)=COUNT(*) AND COUNT(DISTINCT row_no)=COUNT(*),1,0),
       @actual=CONCAT(N'商品 ',COUNT(*),N' 件，第 1 名销售额 ',MAX(IIF(sales_rank=1,sales_amount,NULL)),N'，最大销售额 ',MAX(sales_amount),
                      N'，DENSE_RANK 最大 ',MAX(dense_sales_rank),N'，不同销售额 ',COUNT(DISTINCT sales_amount),N' 个')
FROM app.fn_ProductSalesRank('2000-01-01',@today);
EXEC #Rec 'W-01',N'窗口查询',N'排名',N'app.fn_ProductSalesRank（RANK、DENSE_RANK、ROW_NUMBER）',
    N'第 1 名销售额最大；DENSE_RANK 最大值等于不同销售额个数；ROW_NUMBER 为 1..n',@actual,@ok;

-- W-02 累计值：最后一天的累计实收等于区间内全部已完成订单的实收之和
SELECT @ok=IIF(MAX(cumulative_amount)=(SELECT SUM(PayableAmount) FROM dbo.SaleOrder WHERE Status='COMPLETED'
                                        AND SaleTime>=@first AND SaleTime<DATEADD(DAY,1,CONVERT(datetime2(0),@today)))
               AND MAX(IIF(sale_date=@today,cumulative_amount,NULL))=MAX(cumulative_amount),1,0),
       @actual=CONCAT(N'最后一天累计 ',MAX(IIF(sale_date=@today,cumulative_amount,NULL)),N'，实收合计 ',
                      (SELECT SUM(PayableAmount) FROM dbo.SaleOrder WHERE Status='COMPLETED'),N'，共 ',COUNT(*),N' 天')
FROM app.fn_DailySalesTrend(@first,@today);
EXEC #Rec 'W-02',N'窗口查询',N'累计值',N'app.fn_DailySalesTrend：按日期排序的累计实收',N'最后一天的累计实收等于全部已完成订单的实收之和',@actual,@ok;

-- W-03 移动平均：今天的近 3 天平均等于（前天+昨天+今天）/3；第一天只有 1 天
DECLARE @d2 decimal(12,2)=(SELECT COALESCE(SUM(PayableAmount),0) FROM dbo.SaleOrder WHERE Status='COMPLETED' AND CONVERT(date,SaleTime)=DATEADD(DAY,-2,@today));
DECLARE @d1 decimal(12,2)=(SELECT COALESCE(SUM(PayableAmount),0) FROM dbo.SaleOrder WHERE Status='COMPLETED' AND CONVERT(date,SaleTime)=DATEADD(DAY,-1,@today));
DECLARE @d0 decimal(12,2)=(SELECT COALESCE(SUM(PayableAmount),0) FROM dbo.SaleOrder WHERE Status='COMPLETED' AND CONVERT(date,SaleTime)=@today);
SELECT @ok=IIF(MAX(IIF(sale_date=@today,moving_avg_3d,NULL))=CONVERT(decimal(12,2),(@d2+@d1+@d0)/3)
               AND MAX(IIF(sale_date=@today,window_days,NULL))=3
               AND MAX(IIF(sale_date=DATEADD(DAY,-2,@today),window_days,NULL))=1,1,0),
       @actual=CONCAT(N'前天 ',@d2,N'、昨天 ',@d1,N'、今天 ',@d0,N'；今天的近 3 天平均 ',MAX(IIF(sale_date=@today,moving_avg_3d,NULL)),
                      N'（窗口 ',MAX(IIF(sale_date=@today,window_days,NULL)),N' 天），区间第一天窗口 ',MAX(IIF(sale_date=DATEADD(DAY,-2,@today),window_days,NULL)),N' 天')
FROM app.fn_DailySalesTrend(DATEADD(DAY,-2,@today),@today);
EXEC #Rec 'W-03',N'窗口查询',N'移动平均',N'app.fn_DailySalesTrend(前天, 今天)：ROWS 2 PRECEDING',
    N'今天的值等于三天实收的平均；区间第一天窗口只有 1 天',@actual,@ok;

SET @ok=IIF(@@TRANCOUNT=0,1,0); SET @actual=CONCAT(N'@@TRANCOUNT=',@@TRANCOUNT);
EXEC #Rec 'END',N'收尾',N'没有遗留事务',N'检查 @@TRANCOUNT',N'0',@actual,@ok;

SELECT CaseNo AS [编号], Area AS [对象], CaseName AS [用例], Action AS [操作], Expected AS [预期结果],
       Actual AS [实际结果], IIF(Passed=1,N'通过',N'未通过') AS [结论]
FROM #Result ORDER BY Seq;
SELECT N'第十一周触发器与窗口查询验证' AS [项目], COUNT(*) AS [检查项], SUM(CONVERT(int,Passed)) AS [通过],
       COUNT(*)-SUM(CONVERT(int,Passed)) AS [失败]
FROM #Result;
GO
