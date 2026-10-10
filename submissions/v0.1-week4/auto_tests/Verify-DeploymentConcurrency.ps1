# 自动回归专项检查，由同目录 Verify-CampusStore.ps1 调用。
param([string]$ServerInstance='localhost',[Parameter(Mandatory=$true)][string]$DatabaseName)
$ErrorActionPreference='Stop'
if ($DatabaseName -notmatch '^CampusStoreDB_Verify_[0-9a-f]{12}$') {
    throw '专项测试禁止连接正式数据库'
}
$guardDb=$DatabaseName+'_Guard'
$connections=@()
$guardCreated=$false
function Open-AuditConnection([string]$db) {
    $builder=New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source']=$ServerInstance
    $builder['Initial Catalog']=$db
    $builder['Integrated Security']=$true
    $builder['Encrypt']=$false
    $builder['TrustServerCertificate']=$true
    $builder['Asynchronous Processing']=$true
    $conn=New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
    $conn.Open()
    return $conn
}
function Run-AuditSql($conn,[string]$sql) {
    $command=$conn.CreateCommand()
    $command.CommandText=$sql
    $command.CommandTimeout=20
    try { [void]$command.ExecuteNonQuery() } finally { $command.Dispose() }
}
function Get-AuditScalar($conn,[string]$sql) {
    $command=$conn.CreateCommand()
    $command.CommandText=$sql
    $command.CommandTimeout=20
    try { return $command.ExecuteScalar() } finally { $command.Dispose() }
}
try {
    $control=Open-AuditConnection 'master'
    $connections+=,$control
    Run-AuditSql $control "CREATE DATABASE [$guardDb];"
    $guardCreated=$true
    $guard=Open-AuditConnection $guardDb
    $connections+=,$guard
    Run-AuditSql $guard 'CREATE TABLE dbo.AuditSentinel(Value int); INSERT dbo.AuditSentinel VALUES(123);'
    $source=Join-Path (Split-Path -Parent $PSScriptRoot) 'sql\01_create_campus_store_database.sql'
    $sql=[System.IO.File]::ReadAllText($source).Replace('CampusStoreDB',$guardDb)
    $refused=0
    foreach ($batch in [regex]::Split($sql,'(?im)^GO\s*$')) {
        if (-not $batch.Trim()) { continue }
        # 故意不遇错退出，模拟普通查询窗口继续发送后续批次。
        try { Run-AuditSql $guard $batch }
        catch {
            $failure=$_.Exception
            while ($failure.InnerException) { $failure=$failure.InnerException }
            if ($failure.Number -notin @(50000,50001)) { throw }
            $refused++
        }
    }
    $guard.ChangeDatabase($guardDb)
    if ($refused -lt 2 -or (Get-AuditScalar $guard 'SELECT COUNT(*) FROM sys.tables') -ne 1 -or
        (Get-AuditScalar $guard 'SELECT Value FROM dbo.AuditSentinel') -ne 123) {
        throw '已有库误运行保护失败'
    }
    Write-Host '已有库建库保护通过：客户端继续后续批次仍被拒绝，哨兵表与数据未改动'

    $setup=Open-AuditConnection $DatabaseName
    $connections+=,$setup
    $tag=(New-Guid).ToString('N').Substring(0,12)
    $product=Get-AuditScalar $setup "DECLARE @c bigint=(SELECT TOP(1) CategoryID FROM dbo.Category ORDER BY CategoryID); INSERT dbo.Product(SKU,ProductName,CategoryID,SalePrice) VALUES('CC$tag',N'Concurrency fixture',@c,2); SELECT CONVERT(bigint,SCOPE_IDENTITY());"
    $purchase=Get-AuditScalar $setup "DECLARE @s bigint=(SELECT TOP(1) SupplierID FROM dbo.Supplier WHERE Status=1 ORDER BY SupplierID),@e bigint=(SELECT TOP(1) EmployeeID FROM dbo.Employee WHERE Status=1 ORDER BY EmployeeID); INSERT dbo.PurchaseOrder(PurchaseNo,SupplierID,EmployeeID) VALUES('CP$tag',@s,@e); DECLARE @p bigint=SCOPE_IDENTITY(); INSERT dbo.PurchaseItem(PurchaseID,ProductID,Quantity,UnitCost) VALUES(@p,$product,2,1); EXEC dbo.ConfirmPurchase @p; SELECT @p;"
    $sale=Get-AuditScalar $setup "DECLARE @e bigint=(SELECT TOP(1) EmployeeID FROM dbo.Employee WHERE Status=1 ORDER BY EmployeeID); INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod) VALUES('CS$tag',@e,'CASH'); DECLARE @s bigint=SCOPE_IDENTITY(); INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice) VALUES(@s,$product,1,2); SELECT @s;"
    $locker=Open-AuditConnection $DatabaseName
    $cashier=Open-AuditConnection $DatabaseName
    $disabler=Open-AuditConnection $DatabaseName
    $connections+=,$locker
    $connections+=,$cashier
    $connections+=,$disabler
    $lockerId=Get-AuditScalar $locker 'SELECT @@SPID'
    $cashierId=Get-AuditScalar $cashier 'SELECT @@SPID'
    Run-AuditSql $locker "BEGIN TRAN; SELECT Quantity FROM dbo.Inventory WITH (UPDLOCK,HOLDLOCK) WHERE ProductID=$product;"
    $saleCommand=$cashier.CreateCommand()
    $saleCommand.CommandTimeout=20
    $saleCommand.CommandText="EXEC dbo.CompleteSale @SaleID=$sale;"
    $pending=$saleCommand.BeginExecuteNonQuery()
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    $blocked=$false
    do {
        $blocked=(Get-AuditScalar $setup "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE session_id=$cashierId AND blocking_session_id=$lockerId AND wait_type LIKE 'LCK_M_%';") -eq 1
        if (-not $blocked) { Start-Sleep -Milliseconds 100 }
    } while (-not $blocked -and [DateTime]::UtcNow -lt $deadline -and -not $pending.IsCompleted)
    if (-not $blocked) { throw '未观察到销售通过状态检查后等待库存锁，不能判定并发测试通过' }
    # 销售已通过启用检查但尚未扣库存，另一连接尝试停用，必须因状态锁等待。
    Run-AuditSql $disabler 'SET LOCK_TIMEOUT 800;'
    $timedOut=$false
    try { Run-AuditSql $disabler "UPDATE dbo.Product SET Status=0 WHERE ProductID=$product;" }
    catch {
        $failure=$_.Exception
        while ($failure.InnerException) { $failure=$failure.InnerException }
        if ($failure.Number -ne 1222) { throw }
        $timedOut=$true
    }
    if (-not $timedOut) { throw '商品停用穿过了结算状态锁' }
    Run-AuditSql $locker 'COMMIT;'
    [void]$saleCommand.EndExecuteNonQuery($pending)
    $saleCommand.Dispose()
    if ((Get-AuditScalar $setup "SELECT Quantity FROM dbo.Inventory WHERE ProductID=$product;") -ne 1 -or
        (Get-AuditScalar $setup "SELECT COUNT(*) FROM dbo.SaleOrder WHERE SaleID=$sale AND Status='COMPLETED';") -ne 1) {
        throw '并发销售结算结果错误'
    }
    Run-AuditSql $disabler 'SET LOCK_TIMEOUT 5000;'
    Run-AuditSql $disabler "UPDATE dbo.Product SET Status=0 WHERE ProductID=$product;"
    if ((Get-AuditScalar $setup "SELECT Status FROM dbo.Product WHERE ProductID=$product;") -ne 0) {
        throw '结算结束后仍不能停用商品'
    }
    Write-Host '并发状态锁验证通过：结算等待库存期间停用超时，结算结束后停用成功'
}
finally {
    # 关闭连接自动撤销未完成的锁测试事务；主体临时库由调用者负责删除。
    foreach ($conn in $connections) { $conn.Dispose() }
    if ($guardCreated) {
        if ($guardDb -notmatch '^CampusStoreDB_Verify_[0-9a-f]{12}_Guard$') { throw '拒绝不安全的临时库清理' }
        $cleanup=Open-AuditConnection 'master'
        try { Run-AuditSql $cleanup "ALTER DATABASE [$guardDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$guardDb];" }
        finally { $cleanup.Dispose() }
    }
}
