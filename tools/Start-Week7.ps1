param([int]$Port=5070)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$python=Join-Path $repoRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw '请先按第七周 README 创建 .venv 并安装依赖。' }
Push-Location $repoRoot
try {
    $env:PYTHONUTF8='1'
    & $python -m app --port $Port
    if ($LASTEXITCODE -ne 0) { throw '应用启动失败，请检查本地配置、端口和后端日志。' }
} finally { Pop-Location }
