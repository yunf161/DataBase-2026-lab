/* 第十周验证：销售统计过程、库存调整过程、补货量函数、销售汇总表值函数、折扣函数和补货选择过程。
   每个用例记录：输入参数、预期结果、实际结果（成功结果或错误号与提示）、是否通过；
   失败用例同时核对库存、流水、审计和单据没有写入不完整数据。
   只在随机测试库运行：python -m tools.verify_week12。
   过程与函数的区别：过程可以修改数据、控制事务、用 THROW 报错，用 EXEC 调用；
   函数只做计算或查询，不能修改数据也不能 THROW，非法输入返回 NULL，可以写在 SELECT / WHERE / JOIN 中。 */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET XACT_ABORT OFF;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]Test[_]%'
    THROW 51700,N'验证脚本只在随机测试库运行，请使用 python -m tools.verify_week12',1;
IF @@TRANCOUNT<>0 THROW 51700,N'请在没有外层事务的连接上运行',1;
IF OBJECT_ID(N'tempdb..#Result') IS NOT NULL DROP TABLE #Result;
CREATE TABLE #Result(Seq int IDENTITY PRIMARY KEY, CaseNo varchar(10), Area nvarchar(20), CaseName nvarchar(60),
                     Input nvarchar(300), Expected nvarchar(400), Actual nvarchar(800), Passed bit);
IF OBJECT_ID(N'tempdb..#Rec') IS NOT NULL DROP PROCEDURE #Rec;
IF OBJECT_ID(N'tempdb..#State') IS NOT NULL DROP PROCEDURE #State;
GO
CREATE PROCEDURE #Rec @No varchar(10),@Area nvarchar(20),@Case nvarchar(60),@Input nvarchar(300),
    @Exp nvarchar(400),@Actual nvarchar(800),@Ok bit
AS INSERT #Result(CaseNo,Area,CaseName,Input,Expected,Actual,Passed) VALUES(@No,@Area,@Case,@Input,@Exp,@Actual,ISNULL(@Ok,0));
GO
CREATE PROCEDURE #State @P bigint,@Text nvarchar(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @Text=CONCAT(N'库存 ',(SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P),
        N'；流水 ',(SELECT COUNT(*) FROM dbo.InventoryLog WHERE ProductID=@P),N' 条',
        N'；审计 ',(SELECT COUNT(*) FROM dbo.InventoryAudit WHERE ProductID=@P),N' 条');
END;
GO
DECLARE @tag varchar(8)=LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),8);
DECLARE @P bigint,@Q bigint,@skuP varchar(30)='TP'+@tag,@skuQ varchar(30)='TQ'+@tag;
DECLARE @sale bigint,@purchase bigint,@err int,@msg nvarchar(400),@ok bit,@n int,@n2 int;
DECLARE @before nvarchar(400),@after nvarchar(400),@actual nvarchar(800);
DECLARE @today date=CONVERT(date,SYSDATETIME());
DECLARE @int int,@rate decimal(5,4),@amount decimal(12,2);

INSERT dbo.Product(SKU,ProductName,CategoryID,Unit,SalePrice)
SELECT @skuP,N'测试商品P',CategoryID,N'件',10.00 FROM dbo.Category WHERE CategoryCode='DRINK';
SET @P=SCOPE_IDENTITY();
INSERT dbo.Product(SKU,ProductName,CategoryID,Unit,SalePrice)
SELECT @skuQ,N'测试商品Q',CategoryID,N'件',25.00 FROM dbo.Category WHERE CategoryCode='SNACK';
SET @Q=SCOPE_IDENTITY();
UPDATE dbo.Inventory SET MinQuantity=10 WHERE ProductID IN (@P,@Q);

/* ================= 库存调整过程 dbo.usp_AdjustInventory ================= */
EXEC #State @P,@before OUTPUT;
SET @err=0; SET @msg=NULL;
PRINT N'A-01 盘盈的返回结果：';
BEGIN TRY EXEC dbo.usp_AdjustInventory @ProductCode=@skuP,@ChangeQuantity=20,@Reason=N'到货清点',@EmployeeNo='E001'; END TRY
BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC #State @P,@after OUTPUT;
SET @ok=IIF(@err=0 AND (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P)=20
    AND EXISTS(SELECT 1 FROM dbo.InventoryLog l JOIN dbo.Employee e ON e.EmployeeID=l.EmployeeID
               WHERE l.ProductID=@P AND l.ChangeType='STOCKTAKE_IN' AND l.ChangeQuantity=20 AND l.BeforeQuantity=0
                 AND l.AfterQuantity=20 AND l.Remark=N'到货清点' AND e.EmployeeNo='E001'),1,0);
