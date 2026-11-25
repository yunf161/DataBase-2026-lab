/* 第十一周：触发器。可重复执行。
   1. dbo.tr_Inventory_Audit：库存表插入、修改、删除时自动写审计记录，一条语句改多行时逐行记录。
   2. dbo.tr_SaleOrder_CompleteRule：订单改为已完成时检查明细、商品、数量、库存扣减和金额，不满足就拒绝；
      已完成的订单不能再次“完成”。
   触发器只做记录和检查，不扣库存、不提交事务；库存扣减只在 dbo.usp_CompleteOrder / dbo.usp_ReceiveRestock 中进行。
   审计记录随业务事务一起提交或回滚，因此不能当作失败日志使用。 */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]%'
    THROW 51700,N'第十至十二周对象只部署到独立 W7 应用数据库',1;
IF COL_LENGTH(N'dbo.SaleOrder',N'DiscountRate') IS NULL
    THROW 51700,N'请先部署 sql/week10/procedure.sql',1;
GO
-- 审计表不加商品外键：商品被安全删除后，它的审计记录仍要保留。
-- 操作人员也不加外键：员工编号取自会话上下文，写错不能反过来阻止库存业务。
IF OBJECT_ID(N'dbo.InventoryAudit',N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InventoryAudit(
        AuditID bigint IDENTITY(1,1) PRIMARY KEY,
        ProductID bigint NOT NULL,
        OperationType varchar(12) NOT NULL,
        BeforeQuantity int NULL,
        AfterQuantity int NULL,
        ChangeQuantity int NOT NULL,
        BeforeMinQuantity int NULL,
        AfterMinQuantity int NULL,
        OperatorEmployeeID bigint NULL,
        AppUserID bigint NULL,
        DatabaseUser sysname NOT NULL,
        LoginName sysname NOT NULL,
        OperatedAt datetime2(3) NOT NULL CONSTRAINT DF_InventoryAudit_OperatedAt DEFAULT SYSDATETIME(),
        CONSTRAINT CK_InventoryAudit_Type CHECK (OperationType IN ('INSERT','INCREASE','DECREASE','MODIFY','DELETE'))
    );
    CREATE INDEX IX_InventoryAudit_Product ON dbo.InventoryAudit(ProductID,AuditID);
END;
GO
/* 操作类型：INSERT 新建库存行；INCREASE / DECREASE 数量增加或减少；MODIFY 只改了预警下限；DELETE 删除库存行。
   操作人员：优先取业务过程写入的会话标记 CampusStoreOperator（员工 ID）；没有时取网页登录账号对应的员工；
   另外保存数据库用户和登录名，直接在数据库里改的也能看出是谁。
   只改 UpdatedAt 的更新（例如 tr_Inventory_SetUpdatedAt 自己触发的那次）数量和下限都没变，不记录。 */
CREATE OR ALTER TRIGGER dbo.tr_Inventory_Audit ON dbo.Inventory
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    DECLARE @user bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'WebUserID'));
    DECLARE @operator bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'CampusStoreOperator'));
    IF @operator IS NULL AND @user IS NOT NULL
        SELECT @operator=EmployeeID FROM app.AppUser WHERE UserID=@user;

    INSERT dbo.InventoryAudit(ProductID,OperationType,BeforeQuantity,AfterQuantity,ChangeQuantity,
                              BeforeMinQuantity,AfterMinQuantity,OperatorEmployeeID,AppUserID,DatabaseUser,LoginName)
    SELECT COALESCE(i.ProductID,d.ProductID),
           CASE WHEN d.ProductID IS NULL THEN 'INSERT'
                WHEN i.ProductID IS NULL THEN 'DELETE'
                WHEN i.Quantity>d.Quantity THEN 'INCREASE'
                WHEN i.Quantity<d.Quantity THEN 'DECREASE'
                ELSE 'MODIFY' END,
           d.Quantity, i.Quantity, COALESCE(i.Quantity,0)-COALESCE(d.Quantity,0),
           d.MinQuantity, i.MinQuantity, @operator, @user, USER_NAME(), ORIGINAL_LOGIN()
    FROM inserted AS i
    FULL OUTER JOIN deleted AS d ON d.ProductID=i.ProductID
    WHERE d.ProductID IS NULL OR i.ProductID IS NULL
       OR i.Quantity<>d.Quantity OR i.MinQuantity<>d.MinQuantity;
