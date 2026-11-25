/* 第十至十二周整合：把网页（app 架构）原来自己实现的业务换成第十至十二周的过程和函数。可重复执行。
   网页只做登录、角色和输入格式检查，然后调用下面的包装过程；数据修改全部由 dbo 的过程在数据库中完成：
     结算订单    app.SettleSale        → dbo.usp_CompleteOrder（扣库存、写流水、按函数计算折扣、完成订单）
     盘点调整    app.AdjustInventory   → dbo.usp_AdjustInventory
     确认入库    app.ConfirmPurchase   → dbo.usp_ReceiveRestock
     补货建议单  app.CreateRestockDraft → dbo.usp_CreateRestockOrder（补货量来自 dbo.fn_RestockQuantity）
     经营统计    dbo.usp_SalesStatistics、dbo.fn_SalesSummary、app.fn_DailySalesTrend、app.fn_ProductSalesRank
   原来由店员手填的“优惠金额”取消：草稿显示按 dbo.fn_DiscountRate 预估的折扣，结算时由 dbo.usp_CompleteOrder 计算并保存。 */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]%'
    THROW 51700,N'第十至十二周对象只部署到独立 W7 应用数据库',1;
IF OBJECT_ID(N'dbo.usp_CompleteOrder',N'P') IS NULL OR OBJECT_ID(N'dbo.usp_ReceiveRestock',N'P') IS NULL
   OR OBJECT_ID(N'dbo.usp_AdjustInventory',N'P') IS NULL
    THROW 51700,N'请先部署第十至十二周的过程',1;
GO
/* 订单视图：草稿的折扣是按当前明细预估的（结算时才最终确定），已完成订单是实际保存的折扣率和折扣金额。
   is_customer_order=1 即会员订单。其余列与第九周一致。 */
CREATE OR ALTER VIEW app.v_OrderAccess AS
SELECT so.SaleID AS sale_id,so.SaleNo AS sale_no,so.Status AS status,
 so.EmployeeID AS employee_id,so.PaymentMethod AS payment_method,
 CASE WHEN so.Status='DRAFT'
      THEN dbo.fn_DiscountAmount(CASE WHEN ou.RoleName='CUSTOMER' THEN 1 ELSE 0 END,amt.Amount)
      ELSE so.DiscountAmount END AS discount_amount,
 so.TotalAmount AS total_amount,
 CASE WHEN so.Status='COMPLETED' THEN so.PayableAmount END AS payable_amount,
 amt.Amount AS draft_amount,
 so.Remark AS remark,so.CreatedAt AS created_at,own.UserID AS owner_user_id,
 own.SubmittedAt AS submitted_at,
 CASE WHEN ou.RoleName='CUSTOMER' THEN 1 ELSE 0 END AS is_customer_order,
 CASE WHEN so.Status='COMPLETED' THEN so.SaleTime END AS settled_at,
 CASE WHEN USER_NAME() IN (N'WebAdmin',N'WebStaff') THEN e.EmployeeNo END AS employee_no,
 CASE WHEN USER_NAME() IN (N'WebAdmin',N'WebStaff') THEN e.EmployeeName END AS employee_name,
 CASE WHEN so.Status='DRAFT'
      THEN dbo.fn_DiscountRate(CASE WHEN ou.RoleName='CUSTOMER' THEN 1 ELSE 0 END,amt.Amount)
      ELSE so.DiscountRate END AS discount_rate
FROM dbo.SaleOrder so LEFT JOIN app.SaleOwner own ON own.SaleID=so.SaleID
LEFT JOIN app.AppUser ou ON ou.UserID=own.UserID
LEFT JOIN dbo.Employee e ON e.EmployeeID=so.EmployeeID
CROSS APPLY (SELECT CONVERT(decimal(12,2),COALESCE(SUM(si.LineAmount),0)) AS Amount
             FROM dbo.SaleItem si WHERE si.SaleID=so.SaleID) amt
WHERE USER_NAME() IN (N'WebAdmin',N'WebStaff')
 OR own.UserID=TRY_CONVERT(bigint,SESSION_CONTEXT(N'WebUserID'));
