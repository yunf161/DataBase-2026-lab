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

try {
    $scripts = @(
        # 正式部署与结构验证，使用提交目录中的当前实现。
        '01_create_campus_store_database.sql',
        '02_business_procedures.sql',
        # 重复部署，验证已有库金额约束和业务对象能够安全同步。
        '02_business_procedures.sql',
        '04_verify.sql',

        # 装载演示数据并部署第 4 周视图、角色和对象验证。
        '03_sample_data.sql',
        'view.sql',
        'view_verify.sql',
        'constraint.sql',

        # CRUD 连续执行两次，证明随机测试数据能够自行清理并可重复运行。
        'crud.sql',
        'crud.sql',
        'role.sql',
        '06_week4_verify.sql',
        'role_demo.sql',

        # 执行多表连接、聚合、HAVING、子查询以及五个视图的只读查询。
        'query.sql',
        'query_shitu.sql',
        'verify_data.sql',
        '06_demo_observation.sql',

        # 与课堂完全共用反例源码，预期报错被捕获，最后统一判断是否通过。
        'negative_cases.sql',

        # 验证清空与重新装载：清空业务数据后再次导入，并重新检查视图和业务结果。
        '07_clear_all_data.sql',
        '03_sample_data.sql',
        'view_verify.sql',
        'query_shitu.sql',
        '06_demo_observation.sql'
    )
    foreach ($name in $scripts) {
        $source = Join-Path $scriptRoot "sql\$name"
        if (-not (Test-Path -LiteralPath $source)) {
            throw "验证清单中的脚本不存在：$name"
        }
        $target = Join-Path $tempDir $name
        # 建库脚本中的数据库名统一替换，业务测试不能碰正式库。
        $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $source
        [System.IO.File]::WriteAllText($target, $content.Replace('CampusStoreDB', $testDb),
            [System.Text.UTF8Encoding]::new($false))
        Write-Host "执行验证脚本：$name"
        $connectionDatabase = if ($name -eq '01_create_campus_store_database.sql') { 'master' } else { $testDb }
        & sqlcmd -S $ServerInstance -E -No -b -f 65001 -d $connectionDatabase -i $target
        if ($LASTEXITCODE -ne 0) { throw "验证失败：$name" }
        if ($name -eq 'negative_cases.sql') {
            & (Join-Path $PSScriptRoot 'Verify-DeploymentConcurrency.ps1') -ServerInstance $ServerInstance -DatabaseName $testDb
        }
    }
    Write-Host "隔离数据库 $testDb 的结构、业务与演示数据验证通过"
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
    if ($dropFailed) { throw "测试数据库清理失败：$testDb" }
}
