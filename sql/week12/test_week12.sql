/* 第十二周验证：订单完成事务、补货入库事务的正常提交、中途失败回滚、重复调用和业务规则拒绝。
   只在随机测试库（CampusStoreDB_W7_Test_xxx）运行：python -m tools.verify_week12 会新建测试库、部署全部脚本、
   依次运行本脚本并把输出保存到 results/week10-12/，最后删除测试库。
   每个用例开始前把测试商品 P、Q 的库存重置到已知值（通过 dbo.usp_AdjustInventory），再新建订单或补货单；
   每个用例都同时核对库存、库存流水、库存审计和单据本身，不只看报错。 */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET XACT_ABORT OFF;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]Test[_]%'
    THROW 51700,N'验证脚本只在随机测试库运行，请使用 python -m tools.verify_week12',1;
IF @@TRANCOUNT<>0 THROW 51700,N'请在没有外层事务的连接上运行',1;
IF OBJECT_ID(N'tempdb..#Result') IS NOT NULL DROP TABLE #Result;
CREATE TABLE #Result(Seq int IDENTITY PRIMARY KEY, CaseNo varchar(10), Area nvarchar(20), CaseName nvarchar(60),
                     Initial nvarchar(300), Action nvarchar(300), Expected nvarchar(400), Actual nvarchar(800), Passed bit);
IF OBJECT_ID(N'tempdb..#Rec') IS NOT NULL DROP PROCEDURE #Rec;
IF OBJECT_ID(N'tempdb..#NewProduct') IS NOT NULL DROP PROCEDURE #NewProduct;
IF OBJECT_ID(N'tempdb..#SetStock') IS NOT NULL DROP PROCEDURE #SetStock;
IF OBJECT_ID(N'tempdb..#State') IS NOT NULL DROP PROCEDURE #State;
IF OBJECT_ID(N'tempdb..#NewOrder') IS NOT NULL DROP PROCEDURE #NewOrder;
IF OBJECT_ID(N'tempdb..#NewRestock') IS NOT NULL DROP PROCEDURE #NewRestock;
GO
CREATE PROCEDURE #Rec @No varchar(10),@Area nvarchar(20),@Case nvarchar(60),@Init nvarchar(300),
    @Act nvarchar(300),@Exp nvarchar(400),@Actual nvarchar(800),@Ok bit
AS INSERT #Result(CaseNo,Area,CaseName,Initial,Action,Expected,Actual,Passed)
   VALUES(@No,@Area,@Case,@Init,@Act,@Exp,@Actual,ISNULL(@Ok,0));
GO
CREATE PROCEDURE #NewProduct @Letter char(1),@Tag varchar(8),@Name nvarchar(100),@Price decimal(10,2),
    @CategoryCode varchar(20),@ProductID bigint OUTPUT,@SKU varchar(30) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @SKU='T'+@Letter+@Tag;
    INSERT dbo.Product(SKU,ProductName,CategoryID,Unit,SalePrice)
    SELECT @SKU,@Name,CategoryID,N'件',@Price FROM dbo.Category WHERE CategoryCode=@CategoryCode;
    SET @ProductID=SCOPE_IDENTITY();
    UPDATE dbo.Inventory SET MinQuantity=5 WHERE ProductID=@ProductID;
END;
GO
-- 重置库存：差多少调多少，走正式的库存调整过程（会留下“测试前重置库存”的流水和审计）。
CREATE PROCEDURE #SetStock @ProductID bigint,@Quantity int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sku varchar(30),@change int;
    SELECT @sku=p.SKU,@change=@Quantity-i.Quantity FROM dbo.Product p JOIN dbo.Inventory i ON i.ProductID=p.ProductID
    WHERE p.ProductID=@ProductID;
    IF @change<>0
        EXEC dbo.usp_AdjustInventory @ProductCode=@sku,@ChangeQuantity=@change,@Reason=N'测试前重置库存',
             @EmployeeNo='E001',@Quiet=1;
