param([string]$ServerInstance='localhost',[Parameter(Mandatory=$true)][string]$DatabaseName,
      [ValidateSet('Before','After')][string]$Phase='Before')
$ErrorActionPreference='Stop'
if ($DatabaseName -notmatch '^CampusStoreDB_W6_[0-9a-f]{12}$') { throw '迁移边界测试禁止连接正式库' }
. (Join-Path $PSScriptRoot 'Audit-Sql.ps1')
$c=Open-TestConnection $ServerInstance $DatabaseName
$source=[System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'sql\week6\migration.sql'))
$migration=([regex]::Split($source,'(?im)^GO\s*$') | Where-Object { $_.Trim() }) -join "`n"
function Assert-MigrationRejected([string]$Setup,[int[]]$Expected,[string]$Label) {
    $before=Get-TestSnapshot $c
    $errorNumber=0
    try {
        if ($Setup) { Invoke-TestSql $c $Setup }
        # 动态批次执行同一份真实迁移脚本，能捕获其中编译/运行异常。
        $cmd=$c.CreateCommand()
        $cmd.CommandText='EXEC sys.sp_executesql @script'
        $cmd.CommandTimeout=30
        [void]$cmd.Parameters.Add('@script',[System.Data.SqlDbType]::NVarChar,-1)
        $cmd.Parameters['@script'].Value=$migration
        try { [void]$cmd.ExecuteNonQuery() } finally { $cmd.Dispose() }
    } catch {
        $errorNumber=(Get-TestSqlError $_.Exception).Number
    } finally {
        Invoke-TestSql $c 'IF XACT_STATE()<>0 ROLLBACK;'
    }
    $after=Get-TestSnapshot $c
    if ($errorNumber -notin $Expected -or $before -cne $after) {
        throw "$Label 失败：错误 $errorNumber，数据/列/对象定义/权限一致=$($before -ceq $after)"
    }
    Write-Host "$Label 通过：实际错误 $errorNumber；前后数据、列、对象定义与权限完全一致"
}
try {
    if ($Phase -eq 'Before') {
        Assert-MigrationRejected @'
BEGIN TRAN;
UPDATE dbo.InventoryLog SET BusinessNo='__W6_NO_MATCH__'
WHERE LogID=(SELECT MIN(LogID) FROM dbo.InventoryLog WHERE ChangeType='PURCHASE_IN');
'@ @(51613) '未匹配来源拒绝'
        Assert-MigrationRejected @'
BEGIN TRAN;
CREATE TABLE week6.MigrationHistory(
 MigrationCode varchar(30) NOT NULL PRIMARY KEY,
 AppliedAt datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
 Description nvarchar(255) NOT NULL);
INSERT week6.MigrationHistory(MigrationCode,Description) VALUES('W6-INVLOG-FK',N'故障注入：迁移末尾主键冲突');
'@ @(2627,2601) '迁移末尾失败整体回滚'
    } else {
        Assert-MigrationRejected '' @(51610,51611) '重复迁移拒绝'
    }
} finally { $c.Dispose() }
