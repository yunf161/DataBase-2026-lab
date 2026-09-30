/* 第 4 周：SQL Server 数据库角色与最小授权；可重复执行。 */
USE CampusStoreDB;
GO
IF DATABASE_PRINCIPAL_ID(N'CampusViewer') IS NULL
    EXEC(N'CREATE ROLE CampusViewer AUTHORIZATION dbo');
IF DATABASE_PRINCIPAL_ID(N'CampusPurchaser') IS NULL
    EXEC(N'CREATE ROLE CampusPurchaser AUTHORIZATION dbo');
IF DATABASE_PRINCIPAL_ID(N'CampusCashier') IS NULL
    EXEC(N'CREATE ROLE CampusCashier AUTHORIZATION dbo');
IF DATABASE_PRINCIPAL_ID(N'CampusAdmin') IS NULL
    EXEC(N'CREATE ROLE CampusAdmin AUTHORIZATION dbo');
GO

-- 浏览者仅查汇总视图，不直接修改业务表。
GRANT SELECT ON OBJECT::dbo.v_current_inventory TO CampusViewer;
GRANT SELECT ON OBJECT::dbo.v_sale_detail TO CampusViewer;
GRANT SELECT ON OBJECT::dbo.v_daily_sales TO CampusViewer;
GRANT SELECT ON OBJECT::dbo.v_product_sales TO CampusViewer;
GRANT SELECT ON OBJECT::dbo.v_supplier_purchases TO CampusViewer;

-- 采购员可建采购草稿、改草稿明细，并执行确认过程。
GRANT SELECT ON OBJECT::dbo.v_current_inventory TO CampusPurchaser;
GRANT SELECT ON OBJECT::dbo.Product TO CampusPurchaser;
GRANT SELECT ON OBJECT::dbo.Supplier TO CampusPurchaser;
GRANT SELECT ON OBJECT::dbo.Employee TO CampusPurchaser;
GRANT INSERT ON OBJECT::dbo.PurchaseOrder TO CampusPurchaser;
GRANT SELECT,INSERT,UPDATE,DELETE ON OBJECT::dbo.PurchaseItem TO CampusPurchaser;
GRANT EXECUTE ON OBJECT::dbo.ConfirmPurchase TO CampusPurchaser;
DENY UPDATE,DELETE ON OBJECT::dbo.Inventory TO CampusPurchaser;

-- 收银员可建销售草稿、改草稿明细，并执行结算过程。
GRANT SELECT ON OBJECT::dbo.v_current_inventory TO CampusCashier;
GRANT SELECT ON OBJECT::dbo.Product TO CampusCashier;
GRANT SELECT ON OBJECT::dbo.Employee TO CampusCashier;
GRANT INSERT ON OBJECT::dbo.SaleOrder TO CampusCashier;
GRANT SELECT,INSERT,UPDATE,DELETE ON OBJECT::dbo.SaleItem TO CampusCashier;
GRANT EXECUTE ON OBJECT::dbo.CompleteSale TO CampusCashier;
DENY UPDATE,DELETE ON OBJECT::dbo.Inventory TO CampusCashier;

-- 管理员维护基础资料并查看全部数据，但不直接改库存或历史流水。
GRANT SELECT ON SCHEMA::dbo TO CampusAdmin;
GRANT INSERT,UPDATE ON OBJECT::dbo.Category TO CampusAdmin;
GRANT INSERT,UPDATE ON OBJECT::dbo.Product TO CampusAdmin;
GRANT INSERT,UPDATE ON OBJECT::dbo.Supplier TO CampusAdmin;
GRANT INSERT,UPDATE ON OBJECT::dbo.Employee TO CampusAdmin;
GRANT UPDATE (MinQuantity) ON OBJECT::dbo.Inventory TO CampusAdmin;
GO
PRINT N'数据库角色和授权已部署';
GO
