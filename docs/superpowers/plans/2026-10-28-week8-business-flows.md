# 第八周业务流程实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 W7 Flask 应用中完成采购入库、销售结算和受控盘点，验证角色权限、库存/流水事务与统一错误反馈，并推送 `lzq`。

**Architecture:** 保留页面→route→service→repository→SQL Server 的分层。新增 `sql/week8/application.sql` 提供数据库受限入口，调用已有 `dbo.ConfirmPurchase`/`dbo.CompleteSale`；盘点单独以事务更新库存和流水。仅在独立 W7 数据库部署，正式库不迁移。

**Tech Stack:** Python/Flask、pyodbc、SQL Server Express、pytest、Playwright、PowerShell。

---

### Task 1: 基线与环境

**Files:** `tools/prepare_week7.py`、`tools/verify_week7.py`、`requirements-lock.txt`、`docs/week7-application/results/summary.json`

- [ ] 创建本地 `.venv` 并安装锁定依赖；确认 SQL Server Express 与 ODBC Driver 18 可连接。
- [ ] 在随机库运行现有第七周后端测试，记录基线；不动正式 `CampusStoreDB`。
- [ ] 检查已存在 W7 开发库时的增量部署路径与清理边界。

### Task 2: 先证明缺口，再实现 SQL 入口

**Files:** `tests/week8/test_business_flows.py`、`sql/week8/application.sql`、`tools/prepare_week7.py`

- [ ] 测试先断言管理员可建立两商品采购草稿、确认后两商品入库并有对应流水；当前缺少入口，测试应失败。
- [ ] 测试先断言店员结算草稿后订单完成、库存减少、销售流水正确；重复结算和库存不足均拒绝且不改库存。
- [ ] 测试先断言只有管理员可盘点，正负调整记录原因与前后量；越权、零变化或负库存均被拒绝。
- [ ] 新增 W8 SQL 视图和包装过程；只向对应 Web 数据库角色授权 EXEC/SELECT。所有过程先检查 W7 库名与应用身份，并保留原业务过程事务边界。
- [ ] 更新准备工具仅在全新 W7 库中顺序部署 W7→W8；为已存在 W7 库提供显式、不会覆盖数据的部署命令。
- [ ] 重跑针对性 SQL/集成测试，直到新增用例通过且 W7 回归不退化。

### Task 3: 后端分层接口

**Files:** `app/repositories.py`、`app/services.py`、`app/routes.py`、`docs/week8-application/api.md`

- [ ] 对新增 API 先写 401/403/400/409/成功与事务回滚测试。
- [ ] repository 仅用 `?` 参数绑定调用受限视图/过程；service 校验角色、输入、状态并管理同一事务；route 复用登录、CSRF 和统一异常。
- [ ] 对多商品采购与结算读回数据库真实状态；顾客不得通过 API 调用这些操作。
- [ ] 重跑新增测试和原 59 项 W7 测试。

### Task 4: 页面与浏览器验证

**Files:** `app/templates/index.html`、`app/static/app.js`、`app/static/app.css`、`tools/verify_week8_browser.py`

- [ ] 先增加浏览器验收：管理员采购与盘点、店员结算、顾客无入口且越权请求被拒绝、失败提示不泄露 SQL。
- [ ] 在现有页面风格中增加操作入口；前端校验必填、数值范围和二次确认，提交后刷新订单/库存/流水。
- [ ] 用隔离库运行真实浏览器测试，检查桌面与 390px 宽度无功能遮挡。

### Task 5: 文档与交付

**Files:** `README.md`、`docs/week8-application/README.md`、`verification.md`、`user-manual.md`、`report-material.md`

- [ ] 写空环境依赖安装、隔离库初始化、启动与演示顺序；说明既有 W7 库升级方式。
- [ ] 保存成功/失败测试证据和角色差异；核对前端、service、DAO、SQL 四层路径。
- [ ] 运行完整集成/浏览器/SQL 回归、`git diff --check` 与仓库状态检查；仅暂存本周文件，保留本地 AI 使用记录。
- [ ] 提交并推送 `lzq`，最终核对 `origin/lzq` 与本地一致。
