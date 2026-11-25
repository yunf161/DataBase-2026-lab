/* 第十一周：窗口函数查询（只读，不改数据）。
   窗口函数不减少行数：每一行仍是一个商品或一天，统计结果作为新列放在这一行旁边。
   统计口径：只算已完成订单；商品金额是折扣前的明细行金额，日实收是扣除折扣后的应付金额。 */
SET NOCOUNT ON;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]%'
    THROW 51700,N'窗口查询在 W7 应用数据库上运行',1;

/* 1. 排名：按销售额给全部商品排名（没卖出的商品销售额为 0，也参与排名）。
   RANK：销售额相同的并列同一名次，下一名跳号；DENSE_RANK：并列后不跳号；ROW_NUMBER：每行唯一序号，
   并列时再按销量、商品编号区分。业务用途：找出畅销品优先补货、陈列，排在末尾的考虑促销或下架。 */
PRINT N'1. 商品销售额排名';
SELECT p.SKU AS [商品编号], p.ProductName AS [商品名称],
       COALESCE(s.SoldQuantity,0) AS [销售数量], COALESCE(s.SalesAmount,0) AS [销售金额],
       COALESCE(s.OrderCount,0) AS [订单数],
       RANK() OVER (ORDER BY COALESCE(s.SalesAmount,0) DESC) AS [RANK排名],
       DENSE_RANK() OVER (ORDER BY COALESCE(s.SalesAmount,0) DESC) AS [DENSE_RANK排名],
       ROW_NUMBER() OVER (ORDER BY COALESCE(s.SalesAmount,0) DESC, COALESCE(s.SoldQuantity,0) DESC, p.SKU) AS [ROW_NUMBER序号]
FROM dbo.Product AS p
LEFT JOIN dbo.fn_SalesSummary('2000-01-01', CONVERT(date,SYSDATETIME())) AS s ON s.ProductID=p.ProductID
ORDER BY [ROW_NUMBER序号];

/* 2. 累计值：按销售日期从早到晚累计实收金额和销售数量。
   排序字段是销售日期（ORDER BY SaleDate），窗口从第一天到当前行（ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW）。
   业务用途：看到截至每一天的营业额进度，例如月度目标完成情况。 */
PRINT N'2. 按日期的累计实收与累计销量';
WITH daily AS (
    SELECT CONVERT(date,so.SaleTime) AS SaleDate, COUNT(DISTINCT so.SaleID) AS OrderCount,
           SUM(so.PayableAmount) AS SalesAmount
    FROM dbo.SaleOrder AS so
    WHERE so.Status='COMPLETED'
    GROUP BY CONVERT(date,so.SaleTime)
), qty AS (
    SELECT CONVERT(date,so.SaleTime) AS SaleDate, SUM(CONVERT(bigint,si.Quantity)) AS SoldQuantity
    FROM dbo.SaleOrder AS so JOIN dbo.SaleItem AS si ON si.SaleID=so.SaleID
    WHERE so.Status='COMPLETED'
    GROUP BY CONVERT(date,so.SaleTime)
)
SELECT d.SaleDate AS [销售日期], d.OrderCount AS [订单数], d.SalesAmount AS [当日实收],
       SUM(d.SalesAmount) OVER (ORDER BY d.SaleDate ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS [累计实收],
       q.SoldQuantity AS [当日销量],
       SUM(q.SoldQuantity) OVER (ORDER BY d.SaleDate ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS [累计销量]
FROM daily AS d JOIN qty AS q ON q.SaleDate=d.SaleDate
ORDER BY d.SaleDate;

/* 3. 移动平均：最近 3 天（含当天）的平均日实收。
   先用数字表生成从第一笔销售到今天的每一天，没有销售的日子按 0 计入，因此“最近 3 天”是日历上的连续 3 天，
   而不是“最近 3 个有销售的日子”。窗口范围 ROWS BETWEEN 2 PRECEDING AND CURRENT ROW；
   最开始两天不足 3 天，按实际天数平均（[窗口天数] 列给出）。
   业务用途：平滑单日波动，观察销售趋势，为第四阶段的补货预测提供参考。 */
PRINT N'3. 最近 3 天移动平均实收';
DECLARE @first date=(SELECT MIN(CONVERT(date,SaleTime)) FROM dbo.SaleOrder WHERE Status='COMPLETED');
DECLARE @last date=CONVERT(date,SYSDATETIME());
WITH digits AS (SELECT n FROM (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS d(n)),
days AS (
    SELECT DATEADD(DAY,a.n+b.n*10+c.n*100,@first) AS SaleDate
    FROM digits AS a CROSS JOIN digits AS b CROSS JOIN digits AS c
    WHERE a.n+b.n*10+c.n*100<=DATEDIFF(DAY,@first,@last)
), daily AS (
    SELECT CONVERT(date,SaleTime) AS SaleDate, SUM(PayableAmount) AS SalesAmount
    FROM dbo.SaleOrder WHERE Status='COMPLETED'
    GROUP BY CONVERT(date,SaleTime)
)
SELECT d.SaleDate AS [日期], COALESCE(s.SalesAmount,0) AS [当日实收],
       COUNT(*) OVER (ORDER BY d.SaleDate ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS [窗口天数],
       CONVERT(decimal(12,2),AVG(COALESCE(s.SalesAmount,0))
           OVER (ORDER BY d.SaleDate ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)) AS [近3天平均实收]
FROM days AS d LEFT JOIN daily AS s ON s.SaleDate=d.SaleDate
ORDER BY d.SaleDate;
