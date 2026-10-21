# 在独立数据库中运行 SQL 验证；结束时只删除本脚本创建的数据库。
param(
    [string]$ServerInstance = 'localhost'
)

$ErrorActionPreference = 'Stop'
$testId = (New-Guid).ToString('N').Substring(0, 12)
$testDb = "CampusStoreDB_Verify_$testId"
$scriptRoot = Split-Path -Parent $PSScriptRoot
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "campus-store-verify-$testId"
New-Item -ItemType Directory -Path $tempDir | Out-Null
$runFailed = $false

try {
    $scripts = @(
        '01_create_campus_store_database.sql',
        '02_business_procedures.sql',
        '04_verify.sql',
        '03_sample_data.sql',
        'view.sql',
        'view_verify.sql',
        'constraint.sql',
        'crud.sql',
        'crud.sql',
        'role.sql',
        '06_week4_verify.sql',
        'role_demo.sql',
        'query.sql',
        'week5-er-verification.sql',
        # 该脚本保留随机业务数据，应在依赖固定样例行数的验证完成后执行。
        'negative_cases.sql',
        'order_status_verify.sql'
    )
    foreach ($name in $scripts) {
        $source = if ($name -eq 'week5-er-verification.sql') {
            Join-Path $scriptRoot 'docs\week5-er\verification.sql'
        } else { Join-Path $scriptRoot "sql\$name" }
        $target = Join-Path $tempDir $name
        # 建库脚本中的数据库名统一替换，业务测试不能碰正式库。
        $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $source
        $prepared = if ($name -eq 'order_status_verify.sql') { $content } else { $content.Replace('CampusStoreDB', $testDb) }
        [System.IO.File]::WriteAllText($target, $prepared,
            [System.Text.UTF8Encoding]::new($false))
        $connectionDb = if ($name -eq '01_create_campus_store_database.sql') { 'master' } else { $testDb }
        Write-Host "执行 $name"
        & sqlcmd -S $ServerInstance -E -No -b -f 65001 -d $connectionDb -i $target
        if ($LASTEXITCODE -ne 0) { throw "验证失败：$name" }
    }
    & (Join-Path $PSScriptRoot 'Verify-FailureCleanup.ps1') -ServerInstance $ServerInstance -DatabaseName $testDb -Mode Negative
    & (Join-Path $PSScriptRoot 'Verify-DeploymentConcurrency.ps1') -ServerInstance $ServerInstance -DatabaseName $testDb
    Write-Host "隔离数据库 $testDb 的结构、业务与演示数据验证通过"
}
catch {
    $runFailed = $true
    throw
}
finally {
    # 名称由固定前缀和十六进制随机串生成，避免误删其他数据库。
    $dropFailed = $false
    if ($testDb -match '^CampusStoreDB_Verify_[0-9a-f]{12}$') {
        $dropSql = "USE master; IF DB_ID(N'$testDb') IS NOT NULL BEGIN ALTER DATABASE [$testDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$testDb]; END"
        & sqlcmd -S $ServerInstance -E -No -b -Q $dropSql
        $dropFailed = $LASTEXITCODE -ne 0
    }
    Get-ChildItem -LiteralPath $tempDir -File | Remove-Item
    Remove-Item -LiteralPath $tempDir
    if ($dropFailed) {
        if ($runFailed) { Write-Warning "测试数据库清理也失败：$testDb；请在连接恢复后手动检查" }
        else { throw "测试数据库清理失败：$testDb" }
    }
}