END;
GO
-- 当前状态：两件商品的库存、流水条数、审计条数，用来比较操作前后是否完全一致。
CREATE PROCEDURE #State @P bigint,@Q bigint,@Text nvarchar(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @Text=CONCAT(N'库存 P=',(SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P),
        N' Q=',(SELECT Quantity FROM dbo.Inventory WHERE ProductID=@Q),
        N'；流水 P=',(SELECT COUNT(*) FROM dbo.InventoryLog WHERE ProductID=@P),
        N' Q=',(SELECT COUNT(*) FROM dbo.InventoryLog WHERE ProductID=@Q),
        N'；审计 P=',(SELECT COUNT(*) FROM dbo.InventoryAudit WHERE ProductID=@P),
        N' Q=',(SELECT COUNT(*) FROM dbo.InventoryAudit WHERE ProductID=@Q));
END;
GO
-- 新建待完成订单：@Member=1 时挂到顾客账号 customer 名下（会员订单，已提交）。数量为 0 的商品不加明细。
CREATE PROCEDURE #NewOrder @Member bit,@P bigint,@PQ int,@Q bigint,@QQ int,@SaleID bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @no varchar(30)='T12S'+LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),20);
    INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod)
    SELECT @no,EmployeeID,'CASH' FROM dbo.Employee WHERE EmployeeNo='E003';
    SET @SaleID=SCOPE_IDENTITY();
    IF @PQ>0 INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
             SELECT @SaleID,ProductID,@PQ,SalePrice FROM dbo.Product WHERE ProductID=@P;
    IF @QQ>0 INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice)
             SELECT @SaleID,ProductID,@QQ,SalePrice FROM dbo.Product WHERE ProductID=@Q;
    IF @Member=1 INSERT app.SaleOwner(SaleID,UserID,SubmittedAt)
                 SELECT @SaleID,UserID,SYSDATETIME() FROM app.AppUser WHERE Username='customer';
END;
GO
-- 新建人工填写的待入库补货单：供应商 S001、采购员 E002，P 进价 2.00、Q 进价 3.00。
CREATE PROCEDURE #NewRestock @P bigint,@PQ int,@Q bigint,@QQ int,@PurchaseID bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @no varchar(30)='T12R'+LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),20);
    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID)
    SELECT @no,s.SupplierID,e.EmployeeID FROM dbo.Supplier s CROSS JOIN dbo.Employee e
    WHERE s.SupplierCode='S001' AND e.EmployeeNo='E002';
    SET @PurchaseID=SCOPE_IDENTITY();
    IF @PQ>0 INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost) VALUES(@PurchaseID,@P,@PQ,2.00);
    IF @QQ>0 INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost) VALUES(@PurchaseID,@Q,@QQ,3.00);
END;
GO
DECLARE @tag varchar(8)=LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),8);
DECLARE @P bigint,@Q bigint,@skuP varchar(30),@skuQ varchar(30);
DECLARE @sale bigint,@purchase bigint,@err int,@msg nvarchar(400),@ok bit;
DECLARE @before nvarchar(400),@after nvarchar(400),@actual nvarchar(800),@doc nvarchar(300);
EXEC #NewProduct 'P',@tag,N'测试商品P',10.00,'DRINK',@P OUTPUT,@skuP OUTPUT;
EXEC #NewProduct 'Q',@tag,N'测试商品Q',25.00,'SNACK',@Q OUTPUT,@skuQ OUTPUT;

PRINT N'初始数据：测试商品 P（售价 10.00）、Q（售价 25.00），每个用例前把库存重置为 P=10、Q=5';
PRINT N'表之间的关系：SaleOrder 1—N SaleItem N—1 Product 1—1 Inventory 1—N InventoryLog / InventoryAudit；'
    + N'PurchaseOrder（补货单）1—N PurchaseItem（补货明细）N—1 Product';
