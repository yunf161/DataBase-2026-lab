# 第八周验证记录（2026-10-28）

## 验证方法和结果

每次运行均创建随机 `CampusStoreDB_W7_Test_*`，从冻结 v0.1 建库、执行第六周迁移并部署第七、八周应用增量；测试结束自动删除该随机库。没有向正式 `CampusStoreDB` 写入。

| 项目 | 实际结果 | 证据 |
| --- | --- | --- |
| 真实 SQL Server 集成测试 | 72 项通过（第七周 59 项、第八周 13 项） | [原始输出](results/integration-output.txt) |
| 管理员双商品采购 | 草稿不入库，确认后两商品增库、有 2 条关联流水；重复确认 409。直接调用数据库过程发生金额超限也不会留下半条明细 | `tests/week7/week8/test_business_flows.py`、[草稿桌面](results/00-purchase-draft.png)、[草稿窄屏](results/00-purchase-draft-mobile.png)、[窄屏底部操作](results/00-purchase-draft-mobile-bottom.png)、[入库后](results/01-purchase-received.png) |
| 店员销售结算 | 当前表单支付方式、优惠、备注与结算同事务保存；数量扣减和流水同步；重复结算 409，库存不足时草稿及原支付信息保持不变 | 同上、[截图](results/03-sale-completed.png) |
| 管理员盘点 | 正负数量均记录原因、员工与前后量；零变化、负库存、越权被拒绝；直接 SQL 调用时流水失败也回滚库存；页面错误不泄露 SQL 原文 | 同上、[成功截图](results/02-stocktake.png)、[失败提示](results/02-stocktake-error.png) |
| 权限与浏览器 | 管理员、店员、顾客页面按角色显示；顾客直接访问采购 API 返回 403；第100件之后的商品可搜索；初始化请求失败返回可见登录页；浏览器 7 条检查通过、无 JavaScript 异常 | [浏览器结果](results/browser-results.json)、[窄屏截图](results/04-customer-mobile.png) |
| 隔离清理 | 自动清理随机测试库 | [汇总](results/summary.json) |

数据库错误转换为 `BUSINESS_RULE` 等稳定代码，页面展示用户提示，不显示 SQL Server 原始错误；第七周原有认证、CSRF、订单归属、商品和库存功能继续由回归测试覆盖。所有新增 DAO 调用使用 `?` 参数绑定。第八周 SQL 使用 `CREATE OR ALTER`，已有 W7 库可增量部署；采购明细写入和盘点过程也有自身的事务/保存点。

## 本机复跑

先执行[README](README.md)中的依赖安装。后端测试只需要 Python 环境与 SQL Server：

```powershell
.\.venv\Scripts\python.exe -m pytest -q
```

端到端脚本还需 Node.js、`playwright` 包及浏览器。可在项目外或项目根目录安装 Node 依赖（不会修改数据库）：

```powershell
npm install --no-save --no-package-lock playwright@1.64.0
npx playwright install chromium
.\.venv\Scripts\python.exe -m tools.verify_week8 --server '.\SQLEXPRESS'
```

已有 Edge/Chromium 可设置 `PLAYWRIGHT_CHROMIUM_EXECUTABLE` 为其 exe 绝对路径；`NODE_PATH` 可指向已有 Playwright 的 `node_modules`，`--node` 可指定 Node 可执行文件。本机验收使用现有 Edge 与已有 Node Playwright；Python 版 Playwright 下载发生超时，不影响已执行的 Node 浏览器验收。只测后端可加 `--skip-browser`；浏览器调试时可用 `--skip-integration` 复用已生成的后端结果。汇总和截图会写入 `docs/week8-application/results`。

## 尚未覆盖

本周按任务完成角色页面、事务和集成验证；未加入退货、真实支付流水、多门店或生产级独立数据库登录账号。顾客界面不展示库存，采购列表目前适合课程样例数据量；大量采购单需要后端分页。第九周可继续完善最终交付与更大范围的测试。
