/* 第 4 周：主键、外键、检查约束的目录查询与非法数据演示。DDL 定义在 01。 */
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
SET XACT_ABORT OFF;
SET NOCOUNT ON;

SELECT t.name AS TableName,k.name AS ConstraintName,k.type_desc AS ConstraintType
FROM sys.key_constraints AS k
JOIN sys.tables AS t ON t.object_id=k.parent_object_id
ORDER BY t.name,k.type_desc;
SELECT OBJECT_NAME(parent_object_id) AS ChildTable,name AS ForeignKeyName,
       OBJECT_NAME(referenced_object_id) AS ParentTable
FROM sys.foreign_keys ORDER BY ChildTable,ForeignKeyName;
SELECT OBJECT_NAME(parent_object_id) AS TableName,name AS CheckName,definition
FROM sys.check_constraints ORDER BY TableName,CheckName;

IF (SELECT COUNT(*) FROM sys.key_constraints WHERE type='PK')<>10
    THROW 51810,N'主键数量不是 10',1;
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
               WHERE parent_object_id=OBJECT_ID(N'dbo.Product')
                 AND referenced_object_id=OBJECT_ID(N'dbo.Category'))
    THROW 51811,N'商品到分类的外键缺失',1;
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name=N'CK_Product_Price')
    THROW 51812,N'售价检查约束缺失',1;

DECLARE @categoryID bigint=(SELECT TOP (1) CategoryID FROM dbo.Category ORDER BY CategoryID);
IF @categoryID IS NULL THROW 51813,N'请先导入演示数据',1;
BEGIN TRY
    INSERT dbo.Product(SKU,ProductName,CategoryID,SalePrice)
    VALUES ('BAD-PRICE',N'非法负价',@categoryID,-1.00);
    THROW 51800,N'负价没有被 CHECK 拒绝',1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>547 THROW;
    PRINT N'负售价被 CHECK 约束拒绝';
END CATCH;

BEGIN TRY
    INSERT dbo.Product(SKU,ProductName,CategoryID,SalePrice)
    VALUES ('BAD-FK',N'非法分类',-1,1.00);
    THROW 51801,N'无效分类没有被外键拒绝',1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER()<>547 THROW;
    PRINT N'无效分类被外键拒绝';
END CATCH;

BEGIN TRY
    INSERT dbo.Product(SKU,ProductName,CategoryID,SalePrice)
    VALUES ('P0001',N'重复编号',@categoryID,1.00);
    THROW 51802,N'重复 SKU 没有被唯一约束拒绝',1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() NOT IN (2601,2627) THROW;
    PRINT N'重复 SKU 被唯一约束拒绝';
END CATCH;
GO
