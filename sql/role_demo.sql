/* 第 4 周：在同一数据库会话模拟不同用户，演示授权查询与越权失败。 */
USE CampusStoreDB;
GO
SET NOCOUNT ON;
IF DATABASE_PRINCIPAL_ID(N'CourseDemoViewer') IS NOT NULL
    OR DATABASE_PRINCIPAL_ID(N'CourseDemoCashier') IS NOT NULL
    OR DATABASE_PRINCIPAL_ID(N'CourseDemoPurchaser') IS NOT NULL
    THROW 51910,N'演示用户已存在，请先检查旧演示是否完整结束',1;

BEGIN TRY
    CREATE USER CourseDemoViewer WITHOUT LOGIN;
    CREATE USER CourseDemoCashier WITHOUT LOGIN;
    CREATE USER CourseDemoPurchaser WITHOUT LOGIN;
    ALTER ROLE CampusViewer ADD MEMBER CourseDemoViewer;
    ALTER ROLE CampusCashier ADD MEMBER CourseDemoCashier;
    ALTER ROLE CampusPurchaser ADD MEMBER CourseDemoPurchaser;

    EXECUTE AS USER=N'CourseDemoViewer';
    SELECT TOP (3) SKU,ProductName,Quantity FROM dbo.v_current_inventory ORDER BY SKU;
    BEGIN TRY
        SELECT TOP (1) ProductID FROM dbo.Product;
        THROW 51900,N'只读视图用户越权读取了商品表',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>229 THROW;
        PRINT N'只读视图用户直接查商品表被拒绝';
    END CATCH;
    REVERT;

    EXECUTE AS USER=N'CourseDemoCashier';
    IF HAS_PERMS_BY_NAME(N'dbo.CompleteSale',N'OBJECT',N'EXECUTE')<>1
        THROW 51901,N'收银员缺少销售结算权限',1;
    BEGIN TRY
        UPDATE dbo.Inventory SET Quantity=Quantity WHERE ProductID=-1;
        THROW 51902,N'收银员越权修改库存',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>229 THROW;
        PRINT N'收银员直接修改库存被拒绝';
    END CATCH;
    REVERT;

    EXECUTE AS USER=N'CourseDemoPurchaser';
    IF HAS_PERMS_BY_NAME(N'dbo.ConfirmPurchase',N'OBJECT',N'EXECUTE')<>1
        THROW 51903,N'采购员缺少采购确认权限',1;
    BEGIN TRY
        UPDATE dbo.Inventory SET Quantity=Quantity WHERE ProductID=-1;
        THROW 51904,N'采购员越权修改库存',1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER()<>229 THROW;
        PRINT N'采购员直接修改库存被拒绝';
    END CATCH;
    REVERT;

    ALTER ROLE CampusViewer DROP MEMBER CourseDemoViewer;
    ALTER ROLE CampusCashier DROP MEMBER CourseDemoCashier;
    ALTER ROLE CampusPurchaser DROP MEMBER CourseDemoPurchaser;
    DROP USER CourseDemoViewer;
    DROP USER CourseDemoCashier;
    DROP USER CourseDemoPurchaser;
    PRINT N'角色权限演示通过，临时用户已删除';
END TRY
BEGIN CATCH
    IF USER_NAME() IN (N'CourseDemoViewer',N'CourseDemoCashier',N'CourseDemoPurchaser')
        REVERT;
    IF DATABASE_PRINCIPAL_ID(N'CourseDemoViewer') IS NOT NULL
    BEGIN
        ALTER ROLE CampusViewer DROP MEMBER CourseDemoViewer;
        DROP USER CourseDemoViewer;
    END;
    IF DATABASE_PRINCIPAL_ID(N'CourseDemoCashier') IS NOT NULL
    BEGIN
        ALTER ROLE CampusCashier DROP MEMBER CourseDemoCashier;
        DROP USER CourseDemoCashier;
    END;
    IF DATABASE_PRINCIPAL_ID(N'CourseDemoPurchaser') IS NOT NULL
    BEGIN
        ALTER ROLE CampusPurchaser DROP MEMBER CourseDemoPurchaser;
        DROP USER CourseDemoPurchaser;
    END;
    THROW;
END CATCH;
GO