GO
/* 草稿信息：只保存支付方式和备注，折扣不再由人工填写。 */
DROP PROCEDURE IF EXISTS app.UpdateSaleDraft;
GO
CREATE PROCEDURE app.UpdateSaleDraft @SaleID bigint,@PaymentMethod varchar(20),@Remark nvarchar(255)=NULL
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
 EXEC dbo.UpdateSaleDraft @SaleID,@PaymentMethod,@discount,@Remark;
END;
GO
GRANT EXECUTE ON app.UpdateSaleDraft TO WebAdminRole,WebStaffRole,WebCustomerRole;
GO
/* 结算：网页身份检查（订单可访问、仍是草稿、当前账号是有效员工、顾客已提交）后交给 dbo.usp_CompleteOrder。 */
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
 EXEC dbo.usp_CompleteOrder @SaleID=@SaleID,@EmployeeID=@employee,@Quiet=1;
 SELECT @SaleID AS sale_id;
END;
GO
/* 盘点：网页传入盘点后的实际数量，这里换算成调整数量交给 dbo.usp_AdjustInventory。
   参数检查和错误号与第九周相同（51805 数量或原因无效、51801 无员工身份、51804 商品不存在、51813 数量没有变化）。 */
CREATE OR ALTER PROCEDURE app.AdjustInventory @ProductID bigint,@NewQuantity int,@Reason nvarchar(255) AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @employeeNo varchar(20),@sku varchar(30),@before int,@change int;
 SET @Reason=LTRIM(RTRIM(@Reason));
 IF @NewQuantity IS NULL OR @NewQuantity<0 OR @NewQuantity>1000000 OR @Reason IS NULL OR @Reason=N''
  THROW 51805,N'库存数量或调整原因无效',1;
 SELECT @employeeNo=e.EmployeeNo FROM app.AppUser u JOIN dbo.Employee e ON e.EmployeeID=u.EmployeeID
 WHERE u.UserID=TRY_CONVERT(bigint,SESSION_CONTEXT(N'WebUserID')) AND u.Status=1;
 IF @employeeNo IS NULL THROW 51801,N'缺少有效的员工身份',1;
 SELECT @sku=p.SKU,@before=i.Quantity FROM dbo.Inventory i WITH (UPDLOCK,HOLDLOCK)
 JOIN dbo.Product p ON p.ProductID=i.ProductID WHERE i.ProductID=@ProductID;
 IF @before IS NULL THROW 51804,N'商品库存记录不存在',1;
 IF @before=@NewQuantity THROW 51813,N'库存数量没有变化',1;
 SET @change=@NewQuantity-@before;
 EXEC dbo.usp_AdjustInventory @ProductCode=@sku,@ChangeQuantity=@change,@Reason=@Reason,
      @EmployeeNo=@employeeNo,@Quiet=1;
 SELECT @ProductID AS product_id,@NewQuantity AS quantity;
END;
GO
/* 确认入库：交给 dbo.usp_ReceiveRestock，入库员工为当前管理员。 */
CREATE OR ALTER PROCEDURE app.ConfirmPurchase @PurchaseID bigint AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @employee bigint;
 IF NOT EXISTS(SELECT 1 FROM app.v_PurchaseOrders WHERE purchase_id=@PurchaseID AND status='DRAFT')
  THROW 51803,N'只能确认草稿采购单',1;
 SELECT @employee=u.EmployeeID FROM app.AppUser u
 WHERE u.UserID=TRY_CONVERT(bigint,SESSION_CONTEXT(N'WebUserID')) AND u.Status=1 AND u.RoleName='ADMIN';
 IF @employee IS NULL THROW 51801,N'缺少有效管理员身份',1;
 EXEC dbo.usp_ReceiveRestock @PurchaseID=@PurchaseID,@EmployeeID=@employee,@Quiet=1;
END;
GO
/* 按库存预警生成补货建议单（采购草稿），之后可在采购页修改数量和进价再确认入库。 */
CREATE OR ALTER PROCEDURE app.CreateRestockDraft @SupplierID bigint AS
BEGIN
 SET NOCOUNT ON;
 DECLARE @employeeNo varchar(20),@purchase bigint;
 SELECT @employeeNo=e.EmployeeNo FROM app.AppUser u JOIN dbo.Employee e ON e.EmployeeID=u.EmployeeID
 WHERE u.UserID=TRY_CONVERT(bigint,SESSION_CONTEXT(N'WebUserID')) AND u.Status=1 AND u.RoleName='ADMIN';
 IF @employeeNo IS NULL THROW 51801,N'缺少有效管理员身份',1;
 EXEC dbo.usp_CreateRestockOrder @SupplierID=@SupplierID,@EmployeeNo=@employeeNo,
      @PurchaseID=@purchase OUTPUT,@Quiet=1;
 SELECT @purchase AS purchase_id;
