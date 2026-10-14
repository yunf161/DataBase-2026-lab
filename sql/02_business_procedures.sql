/* 无外层事务时过程自行提交；有外层事务时使用保存点，提交权属于调用者。 */
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
-- 同步已有数据库的约束：仅已完成销售要求优惠不超过已结算总额。
-- 草稿和取消单保留未结算金额，不参与销售统计。
BEGIN TRY
    BEGIN TRAN;
    ALTER TABLE dbo.SaleOrder DROP CONSTRAINT CK_SaleOrder_Amount;
    ALTER TABLE dbo.SaleOrder WITH CHECK ADD CONSTRAINT CK_SaleOrder_Amount CHECK
        (TotalAmount>=0 AND DiscountAmount>=0
         AND (Status<>'COMPLETED' OR DiscountAmount<=TotalAmount));
    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;
GO
-- 可重复部署的完整性保护：分类不允许形成循环。
CREATE OR ALTER TRIGGER dbo.tr_Category_PreventCycle ON dbo.Category AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @hasCycle bit=0;
    ;WITH CategoryChain AS (
        SELECT i.CategoryID AS StartCategoryID, i.ParentID AS CurrentCategoryID,
               CAST('/'+CONVERT(varchar(20),i.CategoryID)+'/' AS varchar(max)) AS CategoryPath,
               CAST(0 AS bit) AS HasCycle
        FROM inserted AS i
        WHERE i.ParentID IS NOT NULL

        UNION ALL

        SELECT cc.StartCategoryID, parent.ParentID,
               CAST(cc.CategoryPath+CONVERT(varchar(20),parent.CategoryID)+'/' AS varchar(max)),
               CAST(CASE WHEN CHARINDEX('/'+CONVERT(varchar(20),parent.CategoryID)+'/',cc.CategoryPath)>0
                         THEN 1 ELSE 0 END AS bit)
        FROM CategoryChain AS cc
        JOIN dbo.Category AS parent ON parent.CategoryID=cc.CurrentCategoryID
        WHERE cc.CurrentCategoryID IS NOT NULL
          AND cc.HasCycle=0
    )
    SELECT @hasCycle=CASE WHEN EXISTS (SELECT 1 FROM CategoryChain WHERE HasCycle=1)
                          THEN 1 ELSE 0 END
    OPTION (MAXRECURSION 32767);

    IF @hasCycle=1
        THROW 51010, N'分类不能指向自身或形成循环层级', 1;
END;
GO
-- 库存数量只能在业务过程临时授权的会话中修改；MinQuantity 仍可直接维护。
CREATE OR ALTER TRIGGER dbo.tr_Inventory_QuantityGuard ON dbo.Inventory AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE(Quantity)
       AND EXISTS (
           SELECT 1
           FROM inserted AS i
           JOIN deleted AS d ON d.ProductID=i.ProductID
           WHERE i.Quantity<>d.Quantity
       )
       AND ISNULL(TRY_CONVERT(int,SESSION_CONTEXT(N'CampusStoreInventoryWrite')),0)<>1
        THROW 51011, N'库存数量只能通过采购入库或销售结算过程修改', 1;
END;
GO
-- 为已有 UpdatedAt 字段统一提供自动更新时间。
CREATE OR ALTER TRIGGER dbo.tr_Category_SetUpdatedAt ON dbo.Category AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    UPDATE c SET UpdatedAt=SYSDATETIME()
    FROM dbo.Category AS c JOIN inserted AS i ON i.CategoryID=c.CategoryID;
END;
GO
CREATE OR ALTER TRIGGER dbo.tr_Supplier_SetUpdatedAt ON dbo.Supplier AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    UPDATE s SET UpdatedAt=SYSDATETIME()
    FROM dbo.Supplier AS s JOIN inserted AS i ON i.SupplierID=s.SupplierID;
END;
GO
CREATE OR ALTER TRIGGER dbo.tr_Product_SetUpdatedAt ON dbo.Product AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    UPDATE p SET UpdatedAt=SYSDATETIME()
    FROM dbo.Product AS p JOIN inserted AS i ON i.ProductID=p.ProductID;
