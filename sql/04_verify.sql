-- 在 master 中检查部署是否完成；缺少任何对象都应使 sqlcmd -b 返回非零值。
USE master;
GO
IF DB_ID(N'CampusStoreDB') IS NULL
    THROW 51000, N'CampusStoreDB 尚未创建', 1;
GO
USE CampusStoreDB;
GO
IF (SELECT COUNT(*) FROM sys.tables WHERE name IN
    (N'Category', N'Product', N'Supplier', N'Employee', N'Inventory',
     N'PurchaseOrder', N'PurchaseItem', N'SaleOrder', N'SaleItem', N'InventoryLog')) <> 10
    THROW 51001, N'核心表不足 10 张', 1;

IF (SELECT COUNT(*) FROM sys.views WHERE name IN
    (N'v_current_inventory', N'v_sale_detail', N'v_daily_sales')) <> 3
    THROW 51002, N'业务视图不足 3 个', 1;

IF (SELECT COUNT(*) FROM sys.procedures WHERE name IN
    (N'ConfirmPurchase', N'CompleteSale')) <> 2
    THROW 51003, N'业务过程不足 2 个', 1;

IF (SELECT COUNT(*) FROM sys.triggers WHERE name IN
    (N'tr_Product_CreateInventory', N'tr_Category_PreventCycle',
     N'tr_Inventory_QuantityGuard', N'tr_Category_SetUpdatedAt',
     N'tr_Supplier_SetUpdatedAt', N'tr_Product_SetUpdatedAt',
     N'tr_Inventory_SetUpdatedAt', N'tr_PurchaseOrder_SetUpdatedAt',
     N'tr_PurchaseItem_DraftOnly', N'tr_SaleItem_DraftOnly',
     N'tr_PurchaseOrder_StatusGuard', N'tr_SaleOrder_StatusGuard')
    AND is_disabled=0) <> 12
    THROW 51004, N'完整性和业务触发器不足 12 个或已禁用', 1;

PRINT N'结构对象验证通过';
GO
