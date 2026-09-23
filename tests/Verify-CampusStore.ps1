# 在独立数据库中运行 SQL 验证；结束时只删除本脚本创建的数据库。
$ErrorActionPreference = 'Stop'
$testId = (New-Guid).ToString('N').Substring(0, 12)
$testDb = "CampusStoreDB_Verify_$testId"
$scriptRoot = Split-Path -Parent $PSScriptRoot
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "campus-store-verify-$testId"
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    $scripts = @(
        '01_create_campus_store_database.sql',
        '02_business_procedures.sql',
        '04_verify.sql',
        '05_business_verify.sql',
        '03_sample_data.sql'
    )
    foreach ($name in $scripts) {
        $source = Join-Path $scriptRoot "sql\$name"
        $target = Join-Path $tempDir $name
        # 建库脚本中的数据库名统一替换，业务测试不能碰正式库。
        $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $source
        [System.IO.File]::WriteAllText($target, $content.Replace('CampusStoreDB', $testDb),
            [System.Text.UTF8Encoding]::new($false))
        & sqlcmd -S '.\SQLEXPRESS' -E -No -b -f 65001 -i $target
        if ($LASTEXITCODE -ne 0) { throw "验证失败：$name" }
    }
    Write-Host "隔离数据库 $testDb 的结构、业务与演示数据验证通过"
}
finally {
    # 名称由固定前缀和十六进制随机串生成，避免误删其他数据库。
    $dropFailed = $false
    if ($testDb -match '^CampusStoreDB_Verify_[0-9a-f]{12}$') {
        $dropSql = "USE master; IF DB_ID(N'$testDb') IS NOT NULL BEGIN ALTER DATABASE [$testDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$testDb]; END"
        & sqlcmd -S '.\SQLEXPRESS' -E -No -b -Q $dropSql
        $dropFailed = $LASTEXITCODE -ne 0
    }
    Get-ChildItem -LiteralPath $tempDir -File | Remove-Item
    Remove-Item -LiteralPath $tempDir
    if ($dropFailed) { throw "测试数据库清理失败：$testDb" }
}
