/* 第 4 周：可在 SSMS 直接执行的多表查询，均只读。先运行 view.sql。 */
USE CampusStoreDB;
GO
-- 采购明细：一张单、供应商、商品与当次进价的连接。
SELECT po.PurchaseNo,s.SupplierName,p.SKU,p.ProductName,
       pi.Quantity,pi.UnitCost,pi.LineAmount
FROM dbo.PurchaseOrder AS po
JOIN dbo.Supplier AS s ON s.SupplierID=po.SupplierID
JOIN dbo.PurchaseItem AS pi ON pi.PurchaseID=po.PurchaseID
JOIN dbo.Product AS p ON p.ProductID=pi.ProductID
WHERE po.Status='RECEIVED'
ORDER BY po.PurchaseNo,p.SKU;

-- 销售明细：成交价从 SaleItem 读取，不随商品现价变化。
SELECT so.SaleNo,e.EmployeeName,p.ProductName,
       si.Quantity,si.UnitPrice,si.LineAmount
FROM dbo.SaleOrder AS so
JOIN dbo.Employee AS e ON e.EmployeeID=so.EmployeeID
JOIN dbo.SaleItem AS si ON si.SaleID=so.SaleID
JOIN dbo.Product AS p ON p.ProductID=si.ProductID
WHERE so.Status='COMPLETED'
ORDER BY so.SaleNo,p.SKU;

-- 库存预警和两类统计。
SELECT SKU,ProductName,Quantity,MinQuantity,StockStatus
FROM dbo.v_current_inventory
WHERE StockStatus IN ('LOW_STOCK','OUT_OF_STOCK')
ORDER BY SKU;
SELECT SKU,ProductName,SoldQuantity,SalesAmount
FROM dbo.v_product_sales ORDER BY SKU;
SELECT SupplierCode,SupplierName,ReceivedOrderCount,PurchaseAmount
FROM dbo.v_supplier_purchases ORDER BY SupplierCode;
SELECT SaleDate,OrderCount,SalesAmount
FROM dbo.v_daily_sales ORDER BY SaleDate;

-- 聚合与 HAVING：按商品汇总已完成销售，只保留销售额达到 10 元的商品。
-- JOIN 负责把商品、销售明细和销售单拼接起来，GROUP BY 再把明细按商品归组。
SELECT p.SKU,p.ProductName,
       SUM(si.Quantity) AS SoldQuantity,
       SUM(si.LineAmount) AS SalesAmount
FROM dbo.Product AS p
JOIN dbo.SaleItem AS si ON si.ProductID=p.ProductID
JOIN dbo.SaleOrder AS so ON so.SaleID=si.SaleID
WHERE so.Status='COMPLETED'
GROUP BY p.SKU,p.ProductName
HAVING SUM(si.LineAmount)>=10.00
ORDER BY SalesAmount DESC,p.SKU;

-- 子查询：找出销售额不低于“有销量商品平均销售额”的商品。
-- 内层查询先计算平均值，外层查询再用该结果筛选商品。
SELECT ps.SKU,ps.ProductName,ps.SoldQuantity,ps.SalesAmount
FROM dbo.v_product_sales AS ps
WHERE ps.SoldQuantity>0
  AND ps.SalesAmount>=(
      SELECT AVG(CONVERT(decimal(18,2),x.SalesAmount))
      FROM dbo.v_product_sales AS x
      WHERE x.SoldQuantity>0
  )
ORDER BY ps.SalesAmount DESC,ps.SKU;
GO
