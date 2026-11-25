/* 第十二周：模拟补货入库事务。可重复执行。
   补货单沿用 v1.0 的采购单结构：PurchaseOrder 是补货单头（DRAFT=待入库，RECEIVED=已入库，ReceivedTime=入库时间），
   PurchaseItem 是补货明细（补货单编号—商品—数量的对应关系）。补货单可以人工填写（采购页），
   也可以由 dbo.usp_CreateRestockOrder 按库存预警生成；第四阶段只需把明细数量换成预测结果，入库事务不变。
   事务边界：dbo.usp_ReceiveRestock 负责整个入库——检查单据、商品和数量，增加库存，写采购入库流水，
            更新补货单状态、金额和入库时间，全部成功才提交。已入库的单据再次执行会被拒绝（51741），库存不会重复增加。
   @FailAfterStock=1 仅供测试：库存已增加、流水已写入后、单据完成前主动 THROW。 */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]%'
    THROW 51700,N'第十至十二周对象只部署到独立 W7 应用数据库',1;
IF OBJECT_ID(N'dbo.tr_Inventory_Audit',N'TR') IS NULL
    THROW 51700,N'请先部署 sql/week11/trigger.sql',1;
GO
CREATE OR ALTER PROCEDURE dbo.usp_ReceiveRestock
    @PurchaseID bigint, @EmployeeID bigint=NULL, @FailAfterStock bit=0, @Quiet bit=0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    DECLARE @entryTranCount int=@@TRANCOUNT, @savePointCreated bit=0;
    DECLARE @status varchar(20), @receiver bigint, @supplierID bigint, @lines int, @moved int;
    DECLARE @total decimal(12,2);
    DECLARE @demand TABLE(ProductID bigint PRIMARY KEY, Quantity int NOT NULL, Amount decimal(12,2) NOT NULL);
    DECLARE @changed TABLE(ProductID bigint PRIMARY KEY, BeforeQuantity int NOT NULL, AfterQuantity int NOT NULL);
    IF @PurchaseID IS NULL THROW 51740,N'请提供补货单编号',1;
    BEGIN TRY
        IF @entryTranCount=0 BEGIN TRAN;
        ELSE
        BEGIN
            SAVE TRAN ReceiveRestockSave;
            SET @savePointCreated=1;
        END;

        -- 1. 锁住补货单头，阻止两个会话同时入库同一张单据。
        SELECT @status=Status, @receiver=COALESCE(@EmployeeID,EmployeeID), @supplierID=SupplierID
        FROM dbo.PurchaseOrder WITH (UPDLOCK,HOLDLOCK) WHERE PurchaseID=@PurchaseID;
        IF @status IS NULL THROW 51740,N'补货单不存在',1;
        IF @status='RECEIVED' THROW 51741,N'补货单已入库，不能重复入库，库存不会再次增加',1;
        IF @status='CANCELLED' THROW 51742,N'补货单已取消，不能入库',1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Employee WITH (HOLDLOCK)
                       WHERE EmployeeID=@receiver AND Status=1 AND RoleName IN ('PURCHASER','ADMIN'))
            THROW 51203,N'入库员工未启用或无采购职责',1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Supplier WITH (HOLDLOCK) WHERE SupplierID=@supplierID AND Status=1)
            THROW 51204,N'补货单的供应商已停用',1;

        -- 2. 汇总补货明细并检查商品和数量。
        INSERT @demand(ProductID,Quantity,Amount)
        SELECT ProductID, SUM(Quantity), SUM(LineAmount)
        FROM dbo.PurchaseItem WITH (UPDLOCK,HOLDLOCK) WHERE PurchaseID=@PurchaseID GROUP BY ProductID;
        SET @lines=@@ROWCOUNT;
        IF @lines=0 THROW 51201,N'补货单没有明细',1;
        IF EXISTS (SELECT 1 FROM @demand WHERE Quantity<=0) THROW 51743,N'补货数量必须大于零',1;
        IF EXISTS (SELECT 1 FROM @demand AS d
                   LEFT JOIN dbo.Product AS p WITH (HOLDLOCK) ON p.ProductID=d.ProductID
                   WHERE p.ProductID IS NULL OR p.Status=0)
            THROW 51744,N'补货单含不存在或已停用的商品',1;
        SELECT @total=SUM(Amount) FROM @demand;

        -- 3. 增加库存；改到的行数必须等于商品数，少了说明有商品缺库存记录。
        EXEC sys.sp_set_session_context @key=N'CampusStoreOperator', @value=@receiver;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=1;
        UPDATE i SET Quantity=i.Quantity+d.Quantity, UpdatedAt=SYSDATETIME()
        OUTPUT inserted.ProductID, deleted.Quantity, inserted.Quantity
            INTO @changed(ProductID,BeforeQuantity,AfterQuantity)
        FROM dbo.Inventory AS i JOIN @demand AS d ON d.ProductID=i.ProductID;
        SELECT @moved=COUNT(*) FROM @changed;
        IF @moved<>@lines THROW 51202,N'商品缺少库存记录',1;

        -- 4. 每个商品写一条采购入库流水，记录来源补货单。
        INSERT dbo.InventoryLog(ProductID,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,
                                PurchaseID,SaleID,EmployeeID)
        SELECT ProductID,'PURCHASE_IN',AfterQuantity-BeforeQuantity,BeforeQuantity,AfterQuantity,
               @PurchaseID,NULL,@receiver
        FROM @changed;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=NULL;

        IF @FailAfterStock=1
            THROW 51799,N'测试用：库存已增加、流水已写入，在补货单完成前主动失败',1;

        -- 5. 补货单改为已入库，保存金额和入库时间。
        EXEC sys.sp_set_session_context @key=N'CampusStorePurchaseConfirm', @value=@PurchaseID;
        UPDATE dbo.PurchaseOrder
        SET TotalAmount=@total, Status='RECEIVED', ReceivedTime=SYSDATETIME(), UpdatedAt=SYSDATETIME()
        WHERE PurchaseID=@PurchaseID;
        EXEC sys.sp_set_session_context @key=N'CampusStorePurchaseConfirm', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreOperator', @value=NULL;
        IF @entryTranCount=0 COMMIT;
    END TRY
    BEGIN CATCH
        IF @entryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @entryTranCount>0 AND XACT_STATE()=1 AND @savePointCreated=1
            ROLLBACK TRAN ReceiveRestockSave;
        EXEC sys.sp_set_session_context @key=N'CampusStorePurchaseConfirm', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreOperator', @value=NULL;
        THROW;
    END CATCH;
    IF @Quiet=0
        SELECT PurchaseID AS purchase_id, PurchaseNo AS purchase_no, Status AS status,
               TotalAmount AS total_amount, ReceivedTime AS received_time
        FROM dbo.PurchaseOrder WHERE PurchaseID=@PurchaseID;
END;
GO
/* 统一入库入口：第一阶段的 dbo.ConfirmPurchase 改为直接调用 dbo.usp_ReceiveRestock。 */
CREATE OR ALTER PROCEDURE dbo.ConfirmPurchase @PurchaseID bigint
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_ReceiveRestock @PurchaseID=@PurchaseID, @Quiet=1;
END;
GO
PRINT N'第十二周补货入库事务已部署：usp_ReceiveRestock（dbo.ConfirmPurchase 已改为调用它）';
