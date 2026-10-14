/* 第六周：v0.1 -> v1.0 迁移。只在已经备份/复制的数据库中运行一次。 */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W6[_]%'
    THROW 51609, N'第六周迁移只能在名称为 CampusStoreDB_W6_* 的数据库副本运行', 1;

IF COL_LENGTH(N'dbo.InventoryLog',N'BusinessNo') IS NULL
    THROW 51610, N'迁移前检查失败：缺少 InventoryLog.BusinessNo，可能已经迁移', 1;
IF COL_LENGTH(N'dbo.InventoryLog',N'PurchaseID') IS NOT NULL
    THROW 51611, N'迁移前检查失败：PurchaseID 已存在，禁止重复迁移', 1;
IF OBJECT_ID(N'week6.BaselineMetric',N'U') IS NULL
    THROW 51612, N'尚未运行 sql/week6/baseline.sql', 1;
BEGIN TRY
    BEGIN TRAN;

    /* 在事务内锁定来源数据，避免检查通过后又被并发修改。 */
    DECLARE @invalidOrigin bit=0;
    EXEC sys.sp_executesql N'SELECT @bad=IIF(EXISTS (
        SELECT 1 FROM dbo.InventoryLog AS il WITH (UPDLOCK,HOLDLOCK)
        WHERE (il.ChangeType IN (''PURCHASE_IN'',''PURCHASE_RETURN'') AND
               (il.BusinessNo IS NULL OR (SELECT COUNT(*) FROM dbo.PurchaseOrder AS po WITH (HOLDLOCK) WHERE po.PurchaseNo=il.BusinessNo)<>1))
           OR (il.ChangeType IN (''SALE_OUT'',''SALE_RETURN'') AND
               (il.BusinessNo IS NULL OR (SELECT COUNT(*) FROM dbo.SaleOrder AS so WITH (HOLDLOCK) WHERE so.SaleNo=il.BusinessNo)<>1))
           OR (il.ChangeType IN (''STOCKTAKE_IN'',''STOCKTAKE_OUT'') AND il.BusinessNo IS NOT NULL)
    ),1,0)',N'@bad bit OUTPUT',@bad=@invalidOrigin OUTPUT;
    IF @invalidOrigin=1
        THROW 51613, N'迁移前检查失败：流水单号无法唯一映射，或盘点流水含非空业务单号', 1;

    ALTER TABLE dbo.InventoryLog ADD PurchaseID bigint NULL, SaleID bigint NULL;

    /* SQL Server 会预编译同一批次，新增列的首次引用需放入后编译的动态批次。 */
    EXEC(N'UPDATE il SET PurchaseID=po.PurchaseID
          FROM dbo.InventoryLog AS il
          JOIN dbo.PurchaseOrder AS po ON po.PurchaseNo=il.BusinessNo
          WHERE il.ChangeType IN (''PURCHASE_IN'',''PURCHASE_RETURN'');
          UPDATE il SET SaleID=so.SaleID
          FROM dbo.InventoryLog AS il
          JOIN dbo.SaleOrder AS so ON so.SaleNo=il.BusinessNo
          WHERE il.ChangeType IN (''SALE_OUT'',''SALE_RETURN'');');

    DECLARE @invalidSource bit=0;
    EXEC sys.sp_executesql N'SELECT @bad=IIF(EXISTS(
        SELECT 1 FROM dbo.InventoryLog
        WHERE (ChangeType IN (''PURCHASE_IN'',''PURCHASE_RETURN'') AND (PurchaseID IS NULL OR SaleID IS NOT NULL))
           OR (ChangeType IN (''SALE_OUT'',''SALE_RETURN'') AND (SaleID IS NULL OR PurchaseID IS NOT NULL))
           OR (ChangeType IN (''STOCKTAKE_IN'',''STOCKTAKE_OUT'') AND (PurchaseID IS NOT NULL OR SaleID IS NOT NULL))
    ),1,0)',N'@bad bit OUTPUT',@bad=@invalidSource OUTPUT;
    IF @invalidSource=1 THROW 51614, N'回填结果不完整，迁移已回滚', 1;

    EXEC(N'ALTER TABLE dbo.InventoryLog WITH CHECK ADD
        CONSTRAINT FK_InventoryLog_PurchaseOrder FOREIGN KEY(PurchaseID) REFERENCES dbo.PurchaseOrder(PurchaseID),
        CONSTRAINT FK_InventoryLog_SaleOrder FOREIGN KEY(SaleID) REFERENCES dbo.SaleOrder(SaleID),
        CONSTRAINT CK_InventoryLog_Source CHECK (
            (ChangeType IN (''PURCHASE_IN'',''PURCHASE_RETURN'') AND PurchaseID IS NOT NULL AND SaleID IS NULL)
         OR (ChangeType IN (''SALE_OUT'',''SALE_RETURN'') AND SaleID IS NOT NULL AND PurchaseID IS NULL)
         OR (ChangeType IN (''STOCKTAKE_IN'',''STOCKTAKE_OUT'') AND PurchaseID IS NULL AND SaleID IS NULL)
        ),
        CONSTRAINT CK_InventoryLog_Direction CHECK (
            (ChangeType IN (''PURCHASE_IN'',''SALE_RETURN'',''STOCKTAKE_IN'') AND ChangeQuantity>0)
         OR (ChangeType IN (''SALE_OUT'',''PURCHASE_RETURN'',''STOCKTAKE_OUT'') AND ChangeQuantity<0)
        );
        CREATE INDEX IX_InventoryLog_Purchase ON dbo.InventoryLog(PurchaseID) WHERE PurchaseID IS NOT NULL;
        CREATE INDEX IX_InventoryLog_Sale ON dbo.InventoryLog(SaleID) WHERE SaleID IS NOT NULL;');

    /* 基于已验证的 v0.1 过程定义做最小替换；替换失败即回滚。 */
    DECLARE @definition nvarchar(max);
    SET @definition=OBJECT_DEFINITION(OBJECT_ID(N'dbo.ConfirmPurchase',N'P'));
    IF @definition IS NULL THROW 51615, N'缺少 ConfirmPurchase', 1;
    IF UPPER(LEFT(LTRIM(@definition),6))<>N'CREATE'
        THROW 51619, N'ConfirmPurchase 定义开头不是 CREATE', 1;
    SET @definition=STUFF(@definition,CHARINDEX(N'CREATE',UPPER(@definition)),6,N'ALTER');
    SET @definition=REPLACE(@definition,
        N'BeforeQuantity,AfterQuantity,BusinessNo,EmployeeID',
        N'BeforeQuantity,AfterQuantity,PurchaseID,SaleID,EmployeeID');
    SET @definition=REPLACE(@definition,
        N'@before,@before+@quantity,@businessNo,@employeeID',
        N'@before,@before+@quantity,@PurchaseID,NULL,@employeeID');
    IF CHARINDEX(N'RoleName IN (''PURCHASER'',''ADMIN'')',@definition)=0
    BEGIN
        SET @definition=REPLACE(@definition,
            N'WHERE EmployeeID=@employeeID AND Status=1)',
            N'WHERE EmployeeID=@employeeID AND Status=1 AND RoleName IN (''PURCHASER'',''ADMIN''))');
        SET @definition=REPLACE(@definition,N'采购经办员工已停用',N'采购经办员工未启用或无采购职责');
    END;
    IF CHARINDEX(N'AfterQuantity,PurchaseID,SaleID,EmployeeID',@definition)=0
       OR CHARINDEX(N'@before,@before+@quantity,@PurchaseID,NULL,@employeeID',@definition)=0
       OR CHARINDEX(N'RoleName IN (''PURCHASER'',''ADMIN'')',@definition)=0
        THROW 51616, N'ConfirmPurchase 定义与预期 v0.1 不一致', 1;
    EXEC sys.sp_executesql @definition;

    SET @definition=OBJECT_DEFINITION(OBJECT_ID(N'dbo.CompleteSale',N'P'));
    IF @definition IS NULL THROW 51617, N'缺少 CompleteSale', 1;
    IF UPPER(LEFT(LTRIM(@definition),6))<>N'CREATE'
        THROW 51619, N'CompleteSale 定义开头不是 CREATE', 1;
    SET @definition=STUFF(@definition,CHARINDEX(N'CREATE',UPPER(@definition)),6,N'ALTER');
    SET @definition=REPLACE(@definition,
        N'BeforeQuantity,AfterQuantity,BusinessNo,EmployeeID',
        N'BeforeQuantity,AfterQuantity,PurchaseID,SaleID,EmployeeID');
    SET @definition=REPLACE(@definition,
        N'@before,@before-@quantity,@businessNo,@employeeID',
        N'@before,@before-@quantity,NULL,@SaleID,@employeeID');
    IF CHARINDEX(N'RoleName IN (''CASHIER'',''ADMIN'')',@definition)=0
    BEGIN
        SET @definition=REPLACE(@definition,
            N'WHERE EmployeeID=@employeeID AND Status=1)',
            N'WHERE EmployeeID=@employeeID AND Status=1 AND RoleName IN (''CASHIER'',''ADMIN''))');
        SET @definition=REPLACE(@definition,N'销售经办员工已停用',N'销售经办员工未启用或无收银职责');
    END;
    IF CHARINDEX(N'AfterQuantity,PurchaseID,SaleID,EmployeeID',@definition)=0
       OR CHARINDEX(N'@before,@before-@quantity,NULL,@SaleID,@employeeID',@definition)=0
       OR CHARINDEX(N'RoleName IN (''CASHIER'',''ADMIN'')',@definition)=0
        THROW 51618, N'CompleteSale 定义与预期 v0.1 不一致', 1;
    EXEC sys.sp_executesql @definition;

    /* 同步升级冻结基线的状态保护，显式排除 NULL/不可转换的过程标记。 */
    EXEC(N'CREATE OR ALTER TRIGGER dbo.tr_PurchaseOrder_StatusGuard ON dbo.PurchaseOrder
AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    -- 新订单只能以草稿创建；即使显式指定终态，也必须经过确认过程。
    IF EXISTS (
        SELECT 1 FROM inserted AS i
        LEFT JOIN deleted AS d ON d.PurchaseID=i.PurchaseID
        WHERE d.PurchaseID IS NULL AND i.Status<>''DRAFT''
    ) THROW 51221, N''新增采购单必须为草稿'', 1;
    IF EXISTS (
        SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.PurchaseID=i.PurchaseID
        WHERE d.Status<>''DRAFT'' AND
            (i.SupplierID<>d.SupplierID OR i.EmployeeID<>d.EmployeeID
             OR i.PurchaseNo<>d.PurchaseNo OR i.TotalAmount<>d.TotalAmount)
    ) THROW 51222, N''非草稿采购单的业务编号、金额和参与方不可修改'', 1;
    IF EXISTS (
        SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.PurchaseID=i.PurchaseID
        WHERE i.Status<>d.Status AND NOT (
            d.Status=''DRAFT'' AND (
                i.Status=''CANCELLED'' OR
                (i.Status=''RECEIVED'' AND
                 TRY_CONVERT(bigint,SESSION_CONTEXT(N''CampusStorePurchaseConfirm'')) IS NOT NULL AND
                 TRY_CONVERT(bigint,SESSION_CONTEXT(N''CampusStorePurchaseConfirm''))=i.PurchaseID)
            )
        )
    ) THROW 51220, N''采购单状态不可直接更改或回退'', 1;
END;');

    EXEC(N'CREATE OR ALTER TRIGGER dbo.tr_SaleOrder_StatusGuard ON dbo.SaleOrder
AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1 FROM inserted AS i
        LEFT JOIN deleted AS d ON d.SaleID=i.SaleID
        WHERE d.SaleID IS NULL AND i.Status<>''DRAFT''
    ) THROW 51321, N''新增销售单必须为草稿'', 1;
    IF EXISTS (
        SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.SaleID=i.SaleID
        WHERE d.Status<>''DRAFT'' AND
            (i.EmployeeID<>d.EmployeeID OR i.SaleNo<>d.SaleNo
             OR i.TotalAmount<>d.TotalAmount OR i.DiscountAmount<>d.DiscountAmount
             OR ISNULL(i.PaymentMethod,'''')<>ISNULL(d.PaymentMethod,''''))
    ) THROW 51322, N''非草稿销售单的业务编号、金额、员工和支付方式不可修改'', 1;
    IF EXISTS (
        SELECT 1 FROM inserted AS i JOIN deleted AS d ON d.SaleID=i.SaleID
        WHERE i.Status<>d.Status AND NOT (
            d.Status=''DRAFT'' AND (
                i.Status=''CANCELLED'' OR
                (i.Status=''COMPLETED'' AND
                 TRY_CONVERT(bigint,SESSION_CONTEXT(N''CampusStoreSaleComplete'')) IS NOT NULL AND
                 TRY_CONVERT(bigint,SESSION_CONTEXT(N''CampusStoreSaleComplete''))=i.SaleID)
            )
        )
    ) THROW 51320, N''销售单状态不可直接更改或回退'', 1;
END;');

    DROP INDEX IX_InventoryLog_BusinessNo ON dbo.InventoryLog;
    ALTER TABLE dbo.InventoryLog DROP COLUMN BusinessNo;

    EXEC(N'CREATE OR ALTER VIEW dbo.v_inventory_log_detail AS
    SELECT il.LogID,il.ProductID,p.SKU,p.ProductName,il.ChangeType,
           il.ChangeQuantity,il.BeforeQuantity,il.AfterQuantity,
           il.PurchaseID,il.SaleID,
           COALESCE(po.PurchaseNo,so.SaleNo) AS BusinessNo,
           il.EmployeeID,e.EmployeeNo,e.EmployeeName,il.Remark,il.CreatedAt
    FROM dbo.InventoryLog AS il
    JOIN dbo.Product AS p ON p.ProductID=il.ProductID
    LEFT JOIN dbo.PurchaseOrder AS po ON po.PurchaseID=il.PurchaseID
    LEFT JOIN dbo.SaleOrder AS so ON so.SaleID=il.SaleID
    LEFT JOIN dbo.Employee AS e ON e.EmployeeID=il.EmployeeID;');

    /* 流水包含跨采购/销售和员工信息：清除潜在旧授权，并仅允许管理员查询。 */
    IF DATABASE_PRINCIPAL_ID(N'CampusViewer') IS NOT NULL
        DENY SELECT ON OBJECT::dbo.v_inventory_log_detail TO CampusViewer;
    IF DATABASE_PRINCIPAL_ID(N'CampusPurchaser') IS NOT NULL
        DENY SELECT ON OBJECT::dbo.v_inventory_log_detail TO CampusPurchaser;
    IF DATABASE_PRINCIPAL_ID(N'CampusCashier') IS NOT NULL
        DENY SELECT ON OBJECT::dbo.v_inventory_log_detail TO CampusCashier;
    IF DATABASE_PRINCIPAL_ID(N'CampusAdmin') IS NOT NULL
        GRANT SELECT ON OBJECT::dbo.v_inventory_log_detail TO CampusAdmin;

    IF OBJECT_ID(N'week6.MigrationHistory',N'U') IS NULL
        CREATE TABLE week6.MigrationHistory(
            MigrationCode varchar(30) NOT NULL PRIMARY KEY,
            AppliedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
            Description nvarchar(255) NOT NULL
        );
    INSERT week6.MigrationHistory(MigrationCode,Description)
    VALUES('W6-INVLOG-FK',N'库存流水文本业务单号改为采购/销售订单外键');

    COMMIT;
    PRINT N'第六周迁移成功：InventoryLog 已改为订单外键引用';
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;
GO
