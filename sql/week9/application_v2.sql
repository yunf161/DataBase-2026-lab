/* 第九周应用增量：顾客提交、店员结算和库存调整的数据库部分。
   只接受已部署第七周 app 架构的独立 W7 数据库；可重复执行，不改变10张核心业务表。 */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]%'
    THROW 51800,N'应用增量只能部署到独立 W7 数据库',1;
IF SCHEMA_ID(N'app') IS NULL
    THROW 51800,N'必须先部署第七周 app 架构',1;
IF OBJECT_ID(N'app.SaleOwner',N'U') IS NULL OR OBJECT_ID(N'app.AppUser',N'U') IS NULL
   OR OBJECT_ID(N'app.v_OrderAccess',N'V') IS NULL OR OBJECT_ID(N'dbo.CompleteSale',N'P') IS NULL
   OR OBJECT_ID(N'dbo.v_inventory_log_detail',N'V') IS NULL
    THROW 51800,N'第七周应用对象不完整，拒绝升级',1;
IF COL_LENGTH(N'app.SaleOwner',N'SubmittedAt') IS NULL
    ALTER TABLE app.SaleOwner ADD SubmittedAt datetime2(0) NULL;
GO
CREATE OR ALTER VIEW app.v_OrderAccess AS
SELECT so.SaleID AS sale_id,so.SaleNo AS sale_no,so.Status AS status,
 so.EmployeeID AS employee_id,so.PaymentMethod AS payment_method,
 so.DiscountAmount AS discount_amount,so.TotalAmount AS total_amount,
 CASE WHEN so.Status='COMPLETED' THEN so.PayableAmount END AS payable_amount,
 COALESCE((SELECT SUM(si.LineAmount) FROM dbo.SaleItem si WHERE si.SaleID=so.SaleID),0) AS draft_amount,
 so.Remark AS remark,so.CreatedAt AS created_at,own.UserID AS owner_user_id,
 own.SubmittedAt AS submitted_at,
 CASE WHEN ou.RoleName='CUSTOMER' THEN 1 ELSE 0 END AS is_customer_order
FROM dbo.SaleOrder so LEFT JOIN app.SaleOwner own ON own.SaleID=so.SaleID
LEFT JOIN app.AppUser ou ON ou.UserID=own.UserID
WHERE USER_NAME() IN (N'WebAdmin',N'WebStaff')
 OR own.UserID=TRY_CONVERT(bigint,SESSION_CONTEXT(N'WebUserID'));
GO
CREATE OR ALTER VIEW app.v_InventoryLog AS
SELECT LogID AS log_id,ProductID AS product_id,SKU AS sku,ProductName AS product_name,
 ChangeType AS change_type,ChangeQuantity AS change_quantity,BeforeQuantity AS before_quantity,
 AfterQuantity AS after_quantity,BusinessNo AS business_no,EmployeeNo AS employee_no,
 Remark AS remark,CreatedAt AS created_at
FROM dbo.v_inventory_log_detail;
GO
-- 分类可以分层：member_id 是 category_id 自身及其全部子孙分类，触发器已保证分类不成环。
CREATE OR ALTER VIEW app.v_CategoryScope AS
WITH scope AS (
 SELECT CategoryID AS category_id,CategoryID AS member_id FROM dbo.Category
 UNION ALL
 SELECT s.category_id,c.CategoryID FROM scope s JOIN dbo.Category c ON c.ParentID=s.member_id
)
SELECT category_id,member_id FROM scope;
GO
CREATE OR ALTER PROCEDURE app.WriteSaleItem
 @SaleID bigint,@ProductID bigint,@Quantity int,@UnitPrice decimal(10,2)=NULL,@SaleItemID bigint=NULL
AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @status varchar(20);
 SELECT @status=so.Status FROM dbo.SaleOrder so WITH (UPDLOCK,HOLDLOCK)
 WHERE so.SaleID=@SaleID AND EXISTS(SELECT 1 FROM app.v_OrderAccess a WHERE a.sale_id=so.SaleID);
 IF @status IS NULL THROW 51804,N'订单不可访问',1;
 IF @status<>'DRAFT' THROW 51803,N'只有草稿可以修改明细',1;
 IF USER_NAME()=N'WebCustomer' AND EXISTS(SELECT 1 FROM app.SaleOwner WHERE SaleID=@SaleID AND SubmittedAt IS NOT NULL)
  THROW 51811,N'订单已提交，不能再修改',1;
 IF @Quantity IS NULL OR @Quantity<1 OR @Quantity>1000000 THROW 51805,N'数量无效',1;
 IF USER_NAME()=N'WebCustomer' AND @UnitPrice IS NOT NULL THROW 51810,N'顾客不能指定成交价',1;
 IF @SaleItemID IS NOT NULL
 BEGIN
  SELECT @ProductID=ProductID FROM dbo.SaleItem WHERE SaleItemID=@SaleItemID AND SaleID=@SaleID;
  IF @@ROWCOUNT=0 THROW 51804,N'明细不可访问',1;
 END;
 DECLARE @price decimal(10,2);
 SELECT @price=p.SalePrice FROM dbo.Product p WITH(UPDLOCK,HOLDLOCK)
 JOIN dbo.Category c WITH(HOLDLOCK) ON c.CategoryID=p.CategoryID
 WHERE p.ProductID=@ProductID AND p.Status=1 AND c.Status=1;
 IF @price IS NULL THROW 51808,N'商品已停用或不存在',1;
 IF @SaleItemID IS NOT NULL
  SELECT @price=UnitPrice FROM dbo.SaleItem WHERE SaleItemID=@SaleItemID;
 SET @price=COALESCE(@UnitPrice,@price);
 IF @price<0 OR CONVERT(decimal(20,2),@price)*@Quantity>9999999999.99
  THROW 51805,N'行金额超出范围',1;
 IF @SaleItemID IS NULL
 BEGIN
  INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice) VALUES(@SaleID,@ProductID,@Quantity,@price);
  SET @SaleItemID=SCOPE_IDENTITY();
 END
 ELSE UPDATE dbo.SaleItem SET Quantity=@Quantity,UnitPrice=@price WHERE SaleItemID=@SaleItemID AND SaleID=@SaleID;
 IF (SELECT SUM(LineAmount) FROM dbo.SaleItem WHERE SaleID=@SaleID)>9999999999.99
  THROW 51805,N'订单金额超出范围',1;
 SELECT @SaleItemID AS item_id;
END;
GO
CREATE OR ALTER PROCEDURE app.DeleteSaleItem @SaleID bigint,@SaleItemID bigint AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @status varchar(20);
 SELECT @status=so.Status FROM dbo.SaleOrder so WITH (UPDLOCK,HOLDLOCK)
 WHERE so.SaleID=@SaleID AND EXISTS(SELECT 1 FROM app.v_OrderAccess a WHERE a.sale_id=so.SaleID);
 IF @status IS NULL THROW 51804,N'订单不可访问',1;
 IF @status<>'DRAFT' THROW 51803,N'只有草稿可以删除明细',1;
 IF USER_NAME()=N'WebCustomer' AND EXISTS(SELECT 1 FROM app.SaleOwner WHERE SaleID=@SaleID AND SubmittedAt IS NOT NULL)
  THROW 51811,N'订单已提交，不能再修改',1;
 DELETE dbo.SaleItem WHERE SaleID=@SaleID AND SaleItemID=@SaleItemID;
 IF @@ROWCOUNT=0 THROW 51804,N'明细不存在',1;
END;
GO
CREATE OR ALTER PROCEDURE app.UpdateSaleDraft
 @SaleID bigint,@PaymentMethod varchar(20),@DiscountAmount decimal(12,2),@Remark nvarchar(255)=NULL
AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @status varchar(20),@discount decimal(12,2);
 SELECT @status=so.Status,@discount=so.DiscountAmount FROM dbo.SaleOrder so WITH(UPDLOCK,HOLDLOCK)
 WHERE so.SaleID=@SaleID AND EXISTS(SELECT 1 FROM app.v_OrderAccess a WHERE a.sale_id=so.SaleID);
 IF @status IS NULL THROW 51804,N'订单不可访问',1;
 IF @status<>'DRAFT' THROW 51803,N'只有草稿可以修改',1;
 IF USER_NAME()=N'WebCustomer' AND EXISTS(SELECT 1 FROM app.SaleOwner WHERE SaleID=@SaleID AND SubmittedAt IS NOT NULL)
  THROW 51811,N'订单已提交，不能再修改',1;
 IF USER_NAME()=N'WebCustomer' AND @DiscountAmount<>@discount THROW 51810,N'顾客不能设置优惠',1;
 EXEC dbo.UpdateSaleDraft @SaleID,@PaymentMethod,@DiscountAmount,@Remark;
END;
GO
CREATE OR ALTER PROCEDURE app.SubmitSale @SaleID bigint AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @status varchar(20),@owner bigint,@submitted datetime2(0),@changed int,
  @user bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'WebUserID'));
 SELECT @status=so.Status FROM dbo.SaleOrder so WITH (UPDLOCK,HOLDLOCK)
 WHERE so.SaleID=@SaleID AND EXISTS(SELECT 1 FROM app.v_OrderAccess a WHERE a.sale_id=so.SaleID);
 IF @status IS NULL THROW 51804,N'订单不可访问',1;
 IF @status<>'DRAFT' THROW 51803,N'只有草稿可以提交',1;
 SELECT @owner=UserID,@submitted=SubmittedAt FROM app.SaleOwner WHERE SaleID=@SaleID;
 IF @user IS NULL OR @owner IS NULL OR @owner<>@user OR @submitted IS NOT NULL
  THROW 51811,N'只能提交本人尚未提交的订单',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.SaleItem WITH (UPDLOCK,HOLDLOCK) WHERE SaleID=@SaleID)
  THROW 51302,N'订单还没有商品',1;
 IF EXISTS(SELECT 1 FROM dbo.SaleItem si JOIN dbo.Product p WITH(HOLDLOCK) ON p.ProductID=si.ProductID
           JOIN dbo.Category c WITH(HOLDLOCK) ON c.CategoryID=p.CategoryID
           WHERE si.SaleID=@SaleID AND (p.Status=0 OR c.Status=0))
  THROW 51304,N'订单含已停用商品或分类',1;
 -- 只是提前提示，不预留库存；真正扣减仍在结算时由 dbo.CompleteSale 完成。
 IF EXISTS(SELECT 1 FROM dbo.SaleItem si LEFT JOIN dbo.Inventory i ON i.ProductID=si.ProductID
           WHERE si.SaleID=@SaleID AND si.Quantity>COALESCE(i.Quantity,0))
  THROW 51305,N'部分商品库存不足',1;
 -- 价格变化不抛错：抛错会回滚刚更新的现价，顾客刷新后仍看不到新价格。
 UPDATE si SET UnitPrice=p.SalePrice
 FROM dbo.SaleItem si JOIN dbo.Product p WITH(HOLDLOCK) ON p.ProductID=si.ProductID
 WHERE si.SaleID=@SaleID AND si.UnitPrice<>p.SalePrice;
 SET @changed=@@ROWCOUNT;
 IF @changed=0 UPDATE app.SaleOwner SET SubmittedAt=SYSDATETIME() WHERE SaleID=@SaleID;
 SELECT CASE WHEN @changed=0 THEN 1 ELSE 0 END AS submitted,
  CASE WHEN @changed=0 THEN 0 ELSE 1 END AS price_changed;
