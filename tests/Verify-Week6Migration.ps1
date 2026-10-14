# 在随机临时数据库中复现 v0.1、采集基线、迁移并回归，最后仅删除本脚本创建的数据库。
param(
    [string]$ServerInstance = 'localhost'
)

$ErrorActionPreference = 'Stop'
$testId = (New-Guid).ToString('N').Substring(0, 12)
$testDb = "CampusStoreDB_W6_$testId"
$repoRoot = Split-Path -Parent $PSScriptRoot
$baselineRoot = Join-Path $repoRoot 'submissions\v0.1-week4\sql'
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "campus-store-w6-$testId"
New-Item -ItemType Directory -Path $tempDir | Out-Null
$runFailed = $false

try {
    $scripts = @(
        (Join-Path $baselineRoot '01_create_campus_store_database.sql'),
        (Join-Path $baselineRoot '02_business_procedures.sql'),
        (Join-Path $baselineRoot 'view.sql'),
        (Join-Path $baselineRoot 'role.sql'),
        (Join-Path $baselineRoot '03_sample_data.sql'),
        (Join-Path $repoRoot 'sql\week6\baseline.sql'),
        (Join-Path $repoRoot 'sql\week6\migration.sql'),
        (Join-Path $repoRoot 'sql\06_demo_observation.sql'),
        (Join-Path $repoRoot 'sql\week6\regression.sql')
    )

    foreach ($source in $scripts) {
        if (-not (Test-Path -LiteralPath $source)) { throw "缺少脚本：$source" }
        $target = Join-Path $tempDir ([System.IO.Path]::GetFileName($source))
        $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $source
        # v0.1 建库脚本使用固定库名，需要替换；week6 脚本依赖当前连接数据库并校验 W6 前缀。
        $isWeek6Script = $source.StartsWith((Join-Path $repoRoot 'sql\week6'), [System.StringComparison]::OrdinalIgnoreCase)
        $prepared = if ($isWeek6Script) { $content } else { $content.Replace('CampusStoreDB', $testDb) }
        [System.IO.File]::WriteAllText($target,$prepared,[System.Text.UTF8Encoding]::new($false))
        Write-Host "执行 $([System.IO.Path]::GetFileName($source))"
        if ([System.IO.Path]::GetFileName($source) -eq '01_create_campus_store_database.sql') {
            & sqlcmd -S $ServerInstance -E -No -b -f 65001 -i $target
        }
        else {
            & sqlcmd -S $ServerInstance -E -No -b -f 65001 -d $testDb -i $target
        }
        if ($LASTEXITCODE -ne 0) { throw "第六周验证失败：$source" }
    }
    Write-Host "第六周迁移在隔离数据库 $testDb 中验证通过"
}
catch {
    $runFailed = $true
    throw
}
finally {
    $dropFailed = $false
    if ($testDb -match '^CampusStoreDB_W6_[0-9a-f]{12}$') {
        $dropSql = "USE master; IF DB_ID(N'$testDb') IS NOT NULL BEGIN ALTER DATABASE [$testDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$testDb]; END"
        & sqlcmd -S $ServerInstance -E -No -b -Q $dropSql
        $dropFailed = $LASTEXITCODE -ne 0
    }
    if (Test-Path -LiteralPath $tempDir) {
        Get-ChildItem -LiteralPath $tempDir -File | Remove-Item
        Remove-Item -LiteralPath $tempDir
    }
    if ($dropFailed) {
        if ($runFailed) { Write-Warning "测试数据库清理也失败：$testDb；请在连接恢复后手动检查" }
        else { throw "测试数据库清理失败：$testDb" }
    }
}
