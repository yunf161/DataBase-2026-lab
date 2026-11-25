/* 第十周：存储过程。会改变数据的业务（库存调整、补货选择）和需要参数检查的统计放在过程里；可重复执行。
   事务约定（与 sql/02_business_procedures.sql 一致）：调用时没有外层事务，过程自己 BEGIN TRAN / COMMIT；
   已有外层事务（例如网页一次请求的事务）时只建保存点，失败回滚到保存点并把错误抛给调用者，最终提交由外层负责。
   @Quiet=1 时不返回结果集，供 app 架构的包装过程调用，避免多出一个结果集。 */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]W7[_]%'
    THROW 51700,N'第十至十二周对象只部署到独立 W7 应用数据库',1;
IF OBJECT_ID(N'dbo.fn_RestockQuantity',N'FN') IS NULL OR OBJECT_ID(N'dbo.fn_SalesSummary',N'IF') IS NULL
    THROW 51700,N'请先部署 sql/week10/function.sql',1;
GO
-- 历史订单保存实际折扣率；第十周之前的订单是人工优惠，折扣率为 NULL，折扣金额照旧保存在 DiscountAmount。
IF COL_LENGTH(N'dbo.SaleOrder',N'DiscountRate') IS NULL
    ALTER TABLE dbo.SaleOrder ADD DiscountRate decimal(5,4) NULL
        CONSTRAINT CK_SaleOrder_DiscountRate CHECK (DiscountRate IS NULL OR DiscountRate BETWEEN 0 AND 1);
GO
/* 销售统计：开始、结束日期都包含当天（SaleTime >= 开始日 0 点，且 < 结束日次日 0 点）。
   结果集 1：区间汇总（订单数、销售数量、原价、折扣、实收），没有销售时各项为 0；
   结果集 2：区间内各商品的销售情况，来自表值函数 dbo.fn_SalesSummary，没有销售时为空。 */
CREATE OR ALTER PROCEDURE dbo.usp_SalesStatistics @StartDate date, @EndDate date
AS
BEGIN
    SET NOCOUNT ON;
    IF @StartDate IS NULL OR @EndDate IS NULL
        THROW 51701,N'开始日期和结束日期都不能为空',1;
    IF @StartDate>@EndDate
        THROW 51702,N'开始日期不能晚于结束日期',1;
    IF DATEDIFF(DAY,@StartDate,@EndDate)>3660
        THROW 51703,N'统计范围不能超过十年',1;
    DECLARE @from datetime2(0)=CONVERT(datetime2(0),@StartDate);
    DECLARE @to datetime2(0)=DATEADD(DAY,1,CONVERT(datetime2(0),@EndDate));

    SELECT @StartDate AS start_date, @EndDate AS end_date,
           COUNT(*) AS order_count,
           COALESCE(SUM(q.SoldQuantity),0) AS sold_quantity,
           COALESCE(SUM(so.TotalAmount),0) AS original_amount,
           COALESCE(SUM(so.DiscountAmount),0) AS discount_amount,
           COALESCE(SUM(so.PayableAmount),0) AS sales_amount
    FROM dbo.SaleOrder AS so
    OUTER APPLY (SELECT SUM(CONVERT(bigint,si.Quantity)) AS SoldQuantity
                 FROM dbo.SaleItem AS si WHERE si.SaleID=so.SaleID) AS q
    WHERE so.Status='COMPLETED' AND so.SaleTime>=@from AND so.SaleTime<@to;

    SELECT ProductID AS product_id, SKU AS sku, ProductName AS product_name,
           SoldQuantity AS sold_quantity, SalesAmount AS sales_amount, OrderCount AS order_count
    FROM dbo.fn_SalesSummary(@StartDate,@EndDate)
    ORDER BY SalesAmount DESC, ProductID;
END;
GO
/* 库存调整：按商品编号（SKU）增减库存。@ChangeQuantity 为正是盘盈、为负是盘亏。
   拒绝：商品不存在、调整数量为空或为零、调整后库存为负（库存不足）、原因为空、员工不存在/停用/无库存管理职责。
   成功后同时更新库存数量并写一条库存流水（STOCKTAKE_IN / STOCKTAKE_OUT），两者在同一事务中。 */
