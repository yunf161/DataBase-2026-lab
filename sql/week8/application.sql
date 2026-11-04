/* 第八周增量（采购与供应商）：只部署到完成 W6 迁移且已有 W7 app 的独立数据库。可重复执行。 */
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]%'
    THROW 51900,N'第八周应用只允许部署到独立 W7 数据库',1;
IF OBJECT_ID(N'app.AppUser',N'U') IS NULL OR OBJECT_ID(N'dbo.v_inventory_log_detail',N'V') IS NULL
    THROW 51900,N'请先部署第六周迁移和第七周应用',1;
GO
-- 结算和库存调整统一由 sql/week9 的 app.SettleSale、app.AdjustInventory 提供；这里清掉旧版部署留下的同类过程。
DROP PROCEDURE IF EXISTS app.CompleteSale;
DROP PROCEDURE IF EXISTS app.Stocktake;
GO
CREATE OR ALTER VIEW app.v_Suppliers AS
SELECT SupplierID AS supplier_id,SupplierCode AS supplier_code,SupplierName AS supplier_name
FROM dbo.Supplier WHERE Status=1;
GO
CREATE OR ALTER VIEW app.v_PurchaseOrders AS
SELECT po.PurchaseID AS purchase_id,po.PurchaseNo AS purchase_no,
       po.SupplierID AS supplier_id,s.SupplierName AS supplier_name,
       po.EmployeeID AS employee_id,po.Status AS status,
       po.TotalAmount AS total_amount,po.OrderTime AS order_time,
       po.ReceivedTime AS received_time,
       COALESCE((SELECT SUM(pi.LineAmount) FROM dbo.PurchaseItem pi
                 WHERE pi.PurchaseID=po.PurchaseID),0) AS draft_amount
FROM dbo.PurchaseOrder po JOIN dbo.Supplier s ON s.SupplierID=po.SupplierID;
GO
CREATE OR ALTER VIEW app.v_PurchaseItems AS
SELECT pi.PurchaseItemID AS item_id,pi.PurchaseID AS purchase_id,
       pi.ProductID AS product_id,p.SKU AS sku,p.ProductName AS product_name,
       pi.Quantity AS quantity,pi.UnitCost AS unit_cost,pi.LineAmount AS line_amount
FROM dbo.PurchaseItem pi JOIN dbo.Product p ON p.ProductID=pi.ProductID;
GO
CREATE OR ALTER PROCEDURE app.CreatePurchaseDraft @SupplierID bigint AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @employee bigint;
    SELECT @employee=u.EmployeeID FROM app.AppUser u
    JOIN dbo.Employee e ON e.EmployeeID=u.EmployeeID
    WHERE u.UserID=TRY_CONVERT(bigint,SESSION_CONTEXT(N'WebUserID'))
      AND u.RoleName='ADMIN' AND u.Status=1 AND e.Status=1
      AND e.RoleName IN ('ADMIN','PURCHASER');
    IF @employee IS NULL THROW 51801,N'缺少有效管理员身份',1;
    IF NOT EXISTS(SELECT 1 FROM dbo.Supplier WHERE SupplierID=@SupplierID AND Status=1)
        THROW 51814,N'供应商不存在或已停用',1;
    DECLARE @no varchar(30)='W8P'+LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),24);
    INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID)
    VALUES(@no,@SupplierID,@employee);
    SELECT CONVERT(bigint,SCOPE_IDENTITY()) AS purchase_id;
