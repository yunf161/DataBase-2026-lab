/* 第五周 ER 核对：全程只读，可在现有 CampusStoreDB 中重复执行。 */
USE CampusStoreDB;
GO

-- 1. 实际表清单：预期 10 张核心表；Member 未实现。
SELECT t.name AS TableName
FROM sys.tables AS t
WHERE t.schema_id = SCHEMA_ID(N'dbo')
  AND t.name IN (N'Category',N'Supplier',N'Employee',N'Product',N'Inventory',
                 N'PurchaseOrder',N'PurchaseItem',N'SaleOrder',N'SaleItem',N'InventoryLog')
ORDER BY t.name;
SELECT CASE WHEN OBJECT_ID(N'dbo.Member',N'U') IS NULL THEN N'未实现（符合 v0.1）'
            ELSE N'已存在：请重新核对本周 ER 图' END AS MemberStatus;

-- 2. 外键映射：应与 business-rules.md 中 12 条已实现 FK 一一对应。
SELECT OBJECT_NAME(f.parent_object_id) AS ChildTable,
       pc.name AS ChildColumn,
       OBJECT_NAME(f.referenced_object_id) AS ParentTable,
       rc.name AS ParentColumn,
       pc.is_nullable AS ChildColumnNullable
FROM sys.foreign_keys AS f
JOIN sys.foreign_key_columns AS fc ON fc.constraint_object_id = f.object_id
JOIN sys.columns AS pc ON pc.object_id = fc.parent_object_id AND pc.column_id = fc.parent_column_id
JOIN sys.columns AS rc ON rc.object_id = fc.referenced_object_id AND rc.column_id = fc.referenced_column_id
WHERE f.parent_object_id IN (
    OBJECT_ID(N'dbo.Category'), OBJECT_ID(N'dbo.Product'), OBJECT_ID(N'dbo.Inventory'),
    OBJECT_ID(N'dbo.PurchaseOrder'), OBJECT_ID(N'dbo.PurchaseItem'),
    OBJECT_ID(N'dbo.SaleOrder'), OBJECT_ID(N'dbo.SaleItem'), OBJECT_ID(N'dbo.InventoryLog'))
ORDER BY ChildTable, ChildColumn;

-- 2a. 主键及唯一索引：可对照实体表中的 PK、AK、UQ。
SELECT t.name AS TableName, i.name AS IndexName,
       CASE WHEN i.is_primary_key = 1 THEN 'PK'
            WHEN i.has_filter = 1 THEN 'UQ_filtered'
            ELSE 'AK_or_UQ' END AS KeyKind,
       STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS KeyColumns
FROM sys.tables AS t
JOIN sys.indexes AS i ON i.object_id = t.object_id
JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE t.schema_id = SCHEMA_ID(N'dbo') AND i.is_unique = 1 AND ic.key_ordinal > 0
  AND t.name IN (N'Category',N'Supplier',N'Employee',N'Product',N'Inventory',
                 N'PurchaseOrder',N'PurchaseItem',N'SaleOrder',N'SaleItem',N'InventoryLog')
GROUP BY t.name, i.name, i.is_primary_key, i.has_filter
ORDER BY t.name, KeyKind, IndexName;

-- 3. 采购示例：一张单对应可乐和纸巾两条明细，证明单据与商品不是 1:1。
SELECT po.PurchaseNo, p.SKU, p.ProductName, pi.Quantity, pi.UnitCost, pi.LineAmount
FROM dbo.PurchaseOrder AS po
JOIN dbo.PurchaseItem AS pi ON pi.PurchaseID = po.PurchaseID
JOIN dbo.Product AS p ON p.ProductID = pi.ProductID
WHERE po.PurchaseNo = 'PO-DEMO-001'
ORDER BY p.SKU;

-- 4. 销售示例：当前单据不含 MemberID，无法判断顾客是否会员。
SELECT so.SaleNo, so.Status, e.EmployeeNo, p.SKU,
       si.Quantity, si.UnitPrice, si.LineAmount, so.PayableAmount
FROM dbo.SaleOrder AS so
JOIN dbo.Employee AS e ON e.EmployeeID = so.EmployeeID
JOIN dbo.SaleItem AS si ON si.SaleID = so.SaleID
JOIN dbo.Product AS p ON p.ProductID = si.ProductID
WHERE so.SaleNo = 'SO-DEMO-001';

-- 5. 库存及流水：样例数据导入后，可乐 27、纸巾 6；库存缺行检查应无结果。
SELECT p.SKU, p.ProductName, i.Quantity, i.MinQuantity
FROM dbo.Product AS p
LEFT JOIN dbo.Inventory AS i ON i.ProductID = p.ProductID
WHERE p.SKU IN ('P0001','P0002')
ORDER BY p.SKU;
SELECT p.SKU, l.ChangeType, l.ChangeQuantity,
       l.BeforeQuantity, l.AfterQuantity, l.BusinessNo
FROM dbo.InventoryLog AS l
JOIN dbo.Product AS p ON p.ProductID = l.ProductID
WHERE l.BusinessNo IN ('PO-DEMO-001','SO-DEMO-001')
ORDER BY p.SKU, l.LogID;
SELECT p.SKU AS ProductMissingInventory
FROM dbo.Product AS p
LEFT JOIN dbo.Inventory AS i ON i.ProductID = p.ProductID
WHERE i.ProductID IS NULL;

-- 6. 已确认/已完成订单缺明细：正常业务过程创建的数据应无结果。
SELECT po.PurchaseNo AS ConfirmedOrderWithoutItem
FROM dbo.PurchaseOrder AS po
WHERE po.Status = 'RECEIVED'
  AND NOT EXISTS (SELECT 1 FROM dbo.PurchaseItem AS pi WHERE pi.PurchaseID = po.PurchaseID);
SELECT so.SaleNo AS CompletedOrderWithoutItem
FROM dbo.SaleOrder AS so
WHERE so.Status = 'COMPLETED'
  AND NOT EXISTS (SELECT 1 FROM dbo.SaleItem AS si WHERE si.SaleID = so.SaleID);
GO