SET @actual=CONCAT(IIF(@err=0,N'成功',CONCAT(N'错误 ',@err,N' ',@msg)),N'；操作前 ',@before,N' → 操作后 ',@after);
EXEC #Rec 'A-01',N'库存调整',N'盘盈（正常）',N'P，+20，到货清点，E001',N'成功；库存 0→20，写入 1 条盘盈流水（原因、员工 E001）和 1 条审计',@actual,@ok;

EXEC #State @P,@before OUTPUT;
SET @err=0; SET @msg=NULL;
BEGIN TRY EXEC dbo.usp_AdjustInventory @ProductCode=@skuP,@ChangeQuantity=-5,@Reason=N'破损',@EmployeeNo='E001',@Quiet=1; END TRY
BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC #State @P,@after OUTPUT;
SET @ok=IIF(@err=0 AND (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P)=15
    AND EXISTS(SELECT 1 FROM dbo.InventoryLog WHERE ProductID=@P AND ChangeType='STOCKTAKE_OUT' AND ChangeQuantity=-5 AND AfterQuantity=15),1,0);
SET @actual=CONCAT(IIF(@err=0,N'成功',CONCAT(N'错误 ',@err,N' ',@msg)),N'；操作前 ',@before,N' → 操作后 ',@after);
EXEC #Rec 'A-02',N'库存调整',N'盘亏（正常）',N'P，-5，破损，E001',N'成功；库存 20→15，写入 1 条盘亏流水',@actual,@ok;

-- 以下失败用例：库存、流水、审计都必须不变
DECLARE @cases TABLE(No varchar(10),CaseName nvarchar(60),Code varchar(30),Change int NULL,Reason nvarchar(50) NULL,
                     Emp varchar(20) NULL,ExpectErr int,InputText nvarchar(200));
INSERT @cases VALUES
 ('A-03',N'商品编号不存在','NO-SUCH-SKU',5,N'盘点','E001',51710,N'NO-SUCH-SKU，+5'),
 ('A-04',N'调整数量为零',@skuP,0,N'盘点','E001',51711,N'P，0'),
 ('A-05',N'调整数量为空',@skuP,NULL,N'盘点','E001',51711,N'P，NULL'),
 ('A-06',N'库存不足',@skuP,-100,N'盘亏','E001',51712,N'P（库存 15），-100'),
 ('A-07',N'原因为空',@skuP,5,N'   ','E001',51714,N'P，+5，原因为空格'),
 ('A-08',N'员工编号不存在',@skuP,5,N'盘点','E999',51713,N'P，+5，E999'),
 ('A-09',N'员工无库存管理职责',@skuP,5,N'盘点','E003',51713,N'P，+5，收银员 E003'),
 ('A-10',N'商品编号为空',NULL,5,N'盘点','E001',51710,N'NULL，+5');
DECLARE @no varchar(10),@case nvarchar(60),@code varchar(30),@change int,@reason nvarchar(50),@emp varchar(20),@expect int,@input nvarchar(200);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT No,CaseName,Code,Change,Reason,Emp,ExpectErr,InputText FROM @cases ORDER BY No;
OPEN c;
FETCH NEXT FROM c INTO @no,@case,@code,@change,@reason,@emp,@expect,@input;
WHILE @@FETCH_STATUS=0
BEGIN
    EXEC #State @P,@before OUTPUT;
    SET @err=0; SET @msg=NULL;
    BEGIN TRY EXEC dbo.usp_AdjustInventory @ProductCode=@code,@ChangeQuantity=@change,@Reason=@reason,@EmployeeNo=@emp,@Quiet=1; END TRY
    BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
    EXEC #State @P,@after OUTPUT;
    SET @ok=IIF(@err=@expect AND @before=@after,1,0);
    SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；操作前 ',@before,N' → 操作后 ',@after);
    DECLARE @exp nvarchar(400)=CONCAT(N'拒绝，错误 ',@expect,N'；库存、流水、审计不变');
    EXEC #Rec @no,N'库存调整',@case,@input,@exp,@actual,@ok;
    FETCH NEXT FROM c INTO @no,@case,@code,@change,@reason,@emp,@expect,@input;
END;
CLOSE c; DEALLOCATE c;