END;
GO
/* 每日销售趋势：日期区间内的每一天都出一行（没有销售的日子为 0），附累计实收和最近 3 天移动平均。
   日期序列用 0—999 的数字表生成（最多 1000 天），不依赖递归。开始晚于结束时返回空。 */
CREATE OR ALTER FUNCTION app.fn_DailySalesTrend(@StartDate date,@EndDate date)
RETURNS TABLE
AS
RETURN
WITH digits AS (SELECT n FROM (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS d(n)),
days AS (
    SELECT DATEADD(DAY,a.n+b.n*10+c.n*100,@StartDate) AS SaleDate
    FROM digits a CROSS JOIN digits b CROSS JOIN digits c
    WHERE a.n+b.n*10+c.n*100<=DATEDIFF(DAY,@StartDate,@EndDate)
),
sales AS (
    SELECT CONVERT(date,SaleTime) AS SaleDate,COUNT(*) AS OrderCount,SUM(TotalAmount) AS OriginalAmount,
           SUM(DiscountAmount) AS DiscountAmount,SUM(PayableAmount) AS SalesAmount
    FROM dbo.SaleOrder
    WHERE Status='COMPLETED' AND SaleTime>=CONVERT(datetime2(0),@StartDate)
      AND SaleTime<DATEADD(DAY,1,CONVERT(datetime2(0),@EndDate))
    GROUP BY CONVERT(date,SaleTime)
)
SELECT d.SaleDate AS sale_date,
       COALESCE(s.OrderCount,0) AS order_count,
       COALESCE(s.OriginalAmount,0) AS original_amount,
       COALESCE(s.DiscountAmount,0) AS discount_amount,
       COALESCE(s.SalesAmount,0) AS sales_amount,
       SUM(COALESCE(s.SalesAmount,0)) OVER (ORDER BY d.SaleDate ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_amount,
       CONVERT(decimal(12,2),AVG(COALESCE(s.SalesAmount,0)) OVER (ORDER BY d.SaleDate ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)) AS moving_avg_3d,
       COUNT(*) OVER (ORDER BY d.SaleDate ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS window_days
FROM days d LEFT JOIN sales s ON s.SaleDate=d.SaleDate;
GO
/* 区间内商品销量排名：以销售额排名（RANK 并列同名次、DENSE_RANK 不跳号、ROW_NUMBER 唯一序号）。 */
CREATE OR ALTER FUNCTION app.fn_ProductSalesRank(@StartDate date,@EndDate date)
RETURNS TABLE
AS
RETURN
SELECT s.ProductID AS product_id,s.SKU AS sku,s.ProductName AS product_name,c.CategoryName AS category_name,
       s.SoldQuantity AS sold_quantity,s.SalesAmount AS sales_amount,s.OrderCount AS order_count,
       RANK() OVER (ORDER BY s.SalesAmount DESC) AS sales_rank,
       DENSE_RANK() OVER (ORDER BY s.SalesAmount DESC) AS dense_sales_rank,
       ROW_NUMBER() OVER (ORDER BY s.SalesAmount DESC,s.SoldQuantity DESC,s.ProductID) AS row_no
FROM dbo.fn_SalesSummary(@StartDate,@EndDate) s
JOIN dbo.Product p ON p.ProductID=s.ProductID
JOIN dbo.Category c ON c.CategoryID=p.CategoryID;
GO
GRANT EXECUTE ON app.CreateRestockDraft TO WebAdminRole;
GRANT EXECUTE ON dbo.usp_SalesStatistics TO WebAdminRole,WebStaffRole;
GRANT SELECT ON app.fn_DailySalesTrend TO WebAdminRole,WebStaffRole;
GRANT SELECT ON app.fn_ProductSalesRank TO WebAdminRole,WebStaffRole;
GO
PRINT N'第十至十二周整合已部署：网页的结算、盘点、入库、补货建议和经营统计均改为调用数据库过程与函数';