END;
GO
CREATE OR ALTER TRIGGER dbo.tr_Inventory_SetUpdatedAt ON dbo.Inventory AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    UPDATE i SET UpdatedAt=SYSDATETIME()
    FROM dbo.Inventory AS i JOIN inserted AS n ON n.ProductID=i.ProductID;
END;
GO
CREATE OR ALTER TRIGGER dbo.tr_PurchaseOrder_SetUpdatedAt ON dbo.PurchaseOrder AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    UPDATE po SET UpdatedAt=SYSDATETIME()
    FROM dbo.PurchaseOrder AS po JOIN inserted AS i ON i.PurchaseID=po.PurchaseID;
END;
GO
-- 订单状态只允许草稿取消，或由对应确认过程完成。
-- 管理员可维护对象；普通业务账号不应获得表结构或触发器修改权限。
CREATE OR ALTER TRIGGER dbo.tr_PurchaseOrder_StatusGuard ON dbo.PurchaseOrder
AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    -- 新订单只能以草稿创建；即使显式指定终态，也必须经过确认过程。
    IF EXISTS (
        SELECT 1 FROM inserted AS i
        LEFT JOIN deleted AS d ON d.PurchaseID=i.PurchaseID
        WHERE d.PurchaseID IS NULL AND i.Status<>'DRAFT'
    ) THROW 51221, N'新增采购单必须为草稿', 1;
    IF EXISTS (
        SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.PurchaseID=i.PurchaseID
        WHERE d.Status<>'DRAFT' AND
            (i.SupplierID<>d.SupplierID OR i.EmployeeID<>d.EmployeeID
             OR i.PurchaseNo<>d.PurchaseNo OR i.TotalAmount<>d.TotalAmount)
    ) THROW 51222, N'非草稿采购单的业务编号、金额和参与方不可修改', 1;
    IF EXISTS (
        SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.PurchaseID=i.PurchaseID
        WHERE i.Status<>d.Status AND NOT (
            d.Status='DRAFT' AND (
                i.Status='CANCELLED' OR
                (i.Status='RECEIVED' AND
                 TRY_CONVERT(bigint,SESSION_CONTEXT(N'CampusStorePurchaseConfirm'))=i.PurchaseID)
            )
        )
    ) THROW 51220, N'采购单状态不可直接更改或回退', 1;
END;
GO
CREATE OR ALTER TRIGGER dbo.tr_SaleOrder_StatusGuard ON dbo.SaleOrder
AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1 FROM inserted AS i
        LEFT JOIN deleted AS d ON d.SaleID=i.SaleID
        WHERE d.SaleID IS NULL AND i.Status<>'DRAFT'
    ) THROW 51321, N'新增销售单必须为草稿', 1;
    IF EXISTS (
        SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.SaleID=i.SaleID
        WHERE d.Status<>'DRAFT' AND
            (i.EmployeeID<>d.EmployeeID OR i.SaleNo<>d.SaleNo
             OR i.TotalAmount<>d.TotalAmount OR i.DiscountAmount<>d.DiscountAmount
             OR ISNULL(i.PaymentMethod,'')<>ISNULL(d.PaymentMethod,''))
    ) THROW 51322, N'非草稿销售单的业务编号、金额、员工和支付方式不可修改', 1;
    IF EXISTS (
        SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.SaleID=i.SaleID
        WHERE i.Status<>d.Status AND NOT (
            d.Status='DRAFT' AND (
                i.Status='CANCELLED' OR
                (i.Status='COMPLETED' AND
                 TRY_CONVERT(bigint,SESSION_CONTEXT(N'CampusStoreSaleComplete'))=i.SaleID)
            )
        )
    ) THROW 51320, N'销售单状态不可直接更改或回退', 1;
