# 第八周：角色业务流程与事务验证

本周依据[《第7-9周任务讲解》](../../submissions/v1.0-week7/requirements/第7-9周任务讲解.docx)中的“应用开发（二）”完成管理员采购入库和盘点、店员销售结算、顾客权限隔离，并把订单、明细、库存和流水接成可操作的 Web 流程。第七周应用与第六周迁移结果是基础；正式 `CampusStoreDB` 和前几周冻结包不参与本周应用测试。

## 从空环境复现

需要 Windows、SQL Server Express、ODBC Driver 18、Python 3.12+ 和可建库的 Windows 账号。先在 SSMS 看连接名；以下以 `.\SQLEXPRESS` 为例。在仓库根目录的 PowerShell 执行：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-week8.txt
.\.venv\Scripts\python.exe -m tools.prepare_week7 --server '.\SQLEXPRESS'
.\.venv\Scripts\python.exe -m app --port 5070
```

准备工具只创建不存在的 `CampusStoreDB_W7_Development`，依次建立 v0.1、执行第六周迁移、部署第七周及第八周增量、导入演示账号和数据；目标库已经存在时会拒绝覆盖。它写入不提交仓库的 `instance/settings.json`。以后只需最后一行，或使用 `tools/Start-Week7.ps1`。浏览器打开 <http://127.0.0.1:5070>。演示账号 `admin`、`staff`、`customer`、`customer2`，密码均为 `Campus2026!`，仅供本地课堂演示。

`requirements-week8.txt` 只包含应用与 SQL 集成测试依赖。第七周旧版 Python Playwright 验收需要完整的 `requirements-lock.txt`；本周浏览器脚本改用下文说明的 Node Playwright。

如果已有第七周开发库及 `instance/settings.json`，**不要再次运行准备工具**；仅运行一次增量部署命令，再启动应用：

```powershell
.\.venv\Scripts\python.exe -m tools.deploy_week8
.\.venv\Scripts\python.exe -m app --port 5070
```

增量脚本使用 `CREATE OR ALTER` 与重复授权，可以再次执行；不重建表、不清空订单。可用 `--server`、`--database` 指向另一现有 `CampusStoreDB_W7_*` 应用库。首次运行前可自行备份长期使用的开发库。`sql/week8/application.sql` 的库名和基础对象检查会拒绝正式库。

## 页面怎么操作

1. 管理员登录 → 左侧“采购入库” →“新建采购”选供应商 → 加入两种商品、数量与进价 →“确认入库”。确认前库存不变；确认后采购状态为“已入库”，库存增加且有采购流水。草稿明细可更新、移除或取消。
2. 管理员进入“库存查询”，查看新数量；点“盘点调整”，填正数或负数与原因，再二次确认。页面显示调整后的数量；盘点流水含原因和前后量。
3. 店员登录 →“销售订单”→“新建草稿”→ 加入商品 →“完成结算”。完成后库存减少、产生销售流水，不能再次结算。
4. 顾客登录只看商品货架和本人订单；无采购、盘点、结算入口。直接请求这些 API 也会返回 403。

详细步骤与 SSMS 查看方式见[操作手册](user-manual.md)。

## 代码路径与事务

页面 `app/templates/index.html`、`app/static/app.js` → `app/routes.py` → `app/services.py` → `app/repositories.py` → `sql/week8/application.sql`。所有 Web 输入通过 `?` 绑定参数；服务层校验角色、状态、数量并在一次事务中调用数据库过程；数据库过程/约束再次拦截非法状态。采购确认调用既有 `dbo.ConfirmPurchase`，销售结算调用既有 `dbo.CompleteSale`；盘点在同一事务写库存与流水。失败时回滚并返回统一 `code/message/request_id`，不把 SQL 原文显示给用户。数据库身份按既有 W7 方案模拟受限 Web 用户，非独立生产账号。

## 验证与交付文件

隔离验证会创建随机 `CampusStoreDB_W7_Test_*` 测试库，结束后清理；不会操作开发库或正式库。后端集成测试：

```powershell
.\.venv\Scripts\python.exe -m pytest -q
```

浏览器验收需要 Node.js、Playwright 包及 Chromium/Edge，见[验证记录](verification.md)。测试原始输出、JSON 汇总和截图在 `results/`。

- [API 与角色矩阵](api.md)
- [操作手册及 SQL 查看](user-manual.md)
- [验证记录与边界](verification.md)
- [第二阶段报告素材](report-material.md)
- [第八周 AI 使用记录](ai-log.md)