-- 重复调用：每次调用都是一次新的调整，两次 +1 共 +2，两条流水首尾相连
EXEC dbo.usp_AdjustInventory @ProductCode=@skuP,@ChangeQuantity=1,@Reason=N'重复调用1',@EmployeeNo='E001',@Quiet=1;
EXEC dbo.usp_AdjustInventory @ProductCode=@skuP,@ChangeQuantity=1,@Reason=N'重复调用2',@EmployeeNo='E001',@Quiet=1;
SELECT @n=COUNT(*) FROM dbo.InventoryLog a JOIN dbo.InventoryLog b ON b.ProductID=a.ProductID AND b.Remark=N'重复调用2'
WHERE a.ProductID=@P AND a.Remark=N'重复调用1' AND a.AfterQuantity=16 AND b.BeforeQuantity=16 AND b.AfterQuantity=17;
SET @ok=IIF(@n=1 AND (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P)=17,1,0);
SET @actual=CONCAT(N'库存 ',(SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P),N'；首尾相连的流水对 ',@n,N' 组');
EXEC #Rec 'A-11',N'库存调整',N'重复调用',N'P，+1 调用两次',N'库存 15→16→17，两条流水首尾相连',@actual,@ok;
-- 回到 15，供补货量用例使用
EXEC dbo.usp_AdjustInventory @ProductCode=@skuP,@ChangeQuantity=-2,@Reason=N'恢复测试库存',@EmployeeNo='E001',@Quiet=1;

/* ================= 补货量函数 dbo.fn_RestockQuantity ================= */
-- P：库存 15，预警下限 10，默认目标为 20
DECLARE @f TABLE(No varchar(10),CaseName nvarchar(60),Target int NULL,UseMissing bit,Expected int NULL,InputText nvarchar(200),ExpText nvarchar(200));
INSERT @f VALUES
 ('F-01',N'默认目标（下限的 2 倍）',NULL,0,5,N'P（库存 15，下限 10），DEFAULT',N'返回 5（补到 20）'),
 ('F-02',N'指定目标库存',50,0,35,N'P，目标 50',N'返回 35'),
 ('F-03',N'库存已超过目标',10,0,0,N'P，目标 10',N'返回 0'),
 ('F-04',N'库存正好等于目标',15,0,0,N'P，目标 15',N'返回 0'),
 ('F-05',N'目标为负数',-1,0,NULL,N'P，目标 -1',N'返回 NULL（非法参数）'),
 ('F-06',N'商品不存在',NULL,1,NULL,N'不存在的商品编号',N'返回 NULL（商品不存在）');
DECLARE @target int,@missing bit,@expectInt int,@expText nvarchar(200);
DECLARE @missingProduct bigint=(SELECT MAX(ProductID)+1000 FROM dbo.Product);
DECLARE fc CURSOR LOCAL FAST_FORWARD FOR SELECT No,CaseName,Target,UseMissing,Expected,InputText,ExpText FROM @f ORDER BY No;
OPEN fc;
FETCH NEXT FROM fc INTO @no,@case,@target,@missing,@expectInt,@input,@expText;
WHILE @@FETCH_STATUS=0
BEGIN
    IF @missing=1 SET @int=dbo.fn_RestockQuantity(@missingProduct,DEFAULT);
    ELSE IF @target IS NULL SET @int=dbo.fn_RestockQuantity(@P,DEFAULT);
    ELSE SET @int=dbo.fn_RestockQuantity(@P,@target);
    SET @ok=IIF((@int IS NULL AND @expectInt IS NULL) OR @int=@expectInt,1,0);
    SET @actual=CONCAT(N'返回 ',COALESCE(CONVERT(nvarchar(20),@int),N'NULL'));
    EXEC #Rec @no,N'补货量函数',@case,@input,@expText,@actual,@ok;
    FETCH NEXT FROM fc INTO @no,@case,@target,@missing,@expectInt,@input,@expText;
END;
CLOSE fc; DEALLOCATE fc;

-- 纯函数可重复调用：相同库存和目标不修改数据，两次结果一致。
DECLARE @restockAgain int=dbo.fn_RestockQuantity(@P,50);
SET @int=dbo.fn_RestockQuantity(@P,50);
SET @ok=IIF(@int=35 AND @restockAgain=@int,1,0);
SET @actual=CONCAT(N'第一次 ',@int,N'，第二次 ',@restockAgain,N'，库存仍为 ',
                   (SELECT Quantity FROM dbo.Inventory WHERE ProductID=@P));
EXEC #Rec 'F-07',N'补货量函数',N'重复调用',N'P（库存 15），目标 50，连续调用两次',
    N'两次都返回 35，不修改库存',@actual,@ok;