END;
GO
CREATE OR ALTER PROCEDURE app.SettleSale @SaleID bigint AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @status varchar(20),@employee bigint,@isCustomerOrder int,@submitted datetime2(0);
 SELECT @status=so.Status FROM dbo.SaleOrder so WITH (UPDLOCK,HOLDLOCK)
 WHERE so.SaleID=@SaleID AND EXISTS(SELECT 1 FROM app.v_OrderAccess a WHERE a.sale_id=so.SaleID);
 IF @status IS NULL THROW 51804,N'订单不可访问',1;
 IF @status<>'DRAFT' THROW 51803,N'只有草稿可以结算',1;
 SELECT @employee=EmployeeID FROM app.AppUser
 WHERE UserID=TRY_CONVERT(bigint,SESSION_CONTEXT(N'WebUserID')) AND Status=1;
 IF @employee IS NULL THROW 51801,N'缺少有效的员工身份',1;
 SELECT @isCustomerOrder=a.is_customer_order,@submitted=a.submitted_at
 FROM app.v_OrderAccess a WHERE a.sale_id=@SaleID;
 IF @isCustomerOrder=1 AND @submitted IS NULL THROW 51812,N'顾客尚未提交此订单',1;
 IF EXISTS(SELECT 1 FROM dbo.SaleItem si JOIN dbo.Product p WITH(HOLDLOCK) ON p.ProductID=si.ProductID
           JOIN dbo.Category c WITH(HOLDLOCK) ON c.CategoryID=p.CategoryID
           WHERE si.SaleID=@SaleID AND (p.Status=0 OR c.Status=0))
  THROW 51304,N'订单含已停用商品或分类',1;
 UPDATE dbo.SaleOrder SET EmployeeID=@employee WHERE SaleID=@SaleID;
 EXEC dbo.CompleteSale @SaleID;
 SELECT @SaleID AS sale_id;
END;
GO
CREATE OR ALTER PROCEDURE app.AdjustInventory @ProductID bigint,@NewQuantity int,@Reason nvarchar(255) AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @employee bigint,@before int;
 SET @Reason=LTRIM(RTRIM(@Reason));
 IF @NewQuantity IS NULL OR @NewQuantity<0 OR @NewQuantity>1000000 OR @Reason IS NULL OR @Reason=N''
  THROW 51805,N'库存数量或调整原因无效',1;
 SELECT @employee=EmployeeID FROM app.AppUser
 WHERE UserID=TRY_CONVERT(bigint,SESSION_CONTEXT(N'WebUserID')) AND Status=1;
 IF @employee IS NULL THROW 51801,N'缺少有效的员工身份',1;
 SELECT @before=Quantity FROM dbo.Inventory WITH (UPDLOCK,HOLDLOCK) WHERE ProductID=@ProductID;
 IF @before IS NULL THROW 51804,N'商品库存记录不存在',1;
 IF @before=@NewQuantity THROW 51813,N'库存数量没有变化',1;
 BEGIN TRY
  EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite',@value=1;
  UPDATE dbo.Inventory SET Quantity=@NewQuantity,UpdatedAt=SYSDATETIME() WHERE ProductID=@ProductID;
  INSERT dbo.InventoryLog(ProductID,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,
   PurchaseID,SaleID,EmployeeID,Remark)
  VALUES(@ProductID,CASE WHEN @NewQuantity>@before THEN 'STOCKTAKE_IN' ELSE 'STOCKTAKE_OUT' END,
   @NewQuantity-@before,@before,@NewQuantity,NULL,NULL,@employee,@Reason);
  EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite',@value=NULL;
 END TRY
 BEGIN CATCH
  EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite',@value=NULL;
  THROW;
 END CATCH;
 SELECT @ProductID AS product_id,@NewQuantity AS quantity;
END;
GO
GRANT EXECUTE ON app.SubmitSale TO WebCustomerRole;
GRANT EXECUTE ON app.SettleSale TO WebAdminRole,WebStaffRole;
GRANT EXECUTE ON app.AdjustInventory TO WebAdminRole;
GRANT SELECT ON app.v_InventoryLog TO WebAdminRole;
GRANT SELECT ON app.v_CategoryScope TO WebAdminRole,WebStaffRole,WebCustomerRole;
PRINT N'第九周应用增量已部署';
