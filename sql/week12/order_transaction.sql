/* 第十二周：订单完成事务。可重复执行。
   涉及的表：SaleOrder（订单头）、SaleItem（明细）、Inventory（库存）、InventoryLog（库存流水）、
            InventoryAudit（库存审计，由触发器写）、app.SaleOwner（判断是否会员订单）。
   事务边界：由 dbo.usp_CompleteOrder 负责整个“完成订单”业务——检查、扣库存、写流水、算金额折扣、改状态，
            全部成功才提交，任何一步失败全部回滚。网页的 app.SettleSale 只做身份检查后调用它；
            触发器 tr_SaleOrder_CompleteRule 只检查、不扣库存，tr_Inventory_Audit 只记录。
            一次业务只有这一处扣减库存；已完成的订单再次调用会被拒绝（51731），不会重复扣减。
   调用时没有外层事务：过程自己 BEGIN TRAN / COMMIT；
   在网页请求的事务中调用：过程建保存点，失败回滚到保存点并抛错，网页层随后回滚整个请求，最终提交只由网页层做一次。
   @FailAfterStock=1 仅供测试：库存已扣减、流水已写入后、订单完成前主动 THROW，用来证明前面的写入会被回滚。 */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]%'
    THROW 51700,N'第十至十二周对象只部署到独立 W7 应用数据库',1;