/* ================= 折扣函数 dbo.fn_DiscountRate / dbo.fn_DiscountAmount ================= */
DECLARE @d TABLE(No varchar(10),CaseName nvarchar(60),Member bit NULL,Amount decimal(12,2) NULL,
                 ExpRate decimal(5,4) NULL,ExpAmount decimal(12,2) NULL,InputText nvarchar(200));
INSERT @d VALUES
 ('D-01',N'会员、未满 100',1,50.00,0.0500,2.50,N'会员，50.00'),
 ('D-02',N'非会员、未满 100',0,30.00,0.0000,0.00,N'非会员，30.00'),
 ('D-03',N'非会员、正好 100',0,100.00,0.0500,5.00,N'非会员，100.00'),
 ('D-04',N'会员、满 100',1,120.00,0.1000,12.00,N'会员，120.00'),
 ('D-05',N'四舍五入到分',1,33.33,0.0500,1.67,N'会员，33.33'),
 ('D-06',N'非法金额（负数）',1,-1.00,NULL,NULL,N'会员，-1.00'),
 ('D-07',N'非法会员标志（空值）',NULL,50.00,NULL,NULL,N'NULL，50.00'),
 ('D-08',N'非法金额（空值）',0,NULL,NULL,NULL,N'非会员，NULL');
DECLARE @member bit,@amt decimal(12,2),@expRate decimal(5,4),@expAmount decimal(12,2);
DECLARE dc CURSOR LOCAL FAST_FORWARD FOR SELECT No,CaseName,Member,Amount,ExpRate,ExpAmount,InputText FROM @d ORDER BY No;
OPEN dc;
FETCH NEXT FROM dc INTO @no,@case,@member,@amt,@expRate,@expAmount,@input;
WHILE @@FETCH_STATUS=0
BEGIN
    SET @rate=dbo.fn_DiscountRate(@member,@amt);
    SET @amount=dbo.fn_DiscountAmount(@member,@amt);
    SET @ok=IIF(((@rate IS NULL AND @expRate IS NULL) OR @rate=@expRate)
            AND ((@amount IS NULL AND @expAmount IS NULL) OR @amount=@expAmount),1,0);
    SET @actual=CONCAT(N'折扣率 ',COALESCE(CONVERT(nvarchar(20),@rate),N'NULL'),N'，折扣金额 ',COALESCE(CONVERT(nvarchar(20),@amount),N'NULL'));
    SET @expText=CONCAT(N'折扣率 ',COALESCE(CONVERT(nvarchar(20),@expRate),N'NULL'),N'，折扣金额 ',COALESCE(CONVERT(nvarchar(20),@expAmount),N'NULL'));
    EXEC #Rec @no,N'折扣函数',@case,@input,@expText,@actual,@ok;
    FETCH NEXT FROM dc INTO @no,@case,@member,@amt,@expRate,@expAmount,@input;
END;
CLOSE dc; DEALLOCATE dc;

-- 折扣函数可重复调用：相同会员标志和金额得到相同结果。
DECLARE @rateAgain decimal(5,4)=dbo.fn_DiscountRate(1,120.00),
        @amountAgain decimal(12,2)=dbo.fn_DiscountAmount(1,120.00);
SET @rate=dbo.fn_DiscountRate(1,120.00);
SET @amount=dbo.fn_DiscountAmount(1,120.00);
SET @ok=IIF(@rate=0.1000 AND @rateAgain=@rate AND @amount=12.00 AND @amountAgain=@amount,1,0);
SET @actual=CONCAT(N'两次折扣率 ',@rate,N' / ',@rateAgain,N'，折扣金额 ',@amount,N' / ',@amountAgain);
EXEC #Rec 'D-11',N'折扣函数',N'重复调用',N'会员，120.00，连续调用两次',
    N'两次均返回折扣率 0.1000、折扣金额 12.00',@actual,@ok;

-- 折扣写入订单：会员订单 Q×4=100.00，结算后保存折扣率 0.10、折扣 10.00，明细保存成交价；之后改售价，历史订单不变
EXEC dbo.usp_AdjustInventory @ProductCode=@skuQ,@ChangeQuantity=10,@Reason=N'折扣测试备货',@EmployeeNo='E001',@Quiet=1;
INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod)
SELECT 'T10S'+@tag,EmployeeID,'WECHAT' FROM dbo.Employee WHERE EmployeeNo='E003';
SET @sale=SCOPE_IDENTITY();
INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice) VALUES(@sale,@Q,4,25.00);
INSERT app.SaleOwner(SaleID,UserID,SubmittedAt) SELECT @sale,UserID,SYSDATETIME() FROM app.AppUser WHERE Username='customer';
EXEC dbo.usp_CompleteOrder @SaleID=@sale,@Quiet=1;
UPDATE dbo.Product SET SalePrice=30.00 WHERE ProductID=@Q;
SELECT @ok=IIF(so.DiscountRate=0.1000 AND so.DiscountAmount=10.00 AND so.PayableAmount=90.00 AND si.UnitPrice=25.00
               AND si.LineAmount=100.00 AND p.SalePrice=30.00,1,0),
       @actual=CONCAT(N'折扣率 ',so.DiscountRate,N'，折扣 ',so.DiscountAmount,N'，应付 ',so.PayableAmount,
                      N'；明细成交价 ',si.UnitPrice,N'，商品现价 ',p.SalePrice)
