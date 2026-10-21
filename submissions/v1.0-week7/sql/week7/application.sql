/* 第七周应用增量：只接受已完成第六周迁移的独立 W7 数据库。
   不改变10张核心业务表；新增账号、订单归属、受限视图和过程。 */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]%'
    THROW 51800,N'应用增量只能部署到独立 W7 数据库',1;
IF OBJECT_ID(N'dbo.v_inventory_log_detail',N'V') IS NULL OR COL_LENGTH(N'dbo.InventoryLog',N'BusinessNo') IS NOT NULL
    THROW 51800,N'必须先完成第六周迁移',1;
IF SCHEMA_ID(N'app') IS NOT NULL THROW 51800,N'app 已存在，拒绝覆盖应用数据',1;
EXEC(N'CREATE SCHEMA app AUTHORIZATION dbo;');
CREATE TABLE app.AppUser(
 UserID bigint IDENTITY PRIMARY KEY,
 Username varchar(40) NOT NULL UNIQUE,
 PasswordHash varchar(255) NOT NULL,
 DisplayName nvarchar(50) NOT NULL,
 RoleName varchar(20) NOT NULL,
 EmployeeID bigint NULL REFERENCES dbo.Employee(EmployeeID),
 Status bit NOT NULL DEFAULT 1,
 CreatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 CONSTRAINT CK_AppUser_Role CHECK(
   (RoleName='CUSTOMER' AND EmployeeID IS NULL) OR
   (RoleName IN ('ADMIN','STAFF') AND EmployeeID IS NOT NULL))
);
CREATE UNIQUE INDEX UX_AppUser_Employee ON app.AppUser(EmployeeID) WHERE EmployeeID IS NOT NULL;
CREATE TABLE app.SaleOwner(
 SaleID bigint PRIMARY KEY REFERENCES dbo.SaleOrder(SaleID),
 UserID bigint NOT NULL REFERENCES app.AppUser(UserID),
 CreatedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME()
);
CREATE INDEX IX_SaleOwner_User ON app.SaleOwner(UserID,SaleID);
CREATE ROLE WebAuthRole AUTHORIZATION dbo;
CREATE ROLE WebAdminRole AUTHORIZATION dbo;
CREATE ROLE WebStaffRole AUTHORIZATION dbo;
CREATE ROLE WebCustomerRole AUTHORIZATION dbo;
CREATE USER WebAuth WITHOUT LOGIN;
CREATE USER WebAdmin WITHOUT LOGIN;
CREATE USER WebStaff WITHOUT LOGIN;
CREATE USER WebCustomer WITHOUT LOGIN;
ALTER ROLE WebAuthRole ADD MEMBER WebAuth;
ALTER ROLE WebAdminRole ADD MEMBER WebAdmin;
ALTER ROLE WebStaffRole ADD MEMBER WebStaff;
ALTER ROLE WebCustomerRole ADD MEMBER WebCustomer;
GO
CREATE VIEW app.v_Catalog AS
SELECT p.ProductID AS product_id,p.SKU AS sku,p.Barcode AS barcode,p.ProductName AS product_name,
 p.CategoryID AS category_id,c.CategoryName AS category_name,p.Specification AS specification,
 p.Unit AS unit,p.SalePrice AS sale_price,p.Status AS status,i.Quantity AS quantity,
 p.UpdatedAt AS updated_at
FROM dbo.Product p JOIN dbo.Category c ON c.CategoryID=p.CategoryID
JOIN dbo.Inventory i ON i.ProductID=p.ProductID
WHERE USER_NAME() IN (N'WebAdmin',N'WebStaff') OR (p.Status=1 AND c.Status=1);
GO
CREATE VIEW app.v_Categories AS
SELECT CategoryID AS category_id,CategoryName AS category_name FROM dbo.Category WHERE Status=1;
GO
CREATE VIEW app.v_Cashiers AS
SELECT EmployeeID AS employee_id,EmployeeNo AS employee_no FROM dbo.Employee
WHERE Status=1 AND RoleName IN ('CASHIER','ADMIN');
GO
CREATE VIEW app.v_Inventory AS
SELECT p.ProductID AS product_id,p.SKU AS sku,p.ProductName AS product_name,c.CategoryName AS category_name,
 i.Quantity AS quantity,i.MinQuantity AS min_quantity,
 CASE WHEN i.Quantity=0 THEN 'OUT_OF_STOCK' WHEN i.Quantity<i.MinQuantity THEN 'LOW_STOCK' ELSE 'NORMAL' END AS stock_status