END;
GO
/* 订单完成规则。只看本次由“非已完成”变成“已完成”的行，一次处理多行：
   51750 没有明细；51752 含停用商品或非法数量；51753 库存没有按明细扣减（每个商品的销售出库流水合计必须正好等于购买数量，
   少扣、多扣、重复扣都会被拒绝）；51754 订单金额不等于明细合计；51755 折扣金额为负、超过总额或与折扣率不符。
   51751：已完成的订单再次被设为已完成。51756：已完成或已取消订单的折扣率被修改。
   与 tr_SaleOrder_StatusGuard（只允许经过结算过程完成）配合：本触发器设为 UPDATE 的第一个触发器，先给出具体原因。 */
CREATE OR ALTER TRIGGER dbo.tr_SaleOrder_CompleteRule ON dbo.SaleOrder
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE(DiscountRate) AND EXISTS (
        SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.SaleID=i.SaleID
        WHERE d.Status<>'DRAFT' AND ISNULL(i.DiscountRate,-1)<>ISNULL(d.DiscountRate,-1))
        THROW 51756,N'已完成或已取消订单的折扣率不可修改',1;
    IF NOT UPDATE(Status) RETURN;
    IF EXISTS (SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.SaleID=i.SaleID
               WHERE d.Status='COMPLETED' AND i.Status='COMPLETED')
        THROW 51751,N'订单已经完成，不能重复完成',1;

    DECLARE @done TABLE(SaleID bigint PRIMARY KEY, TotalAmount decimal(12,2) NOT NULL,
                        DiscountAmount decimal(12,2) NOT NULL, DiscountRate decimal(5,4) NULL);
    INSERT @done(SaleID,TotalAmount,DiscountAmount,DiscountRate)
    SELECT i.SaleID,i.TotalAmount,i.DiscountAmount,i.DiscountRate
    FROM inserted AS i JOIN deleted AS d ON d.SaleID=i.SaleID
    WHERE i.Status='COMPLETED' AND d.Status<>'COMPLETED';
    IF @@ROWCOUNT=0 RETURN;

    IF EXISTS (SELECT 1 FROM @done AS x
               WHERE NOT EXISTS (SELECT 1 FROM dbo.SaleItem AS si WHERE si.SaleID=x.SaleID))
        THROW 51750,N'订单没有明细，不能完成',1;
    IF EXISTS (SELECT 1 FROM @done AS x
               JOIN dbo.SaleItem AS si ON si.SaleID=x.SaleID
               JOIN dbo.Product AS p ON p.ProductID=si.ProductID
               WHERE p.Status=0 OR si.Quantity<=0)
        THROW 51752,N'订单含已停用商品或非法购买数量，不能完成',1;
    IF EXISTS (SELECT 1 FROM @done AS x
               JOIN dbo.SaleItem AS si ON si.SaleID=x.SaleID
               OUTER APPLY (SELECT -SUM(l.ChangeQuantity) AS Deducted FROM dbo.InventoryLog AS l
                            WHERE l.SaleID=x.SaleID AND l.ProductID=si.ProductID AND l.ChangeType='SALE_OUT') AS o
               WHERE o.Deducted IS NULL OR o.Deducted<>si.Quantity)
        THROW 51753,N'订单商品的库存没有按明细扣减，不能完成',1;
    IF EXISTS (SELECT 1 FROM @done AS x
               CROSS APPLY (SELECT SUM(si.LineAmount) AS Amount FROM dbo.SaleItem AS si WHERE si.SaleID=x.SaleID) AS s
               WHERE x.TotalAmount<>s.Amount)
        THROW 51754,N'订单金额与明细合计不一致，不能完成',1;
    IF EXISTS (SELECT 1 FROM @done AS x
               WHERE x.DiscountAmount<0 OR x.DiscountAmount>x.TotalAmount
                  OR (x.DiscountRate IS NOT NULL
                      AND x.DiscountAmount<>CONVERT(decimal(12,2),ROUND(x.TotalAmount*x.DiscountRate,2))))
        THROW 51755,N'订单折扣金额非法，不能完成',1;
END;
GO
EXEC sys.sp_settriggerorder @triggername=N'dbo.tr_SaleOrder_CompleteRule', @order=N'First', @stmttype=N'UPDATE';
GO
PRINT N'第十一周触发器已部署：tr_Inventory_Audit、tr_SaleOrder_CompleteRule';
