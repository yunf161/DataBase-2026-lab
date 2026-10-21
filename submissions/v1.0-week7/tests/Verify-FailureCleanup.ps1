param([string]$ServerInstance='localhost',[Parameter(Mandatory=$true)][string]$DatabaseName,
      [ValidateSet('Negative','Week6')][string]$Mode)
$ErrorActionPreference='Stop'
if ($DatabaseName -notmatch '^CampusStoreDB_(Verify|W6)_[0-9a-f]{12}$') { throw '清理故障测试禁止连接正式库' }
. (Join-Path $PSScriptRoot 'Audit-Sql.ps1')
$c=Open-TestConnection $ServerInstance $DatabaseName
$root=Split-Path -Parent $PSScriptRoot
function Run-ExpectedFault([string]$Sql,[int]$Expected,[string]$Label) {
    $caught=0
    try { Invoke-TestBatches $c $Sql } catch { $caught=(Get-TestSqlError $_.Exception).Number }
    if ($caught -ne $Expected) { throw "$Label 错误不符：实际 $caught，预期 $Expected" }
    if ((Invoke-TestSql $c "SELECT COUNT(*) FROM sys.database_principals WHERE name IN ('Week6ViewerProbe','Week6PurchaserProbe','Week6CashierProbe','Week6AdminProbe','CourseDemoViewer','CourseDemoCashier','CourseDemoPurchaser','AuditPurchaser','AuditCashier','AuditAdmin');" -Scalar) -ne 0) {
        throw "$Label 遗留探针用户"
    }
    Write-Host "$Label：实际错误 $caught；探针用户清理通过"
}
try {
    if ($Mode -eq 'Week6') {
        $source=[System.IO.File]::ReadAllText((Join-Path $root 'sql\week6\regression.sql'))
        $anchor='SET @adminCreated=1;'
        if (-not $source.Contains($anchor)) { throw '找不到回归故障注入位置' }
        Run-ExpectedFault ($source.Replace($anchor,$anchor+"`nTHROW 51625,N'探针创建后故障注入',1;")) 51625 '回归用户异常路径清理'
    } else {
        $source=[System.IO.File]::ReadAllText((Join-Path $root 'sql\negative_cases.sql'))
        $anchors=@('SET @fatalTriggerCreated=1;', '    DROP TRIGGER dbo.tr_TransactionAuditFatal;')
        foreach ($anchor in $anchors) {
            if (-not $source.Contains($anchor)) { throw '找不到事务故障注入位置' }
            if ($anchor -eq $anchors[0]) {
                $injected=$source.Replace($anchor,$anchor+"`nTHROW 52995,N'清理专项故障注入',1;")
            } else {
                # 只在正常路径的删除前注入，保留 CATCH 中的实际清理语句。
                $position=$source.IndexOf($anchor)
                $injected=$source.Insert($position,"THROW 52995,N'清理专项故障注入',1;`n")
            }
            Run-ExpectedFault $injected 52999 '事务触发器异常路径'
            $failures=Invoke-TestSql $c "SELECT COUNT(*) FROM #NegativeResults WHERE Result=N'失败' AND Details=N'清理专项故障注入';" -Scalar
            $totalFailures=Invoke-TestSql $c "SELECT COUNT(*) FROM #NegativeResults WHERE Result=N'失败';" -Scalar
            $remaining=Invoke-TestSql $c "SELECT IIF(OBJECT_ID(N'dbo.tr_TransactionAuditFatal',N'TR') IS NULL AND OBJECT_ID(N'tempdb..#EarlierWork') IS NULL,0,1);" -Scalar
            if ($failures -ne 1 -or $totalFailures -ne 1 -or $remaining -ne 0) { throw '故障注入未准确命中清理路径，或触发器/临时表遗留' }
            Write-Host '事务触发器与临时表均已清理；仅故障注入产生 1 项预期组失败'
        }
        Invoke-TestSql $c 'CREATE TRIGGER dbo.tr_TransactionAuditFatal ON dbo.SaleOrder AFTER UPDATE AS BEGIN SET NOCOUNT ON; END;'
        try {
            Run-ExpectedFault $source 52999 '已有对象拒绝覆盖'
            $present=Invoke-TestSql $c "SELECT IIF(OBJECT_ID(N'dbo.tr_TransactionAuditFatal',N'TR') IS NOT NULL,1,0);" -Scalar
            $expectedFailure=Invoke-TestSql $c "SELECT COUNT(*) FROM #NegativeResults WHERE Result=N'失败' AND Details=N'事务测试触发器已经存在，拒绝覆盖已有对象';" -Scalar
            if ($present -ne 1 -or $expectedFailure -ne 1) { throw '已有触发器未被正确保留' }
            Write-Host '已有触发器保留通过：测试未删除他人对象'
        } finally { Invoke-TestSql $c 'DROP TRIGGER dbo.tr_TransactionAuditFatal;' }
    }
} finally {
    try { Invoke-TestSql $c 'IF XACT_STATE()<>0 ROLLBACK;' } finally { $c.Dispose() }
}