FROM dbo.SaleOrder so JOIN dbo.SaleItem si ON si.SaleID=so.SaleID JOIN dbo.Product p ON p.ProductID=si.ProductID
WHERE so.SaleID=@sale;
EXEC #Rec 'D-09',N'折扣函数',N'折扣与成交价保存到历史订单',N'会员订单 Q×4（25.00），结算后把 Q 改价为 30.00',
    N'订单保存折扣率 0.1000、折扣 10.00、应付 90.00；明细成交价仍为 25.00',@actual,@ok;
UPDATE dbo.Product SET SalePrice=25.00 WHERE ProductID=@Q;

-- 非法折扣：已完成订单的折扣金额和折扣率不能再改
SET @err=0; SET @n=0;
BEGIN TRY UPDATE dbo.SaleOrder SET DiscountAmount=1.00 WHERE SaleID=@sale; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); END CATCH;
BEGIN TRY UPDATE dbo.SaleOrder SET DiscountRate=0.5000 WHERE SaleID=@sale; END TRY BEGIN CATCH SET @n=ERROR_NUMBER(); END CATCH;
SELECT @ok=IIF(@err=51322 AND @n=51756 AND DiscountAmount=10.00 AND DiscountRate=0.1000,1,0),
       @actual=CONCAT(N'改折扣金额：错误 ',@err,N'；改折扣率：错误 ',@n,N'；订单仍为折扣率 ',DiscountRate,N'、折扣 ',DiscountAmount)
FROM dbo.SaleOrder WHERE SaleID=@sale;
EXEC #Rec 'D-10',N'折扣函数',N'非法修改历史折扣',N'把 D-09 已完成订单的折扣改为 1.00、折扣率改为 0.5',
    N'分别被拒绝（51322、51756），订单数据不变',@actual,@ok;

/* ================= 销售统计过程与销售汇总函数 ================= */
-- D-09 的订单（Q×4，100.00）今天完成；再完成一张非会员订单 P×2、Q×1（45.00）
INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod)
SELECT 'T10T'+@tag,EmployeeID,'CASH' FROM dbo.Employee WHERE EmployeeNo='E003';
SET @sale=SCOPE_IDENTITY();
INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice) VALUES(@sale,@P,2,10.00),(@sale,@Q,1,25.00);
EXEC dbo.usp_CompleteOrder @SaleID=@sale,@Quiet=1;

SET @err=0; SET @msg=NULL;
PRINT N'S-01 销售统计（今天到今天）：';
BEGIN TRY EXEC dbo.usp_SalesStatistics @StartDate=@today,@EndDate=@today; END TRY
BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
SELECT @ok=IIF(@err=0
    AND EXISTS(SELECT 1 FROM dbo.fn_SalesSummary(@today,@today) WHERE ProductID=@P AND SoldQuantity=2 AND SalesAmount=20.00 AND OrderCount=1)
    AND EXISTS(SELECT 1 FROM dbo.fn_SalesSummary(@today,@today) WHERE ProductID=@Q AND SoldQuantity=5 AND SalesAmount=125.00 AND OrderCount=2),1,0);
SET @actual=CONCAT(IIF(@err=0,N'成功',CONCAT(N'错误 ',@err,N' ',@msg)),N'；汇总函数中 P：',
    (SELECT CONCAT(SoldQuantity,N' 件/',SalesAmount,N' 元/',OrderCount,N' 单') FROM dbo.fn_SalesSummary(@today,@today) WHERE ProductID=@P),
    N'，Q：',(SELECT CONCAT(SoldQuantity,N' 件/',SalesAmount,N' 元/',OrderCount,N' 单') FROM dbo.fn_SalesSummary(@today,@today) WHERE ProductID=@Q));