END;
GO
CREATE OR ALTER TRIGGER dbo.tr_PurchaseItem_DraftOnly ON dbo.PurchaseItem
AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1 FROM (
            SELECT PurchaseID FROM inserted UNION SELECT PurchaseID FROM deleted
        ) AS changed JOIN dbo.PurchaseOrder AS po ON po.PurchaseID=changed.PurchaseID
        WHERE po.Status <> 'DRAFT'
    ) THROW 51210, N'仅草稿采购单可以修改明细', 1;
END;
GO
CREATE OR ALTER TRIGGER dbo.tr_SaleItem_DraftOnly ON dbo.SaleItem
AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1 FROM (
            SELECT SaleID FROM inserted UNION SELECT SaleID FROM deleted
        ) AS changed JOIN dbo.SaleOrder AS so ON so.SaleID=changed.SaleID
        WHERE so.Status <> 'DRAFT'
    ) THROW 51310, N'仅草稿销售单可以修改明细', 1;
END;
GO
CREATE OR ALTER PROCEDURE dbo.ConfirmPurchase @PurchaseID bigint AS
BEGIN
    SET NOCOUNT ON;
    -- 业务校验失败保留可提交的外层事务；不可提交事务交由调用者整体回滚。
    SET XACT_ABORT OFF;
    DECLARE @entryTranCount int=@@TRANCOUNT, @savePointCreated bit=0;
    DECLARE @status varchar(20), @businessNo varchar(30), @employeeID bigint, @supplierID bigint;
    DECLARE @total decimal(12,2), @productID bigint, @quantity int, @before int;
    BEGIN TRY
        IF @entryTranCount=0 BEGIN TRAN;
        ELSE
        BEGIN
            SAVE TRAN ConfirmPurchaseSave;
            SET @savePointCreated=1;
        END;
        -- 锁定订单，阻止两个会话同时确认同一张草稿。
        SELECT @status=Status, @businessNo=PurchaseNo, @employeeID=EmployeeID, @supplierID=SupplierID
        FROM dbo.PurchaseOrder WITH (UPDLOCK,HOLDLOCK) WHERE PurchaseID=@PurchaseID;
        IF @status IS NULL OR @status <> 'DRAFT'
            THROW 51200, N'采购单不存在或不是草稿', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Employee WITH (UPDLOCK,HOLDLOCK)
                       WHERE EmployeeID=@employeeID AND Status=1
                         AND RoleName IN ('PURCHASER','ADMIN'))
            THROW 51203, N'采购经办员工未启用或无采购职责', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Supplier WITH (UPDLOCK,HOLDLOCK)
                       WHERE SupplierID=@supplierID AND Status=1)
            THROW 51204, N'采购供应商已停用', 1;
        -- 保持明细行及相应键范围的锁直到事务结束，防止总额与库存读取不同版本。
        SELECT @total=SUM(LineAmount) FROM dbo.PurchaseItem WITH (UPDLOCK,HOLDLOCK)
        WHERE PurchaseID=@PurchaseID;
        IF @total IS NULL THROW 51201, N'采购单没有明细', 1;

        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=1;

        DECLARE items CURSOR LOCAL FAST_FORWARD FOR
            SELECT ProductID,Quantity FROM dbo.PurchaseItem
            WHERE PurchaseID=@PurchaseID ORDER BY ProductID;
        OPEN items;
        FETCH NEXT FROM items INTO @productID,@quantity;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @before=NULL;
            SELECT @before=Quantity FROM dbo.Inventory WITH (UPDLOCK,HOLDLOCK)
            WHERE ProductID=@productID;
            IF @before IS NULL THROW 51202, N'商品缺少库存记录', 1;
            UPDATE dbo.Inventory SET Quantity=@before+@quantity,
                UpdatedAt=SYSDATETIME() WHERE ProductID=@productID;
            INSERT dbo.InventoryLog(ProductID,ChangeType,ChangeQuantity,
                BeforeQuantity,AfterQuantity,BusinessNo,EmployeeID)
            VALUES (@productID,'PURCHASE_IN',@quantity,
                @before,@before+@quantity,@businessNo,@employeeID);
            FETCH NEXT FROM items INTO @productID,@quantity;
        END;
        CLOSE items;
        DEALLOCATE items;
        EXEC sys.sp_set_session_context @key=N'CampusStorePurchaseConfirm', @value=@PurchaseID;
        UPDATE dbo.PurchaseOrder SET TotalAmount=@total,Status='RECEIVED',
            ReceivedTime=SYSDATETIME(),UpdatedAt=SYSDATETIME()
        WHERE PurchaseID=@PurchaseID;
        EXEC sys.sp_set_session_context @key=N'CampusStorePurchaseConfirm', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=NULL;
        IF @entryTranCount=0 COMMIT;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local','items') >= 0 CLOSE items;
        IF CURSOR_STATUS('local','items') >= -1 DEALLOCATE items;
        IF @entryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @entryTranCount>0 AND XACT_STATE()=1 AND @savePointCreated=1
            ROLLBACK TRAN ConfirmPurchaseSave;
        -- XACT_STATE()=-1 时不能回滚保存点，外层调用者必须整体 ROLLBACK。
        EXEC sys.sp_set_session_context @key=N'CampusStorePurchaseConfirm', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=NULL;
        THROW;
    END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.CompleteSale @SaleID bigint AS
