/*
    清空 CampusStoreDB 中的全部业务数据，但保留：
    1. 数据库和表结构；
    2. 主键、外键、CHECK、DEFAULT 等约束；
    3. 视图、存储过程、触发器和数据库角色。

    警告：本脚本会删除 10 张核心表中的全部记录，不能恢复。
    仅在确定要重新导入演示数据时执行。
*/
USE CampusStoreDB;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'CampusStoreDB'
    THROW 52000, N'安全检查失败：当前数据库不是 CampusStoreDB', 1;

BEGIN TRY
    BEGIN TRAN;

    /*
       已完成订单的明细受触发器保护，正常业务操作不能删除。
       数据重置期间临时停用两个明细保护触发器，结束前一定重新启用。
    */
    DISABLE TRIGGER dbo.tr_PurchaseItem_DraftOnly ON dbo.PurchaseItem;
    DISABLE TRIGGER dbo.tr_SaleItem_DraftOnly ON dbo.SaleItem;

    -- 先删除依赖其他表的数据，再删除被引用的基础资料。
    DELETE FROM dbo.InventoryLog;
    DELETE FROM dbo.PurchaseItem;
    DELETE FROM dbo.SaleItem;
    DELETE FROM dbo.PurchaseOrder;
    DELETE FROM dbo.SaleOrder;
    DELETE FROM dbo.Inventory;
    DELETE FROM dbo.Product;
    DELETE FROM dbo.Category;
    DELETE FROM dbo.Supplier;
    DELETE FROM dbo.Employee;

    -- 让下一次导入演示数据时，各表的自增主键重新从 1 开始。
    DBCC CHECKIDENT ('dbo.Category', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dbo.Supplier', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dbo.Employee', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dbo.Product', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dbo.PurchaseOrder', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dbo.PurchaseItem', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dbo.SaleOrder', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dbo.SaleItem', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dbo.InventoryLog', RESEED, 0) WITH NO_INFOMSGS;

    ENABLE TRIGGER dbo.tr_PurchaseItem_DraftOnly ON dbo.PurchaseItem;
    ENABLE TRIGGER dbo.tr_SaleItem_DraftOnly ON dbo.SaleItem;

    COMMIT;
    PRINT N'CampusStoreDB 的业务数据已清空，表结构、视图、过程、触发器和角色均已保留';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;

    -- 即使清理失败，也确保业务保护触发器处于启用状态。
    ENABLE TRIGGER dbo.tr_PurchaseItem_DraftOnly ON dbo.PurchaseItem;
    ENABLE TRIGGER dbo.tr_SaleItem_DraftOnly ON dbo.SaleItem;
    THROW;
END CATCH;
GO

-- 清理结果：以下 10 个计数都应为 0。
SELECT N'Category' AS TableName, COUNT_BIG(*) AS RecordCount FROM dbo.Category
UNION ALL SELECT N'Supplier', COUNT_BIG(*) FROM dbo.Supplier
UNION ALL SELECT N'Employee', COUNT_BIG(*) FROM dbo.Employee
UNION ALL SELECT N'Product', COUNT_BIG(*) FROM dbo.Product
UNION ALL SELECT N'Inventory', COUNT_BIG(*) FROM dbo.Inventory
UNION ALL SELECT N'PurchaseOrder', COUNT_BIG(*) FROM dbo.PurchaseOrder
UNION ALL SELECT N'PurchaseItem', COUNT_BIG(*) FROM dbo.PurchaseItem
UNION ALL SELECT N'SaleOrder', COUNT_BIG(*) FROM dbo.SaleOrder
UNION ALL SELECT N'SaleItem', COUNT_BIG(*) FROM dbo.SaleItem
UNION ALL SELECT N'InventoryLog', COUNT_BIG(*) FROM dbo.InventoryLog;
GO