IF OBJECT_ID(N'dbo.fn_DiscountAmount',N'FN') IS NULL OR OBJECT_ID(N'dbo.tr_SaleOrder_CompleteRule',N'TR') IS NULL
    THROW 51700,N'请先部署 sql/week10 和 sql/week11',1;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CompleteOrder
    @SaleID bigint, @EmployeeID bigint=NULL, @FailAfterStock bit=0, @Quiet bit=0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    DECLARE @entryTranCount int=@@TRANCOUNT, @savePointCreated bit=0;
    DECLARE @status varchar(20), @employee bigint, @payment varchar(20), @lines int, @moved int;
    DECLARE @total decimal(12,2), @isMember bit, @rate decimal(5,4), @discount decimal(12,2);
    DECLARE @demand TABLE(ProductID bigint PRIMARY KEY, Quantity int NOT NULL, Amount decimal(12,2) NOT NULL);
    DECLARE @changed TABLE(ProductID bigint PRIMARY KEY, BeforeQuantity int NOT NULL, AfterQuantity int NOT NULL);
    IF @SaleID IS NULL THROW 51730,N'请提供订单编号',1;
    BEGIN TRY
        IF @entryTranCount=0 BEGIN TRAN;
        ELSE
        BEGIN
            SAVE TRAN CompleteOrderSave;
            SET @savePointCreated=1;
        END;

        -- 1. 锁住订单头，两个会话不能同时完成同一张订单；第二个会话等第一个提交后读到“已完成”而被拒绝。
        SELECT @status=Status, @employee=COALESCE(@EmployeeID,EmployeeID), @payment=PaymentMethod
        FROM dbo.SaleOrder WITH (UPDLOCK,HOLDLOCK) WHERE SaleID=@SaleID;
        IF @status IS NULL THROW 51730,N'订单不存在',1;
        IF @status='COMPLETED' THROW 51731,N'订单已完成，不能重复完成，库存不会再次扣减',1;
        IF @status='CANCELLED' THROW 51732,N'订单已取消，不能完成',1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Employee WITH (HOLDLOCK)
                       WHERE EmployeeID=@employee AND Status=1 AND RoleName IN ('CASHIER','ADMIN'))
            THROW 51306,N'经办员工未启用或无收银职责',1;
        IF @payment IS NULL THROW 51301,N'结算前需选择支付方式',1;

        -- 2. 按商品汇总需求量（锁住明细，完成前不能再被修改）。
        INSERT @demand(ProductID,Quantity,Amount)
        SELECT ProductID, SUM(Quantity), SUM(LineAmount)
        FROM dbo.SaleItem WITH (UPDLOCK,HOLDLOCK) WHERE SaleID=@SaleID GROUP BY ProductID;
        SET @lines=@@ROWCOUNT;
        IF @lines=0 THROW 51302,N'订单没有明细',1;
        IF EXISTS (SELECT 1 FROM @demand WHERE Quantity<=0) THROW 51733,N'购买数量必须大于零',1;
        IF EXISTS (SELECT 1 FROM @demand AS d
                   JOIN dbo.Product AS p WITH (HOLDLOCK) ON p.ProductID=d.ProductID
                   JOIN dbo.Category AS c WITH (HOLDLOCK) ON c.CategoryID=p.CategoryID
                   WHERE p.Status=0 OR c.Status=0)
            THROW 51304,N'订单含已停用商品或分类',1;

        -- 3. 订单金额与折扣：会员身份和金额交给函数计算，实际折扣率和折扣金额保存在订单头。
        SELECT @total=SUM(Amount) FROM @demand;
        SET @isMember=dbo.fn_IsMemberOrder(@SaleID);
        SET @rate=dbo.fn_DiscountRate(@isMember,@total);
        SET @discount=dbo.fn_DiscountAmount(@isMember,@total);
        IF @rate IS NULL OR @discount IS NULL OR @discount<0 OR @discount>@total
            THROW 51734,N'折扣计算结果非法',1;

        -- 4. 带库存条件扣减：只有库存 >= 需求量的行才会被改；改到的行数少于商品数说明有商品库存不足，整体回滚。
        --    不在事务外先查库存，避免“查的时候够、扣的时候不够”。
        EXEC sys.sp_set_session_context @key=N'CampusStoreOperator', @value=@employee;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=1;
        UPDATE i SET Quantity=i.Quantity-d.Quantity, UpdatedAt=SYSDATETIME()
        OUTPUT inserted.ProductID, deleted.Quantity, inserted.Quantity
            INTO @changed(ProductID,BeforeQuantity,AfterQuantity)
        FROM dbo.Inventory AS i JOIN @demand AS d ON d.ProductID=i.ProductID
        WHERE i.Quantity>=d.Quantity;
        SELECT @moved=COUNT(*) FROM @changed;
        IF @moved<>@lines THROW 51305,N'商品库存不足',1;

        -- 5. 每个商品写一条销售出库流水，前后数量取自上一步实际改动的值。
        INSERT dbo.InventoryLog(ProductID,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,
                                PurchaseID,SaleID,EmployeeID)
        SELECT ProductID,'SALE_OUT',AfterQuantity-BeforeQuantity,BeforeQuantity,AfterQuantity,
               NULL,@SaleID,@employee
        FROM @changed;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=NULL;

        IF @FailAfterStock=1
            THROW 51799,N'测试用：库存已扣减、流水已写入，在订单完成前主动失败',1;

        -- 6. 更新订单状态；tr_SaleOrder_CompleteRule 会再核对明细、库存扣减和金额。
        EXEC sys.sp_set_session_context @key=N'CampusStoreSaleComplete', @value=@SaleID;
        UPDATE dbo.SaleOrder
        SET EmployeeID=@employee, TotalAmount=@total, DiscountRate=@rate, DiscountAmount=@discount,
            Status='COMPLETED', SaleTime=SYSDATETIME()
        WHERE SaleID=@SaleID;
        EXEC sys.sp_set_session_context @key=N'CampusStoreSaleComplete', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreOperator', @value=NULL;
        IF @entryTranCount=0 COMMIT;
    END TRY
    BEGIN CATCH
        IF @entryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @entryTranCount>0 AND XACT_STATE()=1 AND @savePointCreated=1
            ROLLBACK TRAN CompleteOrderSave;
        -- XACT_STATE()=-1 时不能回滚保存点，外层调用者必须整体 ROLLBACK。
        EXEC sys.sp_set_session_context @key=N'CampusStoreSaleComplete', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreOperator', @value=NULL;
        THROW;
    END CATCH;
    IF @Quiet=0
        SELECT SaleID AS sale_id, SaleNo AS sale_no, Status AS status, TotalAmount AS total_amount,
               DiscountRate AS discount_rate, DiscountAmount AS discount_amount, PayableAmount AS payable_amount
        FROM dbo.SaleOrder WHERE SaleID=@SaleID;
END;
GO
/* 统一库存扣减入口：第一阶段的 dbo.CompleteSale 改为直接调用 dbo.usp_CompleteOrder，
   数据库里只剩一处扣减销售库存的代码。 */
CREATE OR ALTER PROCEDURE dbo.CompleteSale @SaleID bigint
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_CompleteOrder @SaleID=@SaleID, @Quiet=1;
END;
GO
PRINT N'第十二周订单完成事务已部署：usp_CompleteOrder（dbo.CompleteSale 已改为调用它）';