EXEC #Rec 'S-01',N'销售统计',N'正常区间（含当天）',N'开始=今天，结束=今天',
    N'成功，返回区间汇总和商品明细；P：2 件/20.00 元/1 单，Q：5 件/125.00 元/2 单',@actual,@ok;

SET @err=0; SET @msg=NULL;
PRINT N'S-02 没有销售记录的区间（2000-01-01 至 2000-01-31）：';
BEGIN TRY EXEC dbo.usp_SalesStatistics @StartDate='2000-01-01',@EndDate='2000-01-31'; END TRY
BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
SET @n=(SELECT COUNT(*) FROM dbo.fn_SalesSummary('2000-01-01','2000-01-31'));
SET @ok=IIF(@err=0 AND @n=0,1,0);
SET @actual=CONCAT(IIF(@err=0,N'成功',CONCAT(N'错误 ',@err,N' ',@msg)),N'；汇总函数返回 ',@n,N' 行');
EXEC #Rec 'S-02',N'销售统计',N'没有销售记录',N'2000-01-01 至 2000-01-31',N'成功；汇总各项为 0，商品明细为空',@actual,@ok;

SET @err=0; SET @msg=NULL;
BEGIN TRY EXEC dbo.usp_SalesStatistics @StartDate=NULL,@EndDate=@today; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
SET @ok=IIF(@err=51701,1,0); SET @actual=CONCAT(N'错误 ',@err,N' ',@msg);
EXEC #Rec 'S-03',N'销售统计',N'开始日期为空',N'NULL 至今天',N'错误 51701',@actual,@ok;

SET @err=0; SET @msg=NULL;
DECLARE @tomorrow date=DATEADD(DAY,1,@today);
BEGIN TRY EXEC dbo.usp_SalesStatistics @StartDate=@tomorrow,@EndDate=@today; END TRY BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
SET @n=(SELECT COUNT(*) FROM dbo.fn_SalesSummary(@tomorrow,@today));
SET @ok=IIF(@err=51702 AND @n=0,1,0); SET @actual=CONCAT(N'过程：错误 ',@err,N' ',@msg,N'；汇总函数返回 ',@n,N' 行');
EXEC #Rec 'S-04',N'销售统计',N'开始日期晚于结束日期',N'明天 至 今天',N'过程报错 51702；表值函数返回空结果',@actual,@ok;

SET @n=(SELECT COUNT(*) FROM dbo.fn_SalesSummary(DATEADD(DAY,-1,@today),DATEADD(DAY,-1,@today)) WHERE ProductID IN (@P,@Q));
SET @n2=(SELECT COUNT(*) FROM dbo.fn_SalesSummary(NULL,@today));
SET @ok=IIF(@n=0 AND @n2=0,1,0);
SET @actual=CONCAT(N'昨天区间含测试商品 ',@n,N' 行；开始日期为 NULL 返回 ',@n2,N' 行');
EXEC #Rec 'S-05',N'销售汇总函数',N'日期边界与空值',N'昨天至昨天；NULL 至今天',N'今天的订单不出现在昨天的区间；空值返回空结果',@actual,@ok;

SELECT @n=COUNT(*) FROM (
    SELECT * FROM dbo.fn_SalesSummary('2000-01-01',@today)
    EXCEPT SELECT * FROM dbo.fn_SalesSummary('2000-01-01',@today)) AS x;
SET @ok=IIF(@n=0,1,0); SET @actual=CONCAT(N'两次结果的差异 ',@n,N' 行');
EXEC #Rec 'S-06',N'销售汇总函数',N'重复调用',N'同一区间调用两次',N'结果完全相同',@actual,@ok;

PRINT N'S-07 表值函数写在 SELECT 中，与商品、分类表连接：';
SELECT s.SKU AS sku, s.ProductName AS product_name, c.CategoryName AS category_name,
       s.SoldQuantity AS sold_quantity, s.SalesAmount AS sales_amount, s.OrderCount AS order_count
FROM dbo.fn_SalesSummary(@today,@today) AS s
JOIN dbo.Product AS p ON p.ProductID=s.ProductID JOIN dbo.Category AS c ON c.CategoryID=p.CategoryID
ORDER BY s.SalesAmount DESC;
SET @n=@@ROWCOUNT;
SET @ok=IIF(@n>=2,1,0); SET @actual=CONCAT(N'返回 ',@n,N' 行');
EXEC #Rec 'S-07',N'销售汇总函数',N'在 SELECT 中调用',N'fn_SalesSummary(今天, 今天) JOIN Product、Category',N'至少返回 P、Q 两行，带分类名称',@actual,@ok;

