/* 订单状态保护专项：只用于随机隔离库；8 项，不保留业务测试数据。 */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT OFF;
IF DB_NAME() NOT LIKE N'CampusStoreDB[_]Verify[_]%' AND DB_NAME() NOT LIKE N'CampusStoreDB[_]W6[_]%'
    THROW 51700,N'状态专项测试只能在自动验证隔离库执行',1;
IF @@TRANCOUNT<>0 THROW 51701,N'请在无外层事务的连接运行专项测试',1;
CREATE TABLE #StatusResult(TestName nvarchar(100),Expected nvarchar(100),Actual nvarchar(200),Passed bit);
DECLARE @product bigint=(SELECT TOP(1) ProductID FROM dbo.Product WHERE Status=1 ORDER BY ProductID),
        @supplier bigint=(SELECT TOP(1) SupplierID FROM dbo.Supplier WHERE Status=1 ORDER BY SupplierID),
        @employee bigint=(SELECT TOP(1) EmployeeID FROM dbo.Employee WHERE Status=1 AND RoleName='ADMIN' ORDER BY EmployeeID),
        @kind int=1,@case int,@id bigint,@caught int,@key sysname,@value sql_variant,
        @tag varchar(12)=LEFT(REPLACE(CONVERT(varchar(36),NEWID()),'-',''),12),@name nvarchar(100);
IF @product IS NULL OR @supplier IS NULL OR @employee IS NULL THROW 51702,N'缺少专项测试基础样例',1;
WHILE @kind<=2
BEGIN
    SET @case=1;
    SET @key=IIF(@kind=1,N'CampusStorePurchaseConfirm',N'CampusStoreSaleComplete');
    WHILE @case<=3
    BEGIN
        SET @caught=0;
        BEGIN TRY
            BEGIN TRAN;
            IF @kind=1
                INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID)
                VALUES('SP'+@tag+CONVERT(varchar(1),@case),@supplier,@employee);
            ELSE
                INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod)
                VALUES('SS'+@tag+CONVERT(varchar(1),@case),@employee,'CASH');
            SET @id=SCOPE_IDENTITY();
            SET @value=NULL;
            IF @case=2 SET @value=N'not-a-number';
            IF @case=3 SET @value=@id+1000000;
            EXEC sys.sp_set_session_context @key=@key,@value=@value;
            IF @kind=1 UPDATE dbo.PurchaseOrder SET Status='RECEIVED' WHERE PurchaseID=@id;
            ELSE UPDATE dbo.SaleOrder SET Status='COMPLETED' WHERE SaleID=@id;
        END TRY
        BEGIN CATCH
            SET @caught=ERROR_NUMBER();
        END CATCH;
        IF XACT_STATE()<>0 ROLLBACK;
        EXEC sys.sp_set_session_context @key=@key,@value=NULL;
        SET @name=CONCAT(IIF(@kind=1,N'采购',N'销售'),N'直接改终态：',CHOOSE(@case,N'标记缺失',N'标记不可转换',N'标记指向其他订单'));
        INSERT #StatusResult VALUES(@name,CONCAT(N'错误 ',IIF(@kind=1,51220,51320)),CONCAT(N'错误 ',@caught),IIF(@caught=IIF(@kind=1,51220,51320),1,0));
        SET @case+=1;
    END;
    SET @kind+=1;
END;

DECLARE @before int,@after int,@amount decimal(12,2),@ok bit;
SET @kind=1;
WHILE @kind<=2
BEGIN
    SET @caught=0; SET @ok=0;
    SELECT @before=Quantity FROM dbo.Inventory WHERE ProductID=@product;
    BEGIN TRY
        BEGIN TRAN;
        IF @kind=1
        BEGIN
            INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID) VALUES('NP'+@tag,@supplier,@employee);
            SET @id=SCOPE_IDENTITY();
            INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost) VALUES(@id,@product,2,1);
            EXEC dbo.ConfirmPurchase @id;
            SELECT @amount=TotalAmount FROM dbo.PurchaseOrder WHERE PurchaseID=@id AND Status='RECEIVED';
        END
        ELSE
        BEGIN
            INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod) VALUES('NS'+@tag,@employee,'CASH');
            SET @id=SCOPE_IDENTITY();
            INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice) VALUES(@id,@product,1,2);
            EXEC dbo.CompleteSale @id;
            SELECT @amount=TotalAmount FROM dbo.SaleOrder WHERE SaleID=@id AND Status='COMPLETED';
        END;
        SELECT @after=Quantity FROM dbo.Inventory WHERE ProductID=@product;
        SET @ok=IIF(@amount=2 AND @after=@before+IIF(@kind=1,2,-1),1,0);
    END TRY
    BEGIN CATCH
        SET @caught=ERROR_NUMBER();
    END CATCH;
    IF XACT_STATE()<>0 ROLLBACK;
    INSERT #StatusResult VALUES(IIF(@kind=1,N'正常采购仍可确认',N'正常销售仍可完成'),N'金额 2.00，库存变化 +2/-1',
        CONCAT(N'错误 ',@caught,N'；库存 ',@before,N' → ',@after,N'；金额 ',@amount),IIF(@caught=0 AND @ok=1,1,0));
    SET @kind+=1;
END;
SELECT TestName,Expected,Actual,IIF(Passed=1,N'通过',N'失败') AS Result FROM #StatusResult ORDER BY TestName;
IF EXISTS(SELECT 1 FROM #StatusResult WHERE Passed=0) THROW 51709,N'状态保护专项测试存在失败',1;
PRINT N'订单状态保护专项 8 项通过';
