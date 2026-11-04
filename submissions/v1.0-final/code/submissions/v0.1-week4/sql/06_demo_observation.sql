/* 在 SSMS 中执行本文件，观察仓库导入的演示业务结果。 */
USE CampusStoreDB;
GO

-- 1. 当前库存及低库存状态
SELECT
    ProductName AS 商品名称,
    CategoryName AS 商品分类,
    Quantity AS 当前库存,
    MinQuantity AS 最低库存,
    StockStatus AS 库存状态
FROM dbo.v_current_inventory
ORDER BY ProductID;
GO

-- 2. 已确认采购单及其金额
SELECT
    PurchaseNo AS 采购单号,
    Status AS 状态,
    TotalAmount AS 采购总额,
    ReceivedTime AS 入库时间
FROM dbo.PurchaseOrder
ORDER BY PurchaseID;
GO

-- 3. 已完成销售单及成交金额
SELECT
    SaleNo AS 销售单号,
    ProductName AS 商品名称,
    Quantity AS 销售数量,
    UnitPrice AS 成交单价,
    LineAmount AS 商品金额,
    PaymentMethod AS 支付方式
FROM dbo.v_sale_detail
ORDER BY SaleTime;
GO

-- 4. 每次入库与销售留下的库存流水
SELECT
    BusinessNo AS 业务单号,
    ChangeType AS 变化类型,
    ProductID AS 商品编号,
    ChangeQuantity AS 变化数量,
    BeforeQuantity AS 变化前库存,
    AfterQuantity AS 变化后库存,
    CreatedAt AS 发生时间
FROM dbo.InventoryLog
ORDER BY LogID;
GO