BEGIN
    SET NOCOUNT ON;
    -- 业务校验失败保留可提交的外层事务；不可提交事务交由调用者整体回滚。
    SET XACT_ABORT OFF;
    DECLARE @entryTranCount int=@@TRANCOUNT, @savePointCreated bit=0;
    DECLARE @status varchar(20), @businessNo varchar(30), @employeeID bigint;
    DECLARE @payment varchar(20), @discount decimal(12,2), @total decimal(12,2);
    DECLARE @productID bigint, @quantity int, @before int;
    BEGIN TRY
        IF @entryTranCount=0 BEGIN TRAN;
        ELSE
        BEGIN
            SAVE TRAN CompleteSaleSave;
            SET @savePointCreated=1;
        END;
        SELECT @status=Status,@businessNo=SaleNo,@employeeID=EmployeeID,
               @payment=PaymentMethod,@discount=DiscountAmount
        FROM dbo.SaleOrder WITH (UPDLOCK,HOLDLOCK) WHERE SaleID=@SaleID;
        IF @status IS NULL OR @status <> 'DRAFT'
            THROW 51300, N'销售单不存在或不是草稿', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Employee WITH (UPDLOCK,HOLDLOCK)
                       WHERE EmployeeID=@employeeID AND Status=1
                         AND RoleName IN ('CASHIER','ADMIN'))
            THROW 51306, N'销售经办员工未启用或无收银职责', 1;
        IF @payment IS NULL THROW 51301, N'结算前需选择支付方式', 1;
        SELECT @total=SUM(LineAmount) FROM dbo.SaleItem WITH (UPDLOCK,HOLDLOCK)
        WHERE SaleID=@SaleID;
        IF @total IS NULL THROW 51302, N'销售单没有明细', 1;
        IF @discount > @total THROW 51303, N'优惠金额超过商品总额', 1;
        IF EXISTS (SELECT 1 FROM dbo.SaleItem AS si JOIN dbo.Product AS p WITH (HOLDLOCK)
                   ON p.ProductID=si.ProductID
                   WHERE si.SaleID=@SaleID AND p.Status=0)
            THROW 51304, N'销售单含停用商品', 1;

        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=1;

        DECLARE items CURSOR LOCAL FAST_FORWARD FOR
            SELECT ProductID,Quantity FROM dbo.SaleItem
            WHERE SaleID=@SaleID ORDER BY ProductID;
        OPEN items;
        FETCH NEXT FROM items INTO @productID,@quantity;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @before=NULL;
            SELECT @before=Quantity FROM dbo.Inventory WITH (UPDLOCK,HOLDLOCK)
            WHERE ProductID=@productID;
            IF @before IS NULL OR @before < @quantity
                THROW 51305, N'商品库存不足', 1;
            UPDATE dbo.Inventory SET Quantity=@before-@quantity,
                UpdatedAt=SYSDATETIME() WHERE ProductID=@productID;
            INSERT dbo.InventoryLog(ProductID,ChangeType,ChangeQuantity,
                BeforeQuantity,AfterQuantity,BusinessNo,EmployeeID)
            VALUES (@productID,'SALE_OUT',-@quantity,
                @before,@before-@quantity,@businessNo,@employeeID);
            FETCH NEXT FROM items INTO @productID,@quantity;
        END;
        CLOSE items;
        DEALLOCATE items;
        EXEC sys.sp_set_session_context @key=N'CampusStoreSaleComplete', @value=@SaleID;
        UPDATE dbo.SaleOrder SET TotalAmount=@total,Status='COMPLETED',
            SaleTime=SYSDATETIME() WHERE SaleID=@SaleID;
        EXEC sys.sp_set_session_context @key=N'CampusStoreSaleComplete', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=NULL;
        IF @entryTranCount=0 COMMIT;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local','items') >= 0 CLOSE items;
        IF CURSOR_STATUS('local','items') >= -1 DEALLOCATE items;
        IF @entryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @entryTranCount>0 AND XACT_STATE()=1 AND @savePointCreated=1
            ROLLBACK TRAN CompleteSaleSave;
        -- XACT_STATE()=-1 时不能回滚保存点，外层调用者必须整体 ROLLBACK。
        EXEC sys.sp_set_session_context @key=N'CampusStoreSaleComplete', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=NULL;
        THROW;
    END CATCH;