SELECT p.ProductID AS product_id, p.SKU AS sku, p.ProductName AS product_name, p.SalePrice AS sale_price,
       i.Quantity AS quantity, i.MinQuantity AS min_quantity
FROM dbo.Product p JOIN dbo.Inventory i ON i.ProductID=p.ProductID WHERE p.ProductID IN (@P,@Q);

/* ================= 订单完成事务 ================= */
-- O-01 正常提交
EXEC #SetStock @P,10; EXEC #SetStock @Q,5;
EXEC #NewOrder 1,@P,3,@Q,2,@sale OUTPUT;
EXEC #State @P,@Q,@before OUTPUT;
SET @err=0; SET @msg=NULL;
PRINT N'O-01 正常提交的返回结果：';
BEGIN TRY EXEC dbo.usp_CompleteOrder @SaleID=@sale; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC #State @P,@Q,@after OUTPUT;
SELECT @ok=IIF(@err=0 AND so.Status='COMPLETED' AND so.TotalAmount=80.00 AND so.DiscountRate=0.0500
               AND so.DiscountAmount=4.00 AND so.PayableAmount=76.00
               AND (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P)=7
               AND (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@Q)=3
               AND (SELECT COUNT(*) FROM dbo.InventoryLog WHERE SaleID=@sale AND ChangeType='SALE_OUT')=2
               AND (SELECT COUNT(*) FROM dbo.InventoryAudit WHERE ProductID IN (@P,@Q) AND OperationType='DECREASE'
                    AND OperatorEmployeeID=so.EmployeeID)>=2,1,0),
       @doc=CONCAT(N'订单 ',so.Status,N'，总额 ',so.TotalAmount,N'，折扣率 ',so.DiscountRate,N'，优惠 ',so.DiscountAmount,N'，应付 ',so.PayableAmount)
FROM dbo.SaleOrder so WHERE so.SaleID=@sale;
SET @actual=CONCAT(IIF(@err=0,N'成功',CONCAT(N'错误 ',@err,N' ',@msg)),N'；',@doc,N'；操作前 ',@before,N' → 操作后 ',@after);
EXEC #Rec 'O-01',N'订单完成',N'正常提交',N'P=10、Q=5；会员订单 P×3、Q×2',N'EXEC dbo.usp_CompleteOrder',
    N'成功；P=7、Q=3，新增 2 条销售出库流水和 2 条减少审计；总额 80.00，会员 95 折优惠 4.00，应付 76.00，已完成',@actual,@ok;