SET @err=0; SET @msg=NULL;
BEGIN TRY
    EXEC dbo.usp_SalesStatistics @StartDate='2000-01-01',@EndDate='2010-01-09';
END TRY
BEGIN CATCH
    SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE();
END CATCH;
SET @ok=IIF(@err=51703,1,0); SET @actual=CONCAT(N'错误 ',@err,N' ',@msg);
EXEC #Rec 'S-08',N'销售统计',N'日期范围过大',N'2000-01-01 至 2010-01-09（跨度 3661 天）',N'错误 51703',@actual,@ok;

/* ================= 补货选择过程 dbo.usp_CreateRestockOrder ================= */
-- P 库存 13（15-2）、下限改为 50：低于下限，补到 100，补货量 87
UPDATE dbo.Inventory SET MinQuantity=50 WHERE ProductID=@P;
SET @n=(SELECT COUNT(*) FROM dbo.PurchaseOrder);
EXEC #State @P,@before OUTPUT;
SET @err=0; SET @msg=NULL; SET @purchase=NULL;
DECLARE @supplier bigint=(SELECT SupplierID FROM dbo.Supplier WHERE SupplierCode='S001');
PRINT N'R-01 补货选择生成的补货单：';
BEGIN TRY EXEC dbo.usp_CreateRestockOrder @SupplierID=@supplier,@EmployeeNo='E002',@PurchaseID=@purchase OUTPUT; END TRY
BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC #State @P,@after OUTPUT;
SET @ok=0;
SELECT @ok=IIF(@err=0 AND po.Status='DRAFT'
    AND EXISTS(SELECT 1 FROM dbo.PurchaseItem WHERE PurchaseID=@purchase AND ProductID=@P AND Quantity=87)
    AND NOT EXISTS(SELECT 1 FROM dbo.PurchaseItem pi JOIN dbo.Inventory i ON i.ProductID=pi.ProductID
                   WHERE pi.PurchaseID=@purchase AND i.Quantity>=i.MinQuantity)
    AND @before=@after,1,0),
       @actual=CONCAT(IIF(@err=0,N'成功',CONCAT(N'错误 ',@err,N' ',@msg)),N'；补货单 ',po.Status,N'，明细 ',
                      (SELECT COUNT(*) FROM dbo.PurchaseItem WHERE PurchaseID=@purchase),N' 行，P 补货量 ',
                      (SELECT Quantity FROM dbo.PurchaseItem WHERE PurchaseID=@purchase AND ProductID=@P),
                      N'；P 操作前 ',@before,N' → 操作后 ',@after)
FROM dbo.PurchaseOrder po WHERE po.PurchaseID=@purchase;
IF @purchase IS NULL SET @actual=CONCAT(N'错误 ',@err,N' ',@msg);
EXEC #Rec 'R-01',N'补货选择',N'生成补货单（正常）',N'供应商 S001，员工 E002；P 库存 13、下限 50',
    N'成功；生成待入库补货单，只含低于下限的商品，P 补货量 87（补到 100）；库存不变',@actual,@ok;

-- 补货选择过程可重复调用：草稿尚未入库，库存仍低于下限，再次调用应生成另一张独立完整草稿。
DECLARE @firstPurchase bigint=@purchase,@purchaseRepeat bigint;
SET @n=(SELECT COUNT(*) FROM dbo.PurchaseOrder);
EXEC #State @P,@before OUTPUT;
SET @err=0; SET @msg=NULL;
BEGIN TRY
    EXEC dbo.usp_CreateRestockOrder @SupplierID=@supplier,@EmployeeNo='E002',
         @PurchaseID=@purchaseRepeat OUTPUT,@Quiet=1;
END TRY
BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
EXEC #State @P,@after OUTPUT;
SET @ok=IIF(@err=0 AND @purchaseRepeat<>@firstPurchase
    AND (SELECT COUNT(*) FROM dbo.PurchaseOrder)=@n+1
    AND EXISTS(SELECT 1 FROM dbo.PurchaseItem WHERE PurchaseID=@purchaseRepeat AND ProductID=@P AND Quantity=87)
    AND NOT EXISTS(SELECT 1 FROM dbo.PurchaseItem pi JOIN dbo.Inventory i ON i.ProductID=pi.ProductID
                   WHERE pi.PurchaseID=@purchaseRepeat AND i.Quantity>=i.MinQuantity)
    AND @before=@after,1,0);