END;
GO

-- 查询入口按业务角色授权；未实现按员工隔离订单。
CREATE OR ALTER PROCEDURE dbo.QueryPurchaseOrders @PurchaseID bigint=NULL AS
BEGIN
    SET NOCOUNT ON;
    SELECT po.PurchaseID,po.PurchaseNo,po.SupplierID,po.EmployeeID,po.Status,po.TotalAmount,
           CASE WHEN po.Status='DRAFT' THEN COALESCE(d.Amount,0) END AS DraftAmount
    FROM dbo.PurchaseOrder AS po
    OUTER APPLY (SELECT SUM(pi.LineAmount) AS Amount FROM dbo.PurchaseItem AS pi
                 WHERE pi.PurchaseID=po.PurchaseID) AS d
    WHERE @PurchaseID IS NULL OR po.PurchaseID=@PurchaseID
    ORDER BY po.PurchaseID;
END;
GO
CREATE OR ALTER PROCEDURE dbo.QuerySaleOrders @SaleID bigint=NULL AS
BEGIN
    SET NOCOUNT ON;
    SELECT so.SaleID,so.SaleNo,so.EmployeeID,so.Status,so.PaymentMethod,so.DiscountAmount,
           so.TotalAmount,
           CASE WHEN so.Status='COMPLETED' THEN so.PayableAmount END AS PayableAmount,
           CASE WHEN so.Status='DRAFT' THEN COALESCE(d.Amount,0) END AS DraftAmount
    FROM dbo.SaleOrder AS so
    OUTER APPLY (SELECT SUM(si.LineAmount) AS Amount FROM dbo.SaleItem AS si
                 WHERE si.SaleID=so.SaleID) AS d
    WHERE @SaleID IS NULL OR so.SaleID=@SaleID
    ORDER BY so.SaleID;
END;
GO
-- 参数明确覆盖支付方式、优惠和备注；不允许改编号、经办人或结算总额。
CREATE OR ALTER PROCEDURE dbo.UpdateSaleDraft
    @SaleID bigint,@PaymentMethod varchar(20),@DiscountAmount decimal(12,2),
    @Remark nvarchar(255)=NULL AS