CREATE OR ALTER PROCEDURE dbo.usp_AdjustInventory
    @ProductCode varchar(30), @ChangeQuantity int, @Reason nvarchar(255), @EmployeeNo varchar(20),
    @Quiet bit=0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    DECLARE @entryTranCount int=@@TRANCOUNT, @savePointCreated bit=0;
    DECLARE @productID bigint, @employeeID bigint, @before int, @after int;
    SET @Reason=NULLIF(LTRIM(RTRIM(@Reason)),N'');
    -- 参数检查放在开事务之前：失败时不会写入任何数据。
    IF @ProductCode IS NULL OR LTRIM(RTRIM(@ProductCode))=''
        THROW 51710,N'请提供商品编号',1;
    IF @ChangeQuantity IS NULL OR @ChangeQuantity=0
        THROW 51711,N'调整数量不能为空或为零',1;
    IF @ChangeQuantity NOT BETWEEN -1000000 AND 1000000
        THROW 51711,N'单次调整数量超出范围',1;
    IF @Reason IS NULL
        THROW 51714,N'请填写调整原因',1;
    IF @EmployeeNo IS NULL
        THROW 51713,N'请提供操作员工编号',1;
    BEGIN TRY
        IF @entryTranCount=0 BEGIN TRAN;
        ELSE
        BEGIN
            SAVE TRAN AdjustInventorySave;
            SET @savePointCreated=1;
        END;
        SELECT @productID=ProductID FROM dbo.Product WITH (HOLDLOCK) WHERE SKU=@ProductCode;
        IF @productID IS NULL THROW 51710,N'商品不存在',1;
        SELECT @employeeID=EmployeeID FROM dbo.Employee WITH (HOLDLOCK)
        WHERE EmployeeNo=@EmployeeNo AND Status=1 AND RoleName IN ('ADMIN','PURCHASER');
        IF @employeeID IS NULL THROW 51713,N'操作员工不存在、已停用或没有库存管理职责',1;
        -- 锁住这一行库存直到事务结束，避免与结算、入库同时改同一商品。
        SELECT @before=Quantity FROM dbo.Inventory WITH (UPDLOCK,HOLDLOCK) WHERE ProductID=@productID;
        IF @before IS NULL THROW 51202,N'商品缺少库存记录',1;
        SET @after=@before+@ChangeQuantity;
        IF @after<0 THROW 51712,N'库存不足，调整后数量不能为负',1;
        IF @after>1000000 THROW 51711,N'调整后库存超出上限',1;

        EXEC sys.sp_set_session_context @key=N'CampusStoreOperator', @value=@employeeID;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=1;
        UPDATE dbo.Inventory SET Quantity=@after, UpdatedAt=SYSDATETIME() WHERE ProductID=@productID;
        INSERT dbo.InventoryLog(ProductID,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,
                                PurchaseID,SaleID,EmployeeID,Remark)
        VALUES(@productID,CASE WHEN @ChangeQuantity>0 THEN 'STOCKTAKE_IN' ELSE 'STOCKTAKE_OUT' END,
               @ChangeQuantity,@before,@after,NULL,NULL,@employeeID,@Reason);
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreOperator', @value=NULL;
        IF @entryTranCount=0 COMMIT;
    END TRY
    BEGIN CATCH
        IF @entryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @entryTranCount>0 AND XACT_STATE()=1 AND @savePointCreated=1
            ROLLBACK TRAN AdjustInventorySave;
        EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite', @value=NULL;
        EXEC sys.sp_set_session_context @key=N'CampusStoreOperator', @value=NULL;
        THROW;
    END CATCH;
    IF @Quiet=0
        SELECT @productID AS product_id, @ProductCode AS sku, @ChangeQuantity AS change_quantity,
               @before AS before_quantity, @after AS after_quantity;
END;
GO
/* 补货选择：找出启用商品中库存低于预警下限的，用 dbo.fn_RestockQuantity 计算补货量（补到预警下限的 2 倍），
   生成一张待入库的补货单（即采购草稿 PurchaseOrder，状态 DRAFT）。进价取该商品最近一次入库的进价，
   从未进过货的按售价的 6 成暂估，入库前可在采购页修改。草稿不改变库存，入库由 dbo.usp_ReceiveRestock 完成。
   没有需要补货的商品时拒绝，不会生成空单。 */