FROM dbo.Product p JOIN dbo.Category c ON c.CategoryID=p.CategoryID
JOIN dbo.Inventory i ON i.ProductID=p.ProductID;
GO
CREATE VIEW app.v_OrderAccess AS
SELECT so.SaleID AS sale_id,so.SaleNo AS sale_no,so.Status AS status,
 so.EmployeeID AS employee_id,so.PaymentMethod AS payment_method,
 so.DiscountAmount AS discount_amount,so.TotalAmount AS total_amount,
 CASE WHEN so.Status='COMPLETED' THEN so.PayableAmount END AS payable_amount,
 COALESCE((SELECT SUM(si.LineAmount) FROM dbo.SaleItem si WHERE si.SaleID=so.SaleID),0) AS draft_amount,
 so.Remark AS remark,so.CreatedAt AS created_at,own.UserID AS owner_user_id
FROM dbo.SaleOrder so LEFT JOIN app.SaleOwner own ON own.SaleID=so.SaleID
WHERE USER_NAME() IN (N'WebAdmin',N'WebStaff')
 OR own.UserID=TRY_CONVERT(bigint,SESSION_CONTEXT(N'WebUserID'));
GO
CREATE VIEW app.v_OrderItems AS
SELECT si.SaleItemID AS item_id,si.SaleID AS sale_id,si.ProductID AS product_id,
 p.SKU AS sku,p.ProductName AS product_name,si.Quantity AS quantity,
 si.UnitPrice AS unit_price,si.LineAmount AS line_amount
FROM dbo.SaleItem si JOIN app.v_OrderAccess access ON access.sale_id=si.SaleID
JOIN dbo.Product p ON p.ProductID=si.ProductID;
GO
CREATE PROCEDURE app.CreateSaleDraft
 @EmployeeID bigint,@PaymentMethod varchar(20),@Remark nvarchar(255)=NULL
AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @user bigint=TRY_CONVERT(bigint,SESSION_CONTEXT(N'WebUserID'));
 IF NOT EXISTS(SELECT 1 FROM app.AppUser WHERE UserID=@user AND Status=1)
  THROW 51801,N'缺少有效应用身份',1;
 IF NOT EXISTS(SELECT 1 FROM dbo.Employee WITH (UPDLOCK,HOLDLOCK)
               WHERE EmployeeID=@EmployeeID AND Status=1 AND RoleName IN ('ADMIN','CASHIER'))
  THROW 51802,N'销售单必须分配有效的收银员工',1;
 DECLARE @no varchar(30)='W7S'+LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),24);
 INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod,Remark) VALUES(@no,@EmployeeID,@PaymentMethod,@Remark);
 DECLARE @sale bigint=SCOPE_IDENTITY();
 INSERT app.SaleOwner(SaleID,UserID) VALUES(@sale,@user);
 SELECT @sale AS sale_id;
END;
GO
CREATE PROCEDURE app.WriteSaleItem
 @SaleID bigint,@ProductID bigint,@Quantity int,@UnitPrice decimal(10,2)=NULL,@SaleItemID bigint=NULL
AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @status varchar(20);
 SELECT @status=so.Status FROM dbo.SaleOrder so WITH (UPDLOCK,HOLDLOCK)
 WHERE so.SaleID=@SaleID AND EXISTS(SELECT 1 FROM app.v_OrderAccess a WHERE a.sale_id=so.SaleID);
 IF @status IS NULL THROW 51804,N'订单不可访问',1;
 IF @status<>'DRAFT' THROW 51803,N'只有草稿可以修改明细',1;
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
CREATE PROCEDURE app.DeleteSaleItem @SaleID bigint,@SaleItemID bigint AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @status varchar(20);
 SELECT @status=so.Status FROM dbo.SaleOrder so WITH (UPDLOCK,HOLDLOCK)
 WHERE so.SaleID=@SaleID AND EXISTS(SELECT 1 FROM app.v_OrderAccess a WHERE a.sale_id=so.SaleID);
 IF @status IS NULL THROW 51804,N'订单不可访问',1;
 IF @status<>'DRAFT' THROW 51803,N'只有草稿可以删除明细',1;
 DELETE dbo.SaleItem WHERE SaleID=@SaleID AND SaleItemID=@SaleItemID;
 IF @@ROWCOUNT=0 THROW 51804,N'明细不存在',1;
END;
GO
CREATE PROCEDURE app.UpdateSaleDraft
 @SaleID bigint,@PaymentMethod varchar(20),@DiscountAmount decimal(12,2),@Remark nvarchar(255)=NULL
AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @status varchar(20);
 SELECT @status=so.Status FROM dbo.SaleOrder so WITH(UPDLOCK,HOLDLOCK)
 WHERE so.SaleID=@SaleID AND EXISTS(SELECT 1 FROM app.v_OrderAccess a WHERE a.sale_id=so.SaleID);
 IF @status IS NULL THROW 51804,N'订单不可访问',1;
 IF @status<>'DRAFT' THROW 51803,N'只有草稿可以修改',1;
 IF USER_NAME()=N'WebCustomer' AND @DiscountAmount<>0 THROW 51810,N'顾客不能设置优惠',1;
 EXEC dbo.UpdateSaleDraft @SaleID,@PaymentMethod,@DiscountAmount,@Remark;
END;
GO
CREATE PROCEDURE app.CancelSaleDraft @SaleID bigint AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @status varchar(20);
 SELECT @status=so.Status FROM dbo.SaleOrder so WITH(UPDLOCK,HOLDLOCK)
 WHERE so.SaleID=@SaleID AND EXISTS(SELECT 1 FROM app.v_OrderAccess a WHERE a.sale_id=so.SaleID);
 IF @status IS NULL THROW 51804,N'订单不可访问',1;
 IF @status<>'DRAFT' THROW 51803,N'只有草稿可以取消',1;
 EXEC dbo.CancelSale @SaleID;
END;
GO
CREATE PROCEDURE app.DeleteUnusedProduct @ProductID bigint AS
BEGIN
 SET NOCOUNT ON;
 IF NOT EXISTS(SELECT 1 FROM dbo.Product WITH(UPDLOCK,HOLDLOCK) WHERE ProductID=@ProductID)
  THROW 51804,N'商品不存在',1;
 IF EXISTS(SELECT 1 FROM dbo.Inventory WITH(UPDLOCK,HOLDLOCK) WHERE ProductID=@ProductID AND Quantity<>0)
  OR EXISTS(SELECT 1 FROM dbo.PurchaseItem WITH(HOLDLOCK) WHERE ProductID=@ProductID)
  OR EXISTS(SELECT 1 FROM dbo.SaleItem WITH(HOLDLOCK) WHERE ProductID=@ProductID)
  OR EXISTS(SELECT 1 FROM dbo.InventoryLog WITH(HOLDLOCK) WHERE ProductID=@ProductID)
  THROW 51806,N'商品有库存或业务引用，应停用而不是删除',1;
 DELETE dbo.Inventory WHERE ProductID=@ProductID;
 DELETE dbo.Product WHERE ProductID=@ProductID;
END;
GO
GRANT SELECT ON app.AppUser TO WebAuthRole;
GRANT SELECT ON dbo.Employee TO WebAuthRole;
GRANT SELECT ON app.v_Catalog TO WebAdminRole,WebStaffRole,WebCustomerRole;
GRANT SELECT ON app.v_Categories TO WebAdminRole,WebStaffRole,WebCustomerRole;
GRANT SELECT ON app.v_Cashiers TO WebAdminRole,WebStaffRole,WebCustomerRole;
GRANT SELECT ON app.v_OrderAccess TO WebAdminRole,WebStaffRole,WebCustomerRole;
GRANT SELECT ON app.v_OrderItems TO WebAdminRole,WebStaffRole,WebCustomerRole;
GRANT SELECT ON app.v_Inventory TO WebAdminRole,WebStaffRole;
GRANT INSERT,UPDATE ON dbo.Product TO WebAdminRole;
GRANT SELECT(ProductID) ON dbo.Product TO WebAdminRole;
GRANT UPDATE(MinQuantity) ON dbo.Inventory TO WebAdminRole;
GRANT SELECT(ProductID) ON dbo.Inventory TO WebAdminRole;
GRANT EXECUTE ON app.DeleteUnusedProduct TO WebAdminRole;
GRANT EXECUTE ON app.CreateSaleDraft TO WebAdminRole,WebStaffRole,WebCustomerRole;
GRANT EXECUTE ON app.WriteSaleItem TO WebAdminRole,WebStaffRole,WebCustomerRole;
GRANT EXECUTE ON app.DeleteSaleItem TO WebAdminRole,WebStaffRole,WebCustomerRole;
GRANT EXECUTE ON app.UpdateSaleDraft TO WebAdminRole,WebStaffRole,WebCustomerRole;
GRANT EXECUTE ON app.CancelSaleDraft TO WebAdminRole,WebStaffRole,WebCustomerRole;
DENY UPDATE(Quantity) ON dbo.Inventory TO WebAdminRole,WebStaffRole,WebCustomerRole;
DENY DELETE ON dbo.Inventory TO WebAdminRole,WebStaffRole,WebCustomerRole;
DENY SELECT ON app.AppUser TO WebAdminRole,WebStaffRole,WebCustomerRole;
PRINT N'第七周应用对象和受限执行身份已部署';