BEGIN
    SET NOCOUNT ON;
    -- 业务校验失败保留可提交的外层事务；不可提交事务交由调用者整体回滚。
    SET XACT_ABORT OFF;
    DECLARE @entryTranCount int=@@TRANCOUNT, @savePointCreated bit=0;
    IF @DiscountAmount IS NULL OR @DiscountAmount<0
        THROW 51401,N'优惠金额必须非空且不小于零',1;
    IF @PaymentMethod IS NOT NULL AND @PaymentMethod NOT IN ('CASH','WECHAT','ALIPAY','BANK_CARD')
        THROW 51402,N'支付方式无效',1;
    BEGIN TRY
        IF @entryTranCount=0 BEGIN TRAN;
        ELSE
        BEGIN
            SAVE TRAN UpdateSaleDraftSave;
            SET @savePointCreated=1;
        END;
        DECLARE @status varchar(20);
        SELECT @status=Status FROM dbo.SaleOrder WITH (UPDLOCK,HOLDLOCK) WHERE SaleID=@SaleID;
        IF @status IS NULL OR @status<>'DRAFT'
            THROW 51400,N'仅草稿销售单可以修改',1;
        UPDATE dbo.SaleOrder SET PaymentMethod=@PaymentMethod,
               DiscountAmount=@DiscountAmount,Remark=@Remark WHERE SaleID=@SaleID;
        IF @entryTranCount=0 COMMIT;
    END TRY
    BEGIN CATCH
        IF @entryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @entryTranCount>0 AND XACT_STATE()=1 AND @savePointCreated=1
            ROLLBACK TRAN UpdateSaleDraftSave;
        -- XACT_STATE()=-1 时不能回滚保存点，外层调用者必须整体 ROLLBACK。
        THROW;
    END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.CancelPurchase @PurchaseID bigint AS
BEGIN
    SET NOCOUNT ON;
    -- 业务校验失败保留可提交的外层事务；不可提交事务交由调用者整体回滚。
    SET XACT_ABORT OFF;
    DECLARE @entryTranCount int=@@TRANCOUNT, @savePointCreated bit=0;
    BEGIN TRY
        IF @entryTranCount=0 BEGIN TRAN;
        ELSE
        BEGIN
            SAVE TRAN CancelPurchaseSave;
            SET @savePointCreated=1;
        END;
        DECLARE @status varchar(20);
        SELECT @status=Status FROM dbo.PurchaseOrder WITH (UPDLOCK,HOLDLOCK) WHERE PurchaseID=@PurchaseID;
        IF @status IS NULL OR @status<>'DRAFT'
            THROW 51410,N'仅草稿采购单可以取消',1;
        UPDATE dbo.PurchaseOrder SET Status='CANCELLED' WHERE PurchaseID=@PurchaseID;
        IF @entryTranCount=0 COMMIT;
    END TRY
    BEGIN CATCH
        IF @entryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @entryTranCount>0 AND XACT_STATE()=1 AND @savePointCreated=1
            ROLLBACK TRAN CancelPurchaseSave;
        -- XACT_STATE()=-1 时不能回滚保存点，外层调用者必须整体 ROLLBACK。
        THROW;
    END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.CancelSale @SaleID bigint AS
BEGIN
    SET NOCOUNT ON;
    -- 业务校验失败保留可提交的外层事务；不可提交事务交由调用者整体回滚。
    SET XACT_ABORT OFF;
    DECLARE @entryTranCount int=@@TRANCOUNT, @savePointCreated bit=0;
    BEGIN TRY
        IF @entryTranCount=0 BEGIN TRAN;
        ELSE
        BEGIN
            SAVE TRAN CancelSaleSave;
            SET @savePointCreated=1;
        END;
        DECLARE @status varchar(20);
        SELECT @status=Status FROM dbo.SaleOrder WITH (UPDLOCK,HOLDLOCK) WHERE SaleID=@SaleID;
        IF @status IS NULL OR @status<>'DRAFT'
            THROW 51411,N'仅草稿销售单可以取消',1;
        UPDATE dbo.SaleOrder SET Status='CANCELLED' WHERE SaleID=@SaleID;
        IF @entryTranCount=0 COMMIT;
    END TRY
    BEGIN CATCH
        IF @entryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @entryTranCount>0 AND XACT_STATE()=1 AND @savePointCreated=1
            ROLLBACK TRAN CancelSaleSave;
        -- XACT_STATE()=-1 时不能回滚保存点，外层调用者必须整体 ROLLBACK。
        THROW;
    END CATCH;
END;
GO