SET @actual=CONCAT(IIF(@err=0,N'成功',CONCAT(N'错误 ',@err,N' ',@msg)),N'；首张 ',@firstPurchase,
                   N'，第二张 ',@purchaseRepeat,N'；补货单数 ',@n,N' → ',(SELECT COUNT(*) FROM dbo.PurchaseOrder),
                   N'；P 操作前 ',@before,N' → 操作后 ',@after);
EXEC #Rec 'R-06',N'补货选择',N'重复调用',N'库存未入库时以相同供应商、员工再调用一次',
    N'生成第二张独立且完整的草稿，补货量仍为 87，库存不变',@actual,@ok;

DECLARE @r TABLE(No varchar(10),CaseName nvarchar(60),Supplier bigint NULL,Emp varchar(20) NULL,ExpectErr int,InputText nvarchar(200));
INSERT @r VALUES
 ('R-02',N'供应商不存在',(SELECT MAX(SupplierID)+1000 FROM dbo.Supplier),'E002',51720,N'不存在的供应商，E002'),
 ('R-03',N'员工无采购职责',@supplier,'E003',51713,N'S001，收银员 E003'),
 ('R-04',N'供应商为空',NULL,'E002',51720,N'NULL，E002');
DECLARE @sup bigint;
DECLARE rc CURSOR LOCAL FAST_FORWARD FOR SELECT No,CaseName,Supplier,Emp,ExpectErr,InputText FROM @r ORDER BY No;
OPEN rc;
FETCH NEXT FROM rc INTO @no,@case,@sup,@emp,@expect,@input;
WHILE @@FETCH_STATUS=0
BEGIN
    SET @n=(SELECT COUNT(*) FROM dbo.PurchaseOrder);
    SET @err=0; SET @msg=NULL; SET @purchase=NULL;
    BEGIN TRY EXEC dbo.usp_CreateRestockOrder @SupplierID=@sup,@EmployeeNo=@emp,@PurchaseID=@purchase OUTPUT,@Quiet=1; END TRY
    BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); END CATCH;
    SET @n2=(SELECT COUNT(*) FROM dbo.PurchaseOrder);
    SET @ok=IIF(@err=@expect AND @n=@n2,1,0);
    SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；补货单数 ',@n,N' → ',@n2);
    SET @expText=CONCAT(N'拒绝，错误 ',@expect,N'；不生成补货单');
    EXEC #Rec @no,N'补货选择',@case,@input,@expText,@actual,@ok;
    FETCH NEXT FROM rc INTO @no,@case,@sup,@emp,@expect,@input;
END;
CLOSE rc; DEALLOCATE rc;

-- 没有需要补货的商品：在事务中把所有下限改为 0 再调用，结束后回滚
SET @n=(SELECT COUNT(*) FROM dbo.PurchaseOrder);
SET @err=0; SET @msg=NULL;
BEGIN TRY
    BEGIN TRAN;
    UPDATE dbo.Inventory SET MinQuantity=0;
    EXEC dbo.usp_CreateRestockOrder @SupplierID=@supplier,@EmployeeNo='E002',@PurchaseID=@purchase OUTPUT,@Quiet=1;
    ROLLBACK;
END TRY
BEGIN CATCH SET @err=ERROR_NUMBER(); SET @msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK; END CATCH;
SET @n2=(SELECT COUNT(*) FROM dbo.PurchaseOrder);
SET @ok=IIF(@err=51721 AND @n=@n2 AND (SELECT MinQuantity FROM dbo.Inventory WHERE ProductID=@P)=50,1,0);
SET @actual=CONCAT(N'错误 ',@err,N' ',@msg,N'；补货单数 ',@n,N' → ',@n2);
EXEC #Rec 'R-05',N'补货选择',N'没有需要补货的商品',N'所有商品下限临时改为 0（事务结束回滚）',N'拒绝，错误 51721；不生成空补货单',@actual,@ok;

SET @ok=IIF(@@TRANCOUNT=0,1,0); SET @actual=CONCAT(N'@@TRANCOUNT=',@@TRANCOUNT);
EXEC #Rec 'END',N'收尾',N'没有遗留事务',N'—',N'0',@actual,@ok;

SELECT CaseNo AS [编号], Area AS [对象], CaseName AS [用例], Input AS [输入参数], Expected AS [预期结果],
       Actual AS [实际结果], IIF(Passed=1,N'通过',N'未通过') AS [结论]
FROM #Result ORDER BY Seq;
SELECT N'第十周过程与函数验证' AS [项目], COUNT(*) AS [检查项], SUM(CONVERT(int,Passed)) AS [通过],
       COUNT(*)-SUM(CONVERT(int,Passed)) AS [失败]
FROM #Result;
GO
