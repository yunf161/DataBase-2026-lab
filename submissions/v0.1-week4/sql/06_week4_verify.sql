-- 部署 view.sql 和 role.sql 后运行；缺少任何第 4 周对象都会失败。
USE CampusStoreDB;
GO
IF OBJECT_ID(N'dbo.v_product_sales', N'V') IS NULL
    THROW 51500, N'缺少商品销售统计视图', 1;
IF OBJECT_ID(N'dbo.v_supplier_purchases', N'V') IS NULL
    THROW 51501, N'缺少供应商采购统计视图', 1;
IF DATABASE_PRINCIPAL_ID(N'CampusViewer') IS NULL
    THROW 51502, N'缺少只读角色', 1;
IF DATABASE_PRINCIPAL_ID(N'CampusPurchaser') IS NULL
    THROW 51503, N'缺少采购角色', 1;
IF DATABASE_PRINCIPAL_ID(N'CampusCashier') IS NULL
    THROW 51504, N'缺少收银角色', 1;
PRINT N'第 4 周对象验证通过';
GO
