/* 第 4 周：主键、外键、检查约束对象查询与检查。DDL 定义在 01；非法数据演示统一在 negative_cases.sql。 */
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

PRINT N'主键、外键和 CHECK 对象检查通过；非法操作统一在 negative_cases.sql 展示';
GO
