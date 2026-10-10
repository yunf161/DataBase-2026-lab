USE CampusStoreDB;
GO

-- 1. 当前库存视图
SELECT *
FROM dbo.v_current_inventory
ORDER BY SKU;

-- 2. 销售明细视图
SELECT *
FROM dbo.v_sale_detail
ORDER BY SaleTime, SaleNo, SKU;

-- 3. 每日销售统计视图
SELECT *
FROM dbo.v_daily_sales
ORDER BY SaleDate;

-- 4. 商品销售统计视图
SELECT *
FROM dbo.v_product_sales
ORDER BY SKU;

-- 5. 供应商采购统计视图
SELECT *
FROM dbo.v_supplier_purchases
ORDER BY SupplierCode;
GO