CREATE OR ALTER PROCEDURE dbo.usp_CreateRestockOrder
    @SupplierID bigint, @EmployeeNo varchar(20), @PurchaseID bigint=NULL OUTPUT, @Quiet bit=0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    DECLARE @entryTranCount int=@@TRANCOUNT, @savePointCreated bit=0, @employeeID bigint;
    DECLARE @lines TABLE(ProductID bigint PRIMARY KEY, Quantity int NULL, UnitCost decimal(10,2) NOT NULL);
    SET @PurchaseID=NULL;
    IF @SupplierID IS NULL THROW 51720,N'请选择供应商',1;
    IF @EmployeeNo IS NULL THROW 51713,N'请提供操作员工编号',1;
    BEGIN TRY
        IF @entryTranCount=0 BEGIN TRAN;
        ELSE
        BEGIN
            SAVE TRAN CreateRestockSave;
            SET @savePointCreated=1;
        END;
        IF NOT EXISTS (SELECT 1 FROM dbo.Supplier WITH (HOLDLOCK) WHERE SupplierID=@SupplierID AND Status=1)
            THROW 51720,N'供应商不存在或已停用',1;
        SELECT @employeeID=EmployeeID FROM dbo.Employee WITH (HOLDLOCK)
        WHERE EmployeeNo=@EmployeeNo AND Status=1 AND RoleName IN ('ADMIN','PURCHASER');
        IF @employeeID IS NULL THROW 51713,N'操作员工不存在、已停用或没有采购职责',1;

        INSERT @lines(ProductID,Quantity,UnitCost)
        SELECT p.ProductID, dbo.fn_RestockQuantity(p.ProductID,DEFAULT),
               COALESCE(lastCost.UnitCost, CONVERT(decimal(10,2),ROUND(p.SalePrice*0.6,2)))
        FROM dbo.Product AS p
        JOIN dbo.Category AS c ON c.CategoryID=p.CategoryID
        JOIN dbo.Inventory AS i WITH (HOLDLOCK) ON i.ProductID=p.ProductID
        OUTER APPLY (SELECT TOP (1) pi.UnitCost
                     FROM dbo.PurchaseItem AS pi JOIN dbo.PurchaseOrder AS po ON po.PurchaseID=pi.PurchaseID
                     WHERE pi.ProductID=p.ProductID AND po.Status='RECEIVED'
                     ORDER BY po.ReceivedTime DESC, po.PurchaseID DESC) AS lastCost
        WHERE p.Status=1 AND c.Status=1 AND i.Quantity<i.MinQuantity;
        DELETE @lines WHERE Quantity IS NULL OR Quantity<=0;
        IF NOT EXISTS (SELECT 1 FROM @lines)
            THROW 51721,N'当前没有低于预警下限、需要补货的商品',1;

        DECLARE @no varchar(30)='W10R'+LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),24);
        INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID,Remark)
        VALUES(@no,@SupplierID,@employeeID,N'按库存预警生成的补货单');
        SET @PurchaseID=CONVERT(bigint,SCOPE_IDENTITY());
        INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost)
        SELECT @PurchaseID,ProductID,Quantity,UnitCost FROM @lines;
        IF @entryTranCount=0 COMMIT;
    END TRY
    BEGIN CATCH
        IF @entryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @entryTranCount>0 AND XACT_STATE()=1 AND @savePointCreated=1
            ROLLBACK TRAN CreateRestockSave;
        SET @PurchaseID=NULL;
        THROW;
    END CATCH;
    IF @Quiet=0
        SELECT po.PurchaseID AS purchase_id, po.PurchaseNo AS purchase_no, p.SKU AS sku,
               p.ProductName AS product_name, i.Quantity AS current_quantity, i.MinQuantity AS min_quantity,
               pi.Quantity AS restock_quantity, pi.UnitCost AS unit_cost
        FROM dbo.PurchaseOrder AS po
        JOIN dbo.PurchaseItem AS pi ON pi.PurchaseID=po.PurchaseID
        JOIN dbo.Product AS p ON p.ProductID=pi.ProductID
        JOIN dbo.Inventory AS i ON i.ProductID=pi.ProductID
        WHERE po.PurchaseID=@PurchaseID ORDER BY pi.ProductID;
END;
GO
PRINT N'第十周存储过程已部署：usp_SalesStatistics、usp_AdjustInventory、usp_CreateRestockOrder';
