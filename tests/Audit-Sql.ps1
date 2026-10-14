# 专项验证共用连接函数；调用方必须校验随机数据库名。
function Open-TestConnection([string]$ServerInstance,[string]$DatabaseName) {
    $b=[System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $b['Data Source']=$ServerInstance
    $b['Initial Catalog']=$DatabaseName
    $b['Integrated Security']=$true
    $b['Encrypt']=$false
    $b['TrustServerCertificate']=$true
    $c=[System.Data.SqlClient.SqlConnection]::new($b.ConnectionString)
    $c.Open()
    return $c
}
function Invoke-TestSql($Connection,[string]$Sql,[switch]$Scalar) {
    $cmd=$Connection.CreateCommand()
    $cmd.CommandText=$Sql
    $cmd.CommandTimeout=30
    try {
        if ($Scalar) { return $cmd.ExecuteScalar() }
        [void]$cmd.ExecuteNonQuery()
    } finally { $cmd.Dispose() }
}
function Get-TestSqlError($Failure) {
    while ($Failure.InnerException) { $Failure=$Failure.InnerException }
    return $Failure
}
function Invoke-TestBatches($Connection,[string]$Sql) {
    foreach ($batch in [regex]::Split($Sql,'(?im)^GO\s*$')) {
        if ($batch.Trim()) { Invoke-TestSql $Connection $batch }
    }
}
function Get-TestSnapshot($Connection) {
    return Invoke-TestSql $Connection @'
SET NOCOUNT ON;
CREATE TABLE #AuditState(T nvarchar(257),N bigint,C int);
DECLARE @s sysname,@t sysname,@q nvarchar(max);
DECLARE audit_cursor CURSOR LOCAL FAST_FORWARD FOR
 SELECT s.name,t.name FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id ORDER BY s.name,t.name;
OPEN audit_cursor; FETCH NEXT FROM audit_cursor INTO @s,@t;
WHILE @@FETCH_STATUS=0 BEGIN
 SET @q=N'INSERT #AuditState SELECT N'''+REPLACE(@s+N'.'+@t,'''','''''')+N''',COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM '+QUOTENAME(@s)+N'.'+QUOTENAME(@t);
 EXEC(@q); FETCH NEXT FROM audit_cursor INTO @s,@t;
END;
CLOSE audit_cursor; DEALLOCATE audit_cursor;
SELECT
 (SELECT * FROM #AuditState ORDER BY T FOR JSON PATH)+
 (SELECT OBJECT_SCHEMA_NAME(object_id) AS S,OBJECT_NAME(object_id) AS N,CONVERT(varchar(64),HASHBYTES('SHA2_256',definition),2) AS H FROM sys.sql_modules ORDER BY S,N FOR JSON PATH)+
 (SELECT OBJECT_SCHEMA_NAME(o.object_id) AS S,o.name AS N,o.type AS T FROM sys.objects o WHERE o.is_ms_shipped=0 ORDER BY S,N FOR JSON PATH)+
 (SELECT OBJECT_SCHEMA_NAME(c.object_id) AS S,OBJECT_NAME(c.object_id) AS T,c.name,c.column_id,c.system_type_id,c.is_nullable FROM sys.columns c JOIN sys.objects o ON o.object_id=c.object_id WHERE o.is_ms_shipped=0 ORDER BY S,T,c.column_id FOR JSON PATH)+
 (SELECT USER_NAME(grantee_principal_id) AS G,class,major_id,minor_id,permission_name,state_desc FROM sys.database_permissions ORDER BY G,class,major_id,minor_id,permission_name FOR JSON PATH);
DROP TABLE #AuditState;
'@ -Scalar
}