END;
GO
CREATE OR ALTER PROCEDURE app.WritePurchaseItem
    @PurchaseID bigint,@ProductID bigint,@Quantity int,@UnitCost decimal(10,2),
    @PurchaseItemID bigint=NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    DECLARE @entryTranCount int=@@TRANCOUNT,@savePointCreated bit=0;
    DECLARE @status varchar(20);
    BEGIN TRY
    IF @entryTranCount=0 BEGIN TRAN;
    ELSE
    BEGIN
        SAVE TRAN WritePurchaseItemSave;
        SET @savePointCreated=1;
    END;
    SELECT @status=Status FROM dbo.PurchaseOrder WITH(UPDLOCK,HOLDLOCK)
    WHERE PurchaseID=@PurchaseID;
    IF @status IS NULL THROW 51804,N'采购单不存在',1;
    IF @status<>'DRAFT' THROW 51803,N'只有草稿采购单可改明细',1;
    IF @Quantity IS NULL OR @Quantity<1 OR @Quantity>1000000
       OR @UnitCost IS NULL OR @UnitCost<0
       OR CONVERT(decimal(20,2),@Quantity)*@UnitCost>9999999999.99
       THROW 51805,N'采购数量或金额无效',1;
    IF @PurchaseItemID IS NOT NULL
    BEGIN
        SELECT @ProductID=ProductID FROM dbo.PurchaseItem
        WHERE PurchaseID=@PurchaseID AND PurchaseItemID=@PurchaseItemID;
        IF @@ROWCOUNT=0 THROW 51804,N'采购明细不存在',1;
    END;
    IF NOT EXISTS(SELECT 1 FROM dbo.Product WHERE ProductID=@ProductID AND Status=1)
        THROW 51808,N'商品不存在或已停用',1;
    IF @PurchaseItemID IS NULL
    BEGIN
        INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost)
        VALUES(@PurchaseID,@ProductID,@Quantity,@UnitCost);
        SET @PurchaseItemID=SCOPE_IDENTITY();
    END
    ELSE
        UPDATE dbo.PurchaseItem SET Quantity=@Quantity,UnitCost=@UnitCost
        WHERE PurchaseItemID=@PurchaseItemID AND PurchaseID=@PurchaseID;
    IF (SELECT SUM(LineAmount) FROM dbo.PurchaseItem WHERE PurchaseID=@PurchaseID)>9999999999.99
        THROW 51805,N'采购单总额超出范围',1;
    SELECT @PurchaseItemID AS item_id;
    IF @entryTranCount=0 COMMIT;
    END TRY
    BEGIN CATCH
        IF @entryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @entryTranCount>0 AND XACT_STATE()=1 AND @savePointCreated=1
            ROLLBACK TRAN WritePurchaseItemSave;
        THROW;
    END CATCH;
END;
GO
CREATE OR ALTER PROCEDURE app.ConfirmPurchase @PurchaseID bigint AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS(SELECT 1 FROM app.v_PurchaseOrders
                  WHERE purchase_id=@PurchaseID AND status='DRAFT')
        THROW 51803,N'只能确认草稿采购单',1;
    EXEC dbo.ConfirmPurchase @PurchaseID;
END;
GO
CREATE OR ALTER PROCEDURE app.DeletePurchaseItem @PurchaseID bigint,@PurchaseItemID bigint AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @status varchar(20);
    SELECT @status=Status FROM dbo.PurchaseOrder WITH(UPDLOCK,HOLDLOCK)
    WHERE PurchaseID=@PurchaseID;
    IF @status IS NULL THROW 51804,N'采购单不存在',1;
    IF @status<>'DRAFT' THROW 51803,N'只有草稿采购单可删明细',1;
    DELETE dbo.PurchaseItem WHERE PurchaseID=@PurchaseID AND PurchaseItemID=@PurchaseItemID;
    IF @@ROWCOUNT=0 THROW 51804,N'采购明细不存在',1;
END;
GO
CREATE OR ALTER PROCEDURE app.CancelPurchaseDraft @PurchaseID bigint AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS(SELECT 1 FROM app.v_PurchaseOrders
                  WHERE purchase_id=@PurchaseID AND status='DRAFT')
        THROW 51803,N'只能取消草稿采购单',1;
    EXEC dbo.CancelPurchase @PurchaseID;
END;
GO
GRANT SELECT ON app.v_Suppliers TO WebAdminRole;
GRANT SELECT ON app.v_PurchaseOrders TO WebAdminRole;
GRANT SELECT ON app.v_PurchaseItems TO WebAdminRole;
GRANT EXECUTE ON app.CreatePurchaseDraft TO WebAdminRole;
GRANT EXECUTE ON app.WritePurchaseItem TO WebAdminRole;
GRANT EXECUTE ON app.ConfirmPurchase TO WebAdminRole;
GRANT EXECUTE ON app.DeletePurchaseItem TO WebAdminRole;
GRANT EXECUTE ON app.CancelPurchaseDraft TO WebAdminRole;
GO
