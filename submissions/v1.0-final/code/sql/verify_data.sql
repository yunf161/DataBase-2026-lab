USE CampusStoreDB;
GO

SELECT
    p.SKU,
    p.ProductName,
    i.Quantity,
    i.MinQuantity
FROM dbo.Product AS p
JOIN dbo.Inventory AS i
    ON i.ProductID = p.ProductID
ORDER BY p.SKU;