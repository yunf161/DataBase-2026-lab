/* 订单确认是库存变化的业务入口；每个过程独立开启并提交事务。 */
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
AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
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
AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
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
    SET XACT_ABORT ON;
    DECLARE @status varchar(20), @businessNo varchar(30), @employeeID bigint;
    DECLARE @total decimal(12,2), @productID bigint, @quantity int, @before int;
    BEGIN TRY
        BEGIN TRAN;
        -- 锁定订单，阻止两个会话同时确认同一张草稿。
        SELECT @status=Status, @businessNo=PurchaseNo, @employeeID=EmployeeID
        FROM dbo.PurchaseOrder WITH (UPDLOCK,HOLDLOCK) WHERE PurchaseID=@PurchaseID;
        IF @status IS NULL OR @status <> 'DRAFT'
            THROW 51200, N'采购单不存在或不是草稿', 1;
        SELECT @total=SUM(LineAmount) FROM dbo.PurchaseItem WHERE PurchaseID=@PurchaseID;
        IF @total IS NULL THROW 51201, N'采购单没有明细', 1;

        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=1;

        DECLARE items CURSOR LOCAL FAST_FORWARD FOR
            SELECT ProductID,Quantity FROM dbo.PurchaseItem
            WHERE PurchaseID=@PurchaseID ORDER BY ProductID;
        OPEN items;
        FETCH NEXT FROM items INTO @productID,@quantity;
        WHILE @@FETCH_STATUS=0
        BEGIN
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
        COMMIT;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local','items') >= 0 CLOSE items;
        IF CURSOR_STATUS('local','items') >= -1 DEALLOCATE items;
        IF XACT_STATE() <> 0 ROLLBACK;
        EXEC sys.sp_set_session_context @key=N'CampusStorePurchaseConfirm', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=NULL;
        THROW;
    END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE dbo.CompleteSale @SaleID bigint AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @status varchar(20), @businessNo varchar(30), @employeeID bigint;
    DECLARE @payment varchar(20), @discount decimal(12,2), @total decimal(12,2);
    DECLARE @productID bigint, @quantity int, @before int;
    BEGIN TRY
        BEGIN TRAN;
        SELECT @status=Status,@businessNo=SaleNo,@employeeID=EmployeeID,
               @payment=PaymentMethod,@discount=DiscountAmount
        FROM dbo.SaleOrder WITH (UPDLOCK,HOLDLOCK) WHERE SaleID=@SaleID;
        IF @status IS NULL OR @status <> 'DRAFT'
            THROW 51300, N'销售单不存在或不是草稿', 1;
        IF @payment IS NULL THROW 51301, N'结算前需选择支付方式', 1;
        SELECT @total=SUM(LineAmount) FROM dbo.SaleItem WHERE SaleID=@SaleID;
        IF @total IS NULL THROW 51302, N'销售单没有明细', 1;
        IF @discount > @total THROW 51303, N'优惠金额超过商品总额', 1;
        IF EXISTS (SELECT 1 FROM dbo.SaleItem AS si JOIN dbo.Product AS p
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
        COMMIT;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local','items') >= 0 CLOSE items;
        IF CURSOR_STATUS('local','items') >= -1 DEALLOCATE items;
        IF XACT_STATE() <> 0 ROLLBACK;
        EXEC sys.sp_set_session_context @key=N'CampusStoreSaleComplete', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=NULL;
        THROW;
    END CATCH;
END;
GO