-- O-02 重复调用同一订单
EXEC #State @P,@Q,@before OUTPUT;
SET @err=0; SET @msg=NULL;
BEGIN TRY EXEC dbo.usp_CompleteOrder @SaleID=@sale,@Quiet=1; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC #State @P,@Q,@after OUTPUT;
SET @ok=IIF(@err=51731 AND @before=@after
            AND (SELECT COUNT(*) FROM dbo.InventoryLog WHERE SaleID=@sale)=2,1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；操作前 ',@before,N' → 操作后 ',@after);
EXEC #Rec 'O-02',N'订单完成',N'重复调用',N'O-01 已完成的订单',N'再次 EXEC dbo.usp_CompleteOrder',
    N'错误 51731；库存、流水、审计都不变（不重复扣减）',@actual,@ok;

-- O-03 中途失败回滚：库存已扣、流水已写之后、订单完成之前主动 THROW
EXEC #SetStock @P,10; EXEC #SetStock @Q,5;
EXEC #NewOrder 1,@P,3,@Q,2,@sale OUTPUT;
EXEC #State @P,@Q,@before OUTPUT;
SET @err=0; SET @msg=NULL;
BEGIN TRY EXEC dbo.usp_CompleteOrder @SaleID=@sale,@FailAfterStock=1,@Quiet=1; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC #State @P,@Q,@after OUTPUT;
SELECT @ok=IIF(@err=51799 AND @before=@after AND so.Status='DRAFT' AND so.TotalAmount=0 AND so.DiscountRate IS NULL
               AND NOT EXISTS(SELECT 1 FROM dbo.InventoryLog WHERE SaleID=@sale)
               AND (SELECT COUNT(*) FROM dbo.SaleItem WHERE SaleID=@sale)=2
               AND EXISTS(SELECT 1 FROM dbo.SaleItem WHERE SaleID=@sale AND ProductID=@P AND Quantity=3)
               AND EXISTS(SELECT 1 FROM dbo.SaleItem WHERE SaleID=@sale AND ProductID=@Q AND Quantity=2)
               AND EXISTS(SELECT 1 FROM app.SaleOwner WHERE SaleID=@sale)
               AND @@TRANCOUNT=0,1,0),
       @doc=CONCAT(N'订单 ',so.Status,N'，总额 ',so.TotalAmount,N'，明细 ',(SELECT COUNT(*) FROM dbo.SaleItem WHERE SaleID=@sale),
                   N' 条，归属记录 ',(SELECT COUNT(*) FROM app.SaleOwner WHERE SaleID=@sale),
                   N' 条，该单流水 ',(SELECT COUNT(*) FROM dbo.InventoryLog WHERE SaleID=@sale),N' 条')
FROM dbo.SaleOrder so WHERE so.SaleID=@sale;
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；',@doc,N'；操作前 ',@before,N' → 操作后 ',@after,N'；@@TRANCOUNT=',@@TRANCOUNT);
EXEC #Rec 'O-03',N'订单完成',N'中途失败回滚',N'P=10、Q=5；会员订单 P×3、Q×2',N'EXEC dbo.usp_CompleteOrder @FailAfterStock=1',
    N'错误 51799；已扣的库存、已写的流水和审计全部撤销，订单仍是草稿、金额未写入',@actual,@ok;

-- O-04 库存不足：P 足够、Q 不够，P 的扣减也必须撤销
EXEC #State @P,@Q,@before OUTPUT;
EXEC #NewOrder 0,@P,3,@Q,6,@sale OUTPUT;
EXEC #State @P,@Q,@before OUTPUT;
SET @err=0; SET @msg=NULL;
BEGIN TRY EXEC dbo.usp_CompleteOrder @SaleID=@sale,@Quiet=1; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC #State @P,@Q,@after OUTPUT;
SET @ok=IIF(@err=51305 AND @before=@after AND (SELECT Status FROM dbo.SaleOrder WHERE SaleID=@sale)='DRAFT',1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；操作前 ',@before,N' → 操作后 ',@after);
EXEC #Rec 'O-04',N'订单完成',N'库存不足拒绝',N'P=10、Q=5；订单 P×3、Q×6',N'EXEC dbo.usp_CompleteOrder',
    N'错误 51305；P 也不扣减，库存、流水、审计不变，订单仍是草稿',@actual,@ok;

-- O-05 订单不存在
SET @err=0; SET @msg=NULL;
BEGIN TRY DECLARE @missingSale bigint=(SELECT MAX(SaleID)+1000 FROM dbo.SaleOrder);
          EXEC dbo.usp_CompleteOrder @SaleID=@missingSale,@Quiet=1; END TRY
BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg);
SET @ok=IIF(@err=51730,1,0);
EXEC #Rec 'O-05',N'订单完成',N'订单不存在',N'最大订单号 + 1000',N'EXEC dbo.usp_CompleteOrder',N'错误 51730 订单不存在',@actual,@ok;

-- O-06 没有明细
EXEC #NewOrder 0,@P,0,@Q,0,@sale OUTPUT;
EXEC #State @P,@Q,@before OUTPUT;
SET @err=0; SET @msg=NULL;
BEGIN TRY EXEC dbo.usp_CompleteOrder @SaleID=@sale,@Quiet=1; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC #State @P,@Q,@after OUTPUT;
SET @ok=IIF(@err=51302 AND @before=@after AND (SELECT Status FROM dbo.SaleOrder WHERE SaleID=@sale)='DRAFT',1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；订单 ',(SELECT Status FROM dbo.SaleOrder WHERE SaleID=@sale));
EXEC #Rec 'O-06',N'订单完成',N'无明细拒绝',N'没有明细的草稿订单',N'EXEC dbo.usp_CompleteOrder',N'错误 51302；订单仍是草稿',@actual,@ok;

-- O-07 已取消的订单
EXEC #NewOrder 0,@P,1,@Q,0,@sale OUTPUT;
EXEC dbo.CancelSale @sale;
SET @err=0; SET @msg=NULL;
BEGIN TRY EXEC dbo.usp_CompleteOrder @SaleID=@sale,@Quiet=1; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
SET @ok=IIF(@err=51732 AND (SELECT Status FROM dbo.SaleOrder WHERE SaleID=@sale)='CANCELLED',1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；订单 ',(SELECT Status FROM dbo.SaleOrder WHERE SaleID=@sale));
EXEC #Rec 'O-07',N'订单完成',N'已取消拒绝',N'已取消的订单 P×1',N'EXEC dbo.usp_CompleteOrder',N'错误 51732；订单仍是已取消',@actual,@ok;

-- O-08 非会员满 100 元
EXEC #SetStock @P,10; EXEC #SetStock @Q,5;
EXEC #NewOrder 0,@P,10,@Q,0,@sale OUTPUT;
SET @err=0; SET @msg=NULL;
BEGIN TRY EXEC dbo.usp_CompleteOrder @SaleID=@sale,@Quiet=1; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
SELECT @ok=IIF(@err=0 AND Status='COMPLETED' AND TotalAmount=100.00 AND DiscountRate=0.0500 AND DiscountAmount=5.00
               AND PayableAmount=95.00 AND (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P)=0,1,0),
       @doc=CONCAT(N'订单 ',Status,N'，总额 ',TotalAmount,N'，折扣率 ',DiscountRate,N'，优惠 ',DiscountAmount,N'，应付 ',PayableAmount,
                   N'；P 库存 ',(SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P))
FROM dbo.SaleOrder WHERE SaleID=@sale;
SET @actual=CONCAT(IIF(@err=0,N'成功',CONCAT(N'错误 ',@err,N' ',@msg)),N'；',@doc);
EXEC #Rec 'O-08',N'订单完成',N'非会员满 100 元',N'P=10；店员开的散客订单 P×10（100.00 元）',N'EXEC dbo.usp_CompleteOrder',
    N'成功；满 100 元减 5%，优惠 5.00，应付 95.00；P 库存扣到 0（库存正好等于需求量也能扣）',@actual,@ok;

-- O-09 在外层事务中调用：过程只建保存点，外层回滚后订单和库存都恢复
EXEC #SetStock @P,10; EXEC #SetStock @Q,5;
EXEC #NewOrder 0,@P,2,@Q,0,@sale OUTPUT;
EXEC #State @P,@Q,@before OUTPUT;
SET @err=0; SET @msg=NULL;
BEGIN TRY
    BEGIN TRAN;
    EXEC dbo.usp_CompleteOrder @SaleID=@sale,@Quiet=1;
    SET @doc=CONCAT(N'外层事务内：订单 ',(SELECT Status FROM dbo.SaleOrder WHERE SaleID=@sale),
                    N'，P 库存 ',(SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P),N'，@@TRANCOUNT=',@@TRANCOUNT);
    ROLLBACK;
END TRY
BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK; END CATCH;
EXEC #State @P,@Q,@after OUTPUT;
SET @ok=IIF(@err=0 AND @before=@after AND (SELECT Status FROM dbo.SaleOrder WHERE SaleID=@sale)='DRAFT' AND @@TRANCOUNT=0,1,0);
SET @actual=CONCAT(@doc,N'；外层 ROLLBACK 后：订单 ',(SELECT Status FROM dbo.SaleOrder WHERE SaleID=@sale),N'，',@after);
EXEC #Rec 'O-09',N'订单完成',N'外层事务负责提交',N'P=10；订单 P×2',N'BEGIN TRAN → EXEC dbo.usp_CompleteOrder → ROLLBACK',
    N'过程内部看到已完成、P=8，但过程没有自行提交；外层回滚后订单回到草稿，库存、流水、审计恢复',@actual,@ok;

/* ================= 补货入库事务 ================= */
-- R-01 正常提交
EXEC #SetStock @P,10; EXEC #SetStock @Q,5;
EXEC #NewRestock @P,20,@Q,10,@purchase OUTPUT;
EXEC #State @P,@Q,@before OUTPUT;
SET @err=0; SET @msg=NULL;
PRINT N'R-01 正常提交的返回结果：';
BEGIN TRY EXEC dbo.usp_ReceiveRestock @PurchaseID=@purchase; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC #State @P,@Q,@after OUTPUT;
SELECT @ok=IIF(@err=0 AND Status='RECEIVED' AND ReceivedTime IS NOT NULL AND TotalAmount=70.00
               AND (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P)=30
               AND (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@Q)=15
               AND (SELECT COUNT(*) FROM dbo.InventoryLog WHERE PurchaseID=@purchase AND ChangeType='PURCHASE_IN')=2,1,0),
       @doc=CONCAT(N'补货单 ',Status,N'，金额 ',TotalAmount,N'，入库时间',IIF(ReceivedTime IS NULL,N'为空',N'已写入'))
FROM dbo.PurchaseOrder WHERE PurchaseID=@purchase;
SET @actual=CONCAT(IIF(@err=0,N'成功',CONCAT(N'错误 ',@err,N' ',@msg)),N'；',@doc,N'；操作前 ',@before,N' → 操作后 ',@after);
EXEC #Rec 'R-01',N'补货入库',N'正常提交',N'P=10、Q=5；人工补货单 P×20（进价 2.00）、Q×10（进价 3.00）',N'EXEC dbo.usp_ReceiveRestock',
    N'成功；P=30、Q=15，2 条采购入库流水（记录补货单编号），补货单已入库、金额 70.00、入库时间已写入',@actual,@ok;
PRINT N'R-01 补货单编号—商品—数量的对应关系：';
SELECT po.PurchaseNo AS purchase_no, p.SKU AS sku, pi.Quantity AS quantity, pi.UnitCost AS unit_cost,
       l.ChangeQuantity AS log_change, l.BeforeQuantity AS log_before, l.AfterQuantity AS log_after
FROM dbo.PurchaseOrder po JOIN dbo.PurchaseItem pi ON pi.PurchaseID=po.PurchaseID
JOIN dbo.Product p ON p.ProductID=pi.ProductID
LEFT JOIN dbo.InventoryLog l ON l.PurchaseID=po.PurchaseID AND l.ProductID=pi.ProductID
WHERE po.PurchaseID=@purchase ORDER BY p.SKU;

-- R-02 重复调用
EXEC #State @P,@Q,@before OUTPUT;
SET @err=0; SET @msg=NULL;
BEGIN TRY EXEC dbo.usp_ReceiveRestock @PurchaseID=@purchase,@Quiet=1; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC #State @P,@Q,@after OUTPUT;
SET @ok=IIF(@err=51741 AND @before=@after AND (SELECT COUNT(*) FROM dbo.InventoryLog WHERE PurchaseID=@purchase)=2,1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；操作前 ',@before,N' → 操作后 ',@after);
EXEC #Rec 'R-02',N'补货入库',N'重复调用',N'R-01 已入库的补货单',N'再次 EXEC dbo.usp_ReceiveRestock',
    N'错误 51741；库存不再增加，流水、审计不变',@actual,@ok;

-- R-03 中途失败回滚：库存已加、流水已写之后、单据完成之前主动 THROW
EXEC #SetStock @P,10; EXEC #SetStock @Q,5;
EXEC #NewRestock @P,20,@Q,10,@purchase OUTPUT;
EXEC #State @P,@Q,@before OUTPUT;
SET @err=0; SET @msg=NULL;
BEGIN TRY EXEC dbo.usp_ReceiveRestock @PurchaseID=@purchase,@FailAfterStock=1,@Quiet=1; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC #State @P,@Q,@after OUTPUT;
SELECT @ok=IIF(@err=51799 AND @before=@after AND Status='DRAFT' AND ReceivedTime IS NULL AND TotalAmount=0
               AND NOT EXISTS(SELECT 1 FROM dbo.InventoryLog WHERE PurchaseID=@purchase)
               AND (SELECT COUNT(*) FROM dbo.PurchaseItem WHERE PurchaseID=@purchase)=2
               AND EXISTS(SELECT 1 FROM dbo.PurchaseItem WHERE PurchaseID=@purchase AND ProductID=@P AND Quantity=20 AND UnitCost=2.00)
               AND EXISTS(SELECT 1 FROM dbo.PurchaseItem WHERE PurchaseID=@purchase AND ProductID=@Q AND Quantity=10 AND UnitCost=3.00)
               AND @@TRANCOUNT=0,1,0),
       @doc=CONCAT(N'补货单 ',Status,N'，入库时间',IIF(ReceivedTime IS NULL,N'为空',N'已写入'),N'，该单流水 ',
                   (SELECT COUNT(*) FROM dbo.InventoryLog WHERE PurchaseID=@purchase),N' 条，明细 ',
                   (SELECT COUNT(*) FROM dbo.PurchaseItem WHERE PurchaseID=@purchase),N' 条')
FROM dbo.PurchaseOrder WHERE PurchaseID=@purchase;
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；',@doc,N'；操作前 ',@before,N' → 操作后 ',@after);
EXEC #Rec 'R-03',N'补货入库',N'中途失败回滚',N'P=10、Q=5；补货单 P×20、Q×10',N'EXEC dbo.usp_ReceiveRestock @FailAfterStock=1',
    N'错误 51799；已加的库存、已写的流水和审计全部撤销，补货单仍待入库、入库时间为空',@actual,@ok;

-- R-04 补货量非正数：把已有明细改为 0，确保命中数量检查约束而不是联合主键。
SET @err=0; SET @msg=NULL;
BEGIN TRY UPDATE dbo.PurchaseItem SET Quantity=0 WHERE PurchaseID=@purchase AND ProductID=@P; END TRY
BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
DECLARE @err2 int=0;
BEGIN TRY EXEC app.WritePurchaseItem @PurchaseID=@purchase,@ProductID=@Q,@Quantity=-5,@UnitCost=3.00; END TRY
BEGIN CATCH SET @err2=ERROR_NUMBER(); END CATCH;
SET @ok=IIF(@err=547 AND @err2=51805 AND (SELECT COUNT(*) FROM dbo.PurchaseItem WHERE PurchaseID=@purchase)=2
            AND (SELECT Quantity FROM dbo.PurchaseItem WHERE PurchaseID=@purchase AND ProductID=@Q)=10,1,0);
SET @actual=CONCAT(N'直接写数量 0：错误 ',@err,N'；经过程写数量 -5：错误 ',@err2,N'；补货单明细仍为 ',
                   (SELECT COUNT(*) FROM dbo.PurchaseItem WHERE PurchaseID=@purchase),N' 行');
EXEC #Rec 'R-04',N'补货入库',N'补货量非正数拒绝',N'R-03 的待入库补货单',N'写入数量 0 和 -5 的补货明细',
    N'数量 0 被检查约束拒绝（错误 547），数量 -5 被过程拒绝（错误 51805），明细不变',@actual,@ok;

-- R-05 补货单不存在
SET @err=0; SET @msg=NULL;
BEGIN TRY DECLARE @missingPurchase bigint=(SELECT MAX(PurchaseID)+1000 FROM dbo.PurchaseOrder);
          EXEC dbo.usp_ReceiveRestock @PurchaseID=@missingPurchase,@Quiet=1; END TRY
BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
SET @ok=IIF(@err=51740,1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg);
EXEC #Rec 'R-05',N'补货入库',N'补货单不存在',N'最大补货单号 + 1000',N'EXEC dbo.usp_ReceiveRestock',N'错误 51740',@actual,@ok;

-- R-06 没有明细
EXEC #NewRestock @P,0,@Q,0,@purchase OUTPUT;
SET @err=0; SET @msg=NULL;
BEGIN TRY EXEC dbo.usp_ReceiveRestock @PurchaseID=@purchase,@Quiet=1; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
SET @ok=IIF(@err=51201 AND (SELECT Status FROM dbo.PurchaseOrder WHERE PurchaseID=@purchase)='DRAFT',1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；补货单 ',(SELECT Status FROM dbo.PurchaseOrder WHERE PurchaseID=@purchase));
EXEC #Rec 'R-06',N'补货入库',N'无明细拒绝',N'没有明细的补货单',N'EXEC dbo.usp_ReceiveRestock',N'错误 51201；补货单仍待入库',@actual,@ok;

-- R-07 已取消
EXEC #NewRestock @P,5,@Q,0,@purchase OUTPUT;
EXEC dbo.CancelPurchase @purchase;
SET @err=0; SET @msg=NULL;
BEGIN TRY EXEC dbo.usp_ReceiveRestock @PurchaseID=@purchase,@Quiet=1; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
SET @ok=IIF(@err=51742 AND (SELECT Status FROM dbo.PurchaseOrder WHERE PurchaseID=@purchase)='CANCELLED',1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg);
EXEC #Rec 'R-07',N'补货入库',N'已取消拒绝',N'已取消的补货单 P×5',N'EXEC dbo.usp_ReceiveRestock',N'错误 51742；补货单仍是已取消',@actual,@ok;

-- R-08 含停用商品
EXEC #NewRestock @P,5,@Q,5,@purchase OUTPUT;
UPDATE dbo.Product SET Status=0 WHERE ProductID=@Q;
EXEC #State @P,@Q,@before OUTPUT;
SET @err=0; SET @msg=NULL;
BEGIN TRY EXEC dbo.usp_ReceiveRestock @PurchaseID=@purchase,@Quiet=1; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC #State @P,@Q,@after OUTPUT;
UPDATE dbo.Product SET Status=1 WHERE ProductID=@Q;
SET @ok=IIF(@err=51744 AND @before=@after AND (SELECT Status FROM dbo.PurchaseOrder WHERE PurchaseID=@purchase)='DRAFT',1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；操作前 ',@before,N' → 操作后 ',@after);
EXEC #Rec 'R-08',N'补货入库',N'含停用商品拒绝',N'补货单 P×5、Q×5，Q 已停用',N'EXEC dbo.usp_ReceiveRestock',
    N'错误 51744；P 也不入库，库存、流水、审计不变',@actual,@ok;

-- 结束检查
SET @ok=IIF(@@TRANCOUNT=0,1,0);
SET @actual=CONCAT(N'@@TRANCOUNT=',@@TRANCOUNT);
EXEC #Rec 'END',N'收尾',N'没有遗留事务',N'—',N'检查 @@TRANCOUNT',N'0',@actual,@ok;

SELECT CaseNo AS [编号], Area AS [业务], CaseName AS [用例], Initial AS [初始数据], Action AS [操作],
       Expected AS [预期结果], Actual AS [实际结果], IIF(Passed=1,N'通过',N'未通过') AS [结论]
FROM #Result ORDER BY Seq;
SELECT N'第十二周事务验证' AS [项目], COUNT(*) AS [检查项], SUM(CONVERT(int,Passed)) AS [通过],
       COUNT(*)-SUM(CONVERT(int,Passed)) AS [失败]
FROM #Result;
GO
