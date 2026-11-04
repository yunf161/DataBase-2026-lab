/* 正常授权展示：只读列出角色权限，越权反例统一在 negative_cases.sql。 */
USE CampusStoreDB;
GO
SELECT role.name AS 数据库角色,p.state_desc AS 授权状态,p.permission_name AS 权限,
       OBJECT_SCHEMA_NAME(p.major_id) AS 架构,OBJECT_NAME(p.major_id) AS 对象,
       CASE WHEN p.minor_id>0 THEN COL_NAME(p.major_id,p.minor_id) END AS 字段
FROM sys.database_permissions AS p
JOIN sys.database_principals AS role ON role.principal_id=p.grantee_principal_id
WHERE role.name IN (N'CampusViewer',N'CampusPurchaser',N'CampusCashier',N'CampusAdmin')
ORDER BY role.name,对象,权限,字段;
PRINT N'正常角色权限展示完成；实际越权操作在 negative_cases.sql 汇总执行';
GO
