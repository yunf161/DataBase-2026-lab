/* 第 4 周：两个额外的统计视图。原有库存、销售明细、每日销售视图见 01。 */
USE CampusStoreDB;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
CREATE OR ALTER VIEW dbo.v_product_sales AS
SELECT p.ProductID,p.SKU,p.ProductName,
       COALESCE(SUM(CONVERT(bigint,si.Quantity)),0) AS SoldQuantity,
       COALESCE(SUM(si.LineAmount),CONVERT(decimal(38,2),0)) AS SalesAmount
FROM dbo.Product AS p
LEFT JOIN (
    SELECT si.ProductID,si.Quantity,si.LineAmount
    FROM dbo.SaleItem AS si
    JOIN dbo.SaleOrder AS so ON so.SaleID=si.SaleID
    WHERE so.Status='COMPLETED'
) AS si ON si.ProductID=p.ProductID
GROUP BY p.ProductID,p.SKU,p.ProductName;
GO
CREATE OR ALTER VIEW dbo.v_supplier_purchases AS
SELECT s.SupplierID,s.SupplierCode,s.SupplierName,
       COUNT(po.PurchaseID) AS ReceivedOrderCount,
       COALESCE(SUM(po.TotalAmount),CONVERT(decimal(38,2),0)) AS PurchaseAmount
FROM dbo.Supplier AS s
LEFT JOIN dbo.PurchaseOrder AS po
    ON po.SupplierID=s.SupplierID AND po.Status='RECEIVED'
GROUP BY s.SupplierID,s.SupplierCode,s.SupplierName;
GO
