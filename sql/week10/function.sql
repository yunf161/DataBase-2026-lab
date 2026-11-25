/* 第十周：函数。只做计算和查询，不修改数据；可重复执行。
   部署顺序：week10/function.sql → week10/procedure.sql → week11/trigger.sql
            → week12/order_transaction.sql → week12/restock_transaction.sql
            → week12/recursive_query.sql → week12/integration.sql
   函数里不能 THROW：参数非法或商品不存在时统一返回 NULL，由调用它的过程判断后报错。 */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]%'
    THROW 51700,N'第十至十二周对象只部署到独立 W7 应用数据库',1;
IF OBJECT_ID(N'app.SaleOwner',N'U') IS NULL OR COL_LENGTH(N'app.SaleOwner',N'SubmittedAt') IS NULL
    THROW 51700,N'请先部署第七至九周应用增量（sql/week7、week8、week9）',1;
GO
/* 补货量：补到目标库存所差的数量。
   @TargetQuantity 为 NULL（调用时写 DEFAULT）表示目标库存取“预警下限的 2 倍”。
   库存已达到或超过目标返回 0；商品没有库存记录（不存在）或目标为负数时返回 NULL；结果不会为负。 */
CREATE OR ALTER FUNCTION dbo.fn_RestockQuantity(@ProductID bigint, @TargetQuantity int = NULL)
RETURNS int
AS
BEGIN
    DECLARE @quantity int, @minimum int, @target int;
    SELECT @quantity=Quantity, @minimum=MinQuantity FROM dbo.Inventory WHERE ProductID=@ProductID;
    IF @quantity IS NULL OR @TargetQuantity < 0 RETURN NULL;
    SET @target=COALESCE(@TargetQuantity, @minimum*2);
    RETURN CASE WHEN @target>@quantity THEN @target-@quantity ELSE 0 END;
END;
GO
/* 销售汇总（内联表值函数）：只统计已完成订单，开始、结束日期都包含当天。
   开始日期晚于结束日期或任一参数为 NULL 时返回空结果。销售金额为折扣前的商品金额（明细行金额之和）。 */
CREATE OR ALTER FUNCTION dbo.fn_SalesSummary(@StartDate date, @EndDate date)
RETURNS TABLE
AS
RETURN
    SELECT p.ProductID, p.SKU, p.ProductName,
           SUM(CONVERT(bigint,si.Quantity)) AS SoldQuantity,
           SUM(si.LineAmount) AS SalesAmount,
           COUNT(DISTINCT so.SaleID) AS OrderCount
    FROM dbo.SaleOrder AS so
    JOIN dbo.SaleItem AS si ON si.SaleID=so.SaleID
    JOIN dbo.Product AS p ON p.ProductID=si.ProductID
    WHERE so.Status='COMPLETED'
      AND @StartDate<=@EndDate
      AND so.SaleTime>=CONVERT(datetime2(0),@StartDate)
      AND so.SaleTime<DATEADD(DAY,1,CONVERT(datetime2(0),@EndDate))
    GROUP BY p.ProductID, p.SKU, p.ProductName;
GO
/* 会员身份：网上顾客账号（app.AppUser.RoleName='CUSTOMER'）创建的订单视为会员订单；
   店员为到店散客开的订单不是会员订单。订单不存在返回 NULL。 */
CREATE OR ALTER FUNCTION dbo.fn_IsMemberOrder(@SaleID bigint)
RETURNS bit
AS
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.SaleOrder WHERE SaleID=@SaleID) RETURN NULL;
    RETURN CASE WHEN EXISTS (
        SELECT 1 FROM app.SaleOwner AS so JOIN app.AppUser AS u ON u.UserID=so.UserID
        WHERE so.SaleID=@SaleID AND u.RoleName='CUSTOMER') THEN 1 ELSE 0 END;
END;
GO
/* 折扣率（0.0500 表示减 5%，即 95 折）。规则：
   1. 会员订单减 5%；
   2. 订单金额满 100 元再减 5%（会员、非会员都适用）；
   合计最多减 10%。任一参数为 NULL 或金额为负时返回 NULL（非法输入）。 */
CREATE OR ALTER FUNCTION dbo.fn_DiscountRate(@IsMember bit, @OrderAmount decimal(12,2))
RETURNS decimal(5,4)
AS
BEGIN
    IF @IsMember IS NULL OR @OrderAmount IS NULL OR @OrderAmount<0 RETURN NULL;
    RETURN CONVERT(decimal(5,4),
        CASE WHEN @IsMember=1 THEN 0.05 ELSE 0 END +
        CASE WHEN @OrderAmount>=100 THEN 0.05 ELSE 0 END);
END;
GO
/* 折扣金额 = 订单金额 × 折扣率，四舍五入到分；非法输入返回 NULL。结果不会超过订单金额。 */
CREATE OR ALTER FUNCTION dbo.fn_DiscountAmount(@IsMember bit, @OrderAmount decimal(12,2))
RETURNS decimal(12,2)
AS
BEGIN
    DECLARE @rate decimal(5,4)=dbo.fn_DiscountRate(@IsMember,@OrderAmount);
    IF @rate IS NULL RETURN NULL;
    RETURN CONVERT(decimal(12,2),ROUND(@OrderAmount*@rate,2));
END;
GO
PRINT N'第十周函数已部署：fn_RestockQuantity、fn_SalesSummary、fn_IsMemberOrder、fn_DiscountRate、fn_DiscountAmount';
