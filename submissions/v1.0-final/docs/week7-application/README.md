# 第七至九周：Web应用、下单结算与库存调整

本目录是第二阶段应用部分的文档。Flask + SQL Server Web程序，管理员维护商品、库存、盘点调整和采购入库；
店员受理并结算顾客提交的订单；顾客浏览在售商品、加入购物车、提交并查看自己的订单。
登录、参数化查询、统一异常、数据库最小权限、订单归属和真实集成验证均已接通。
应用使用第六周迁移后的数据结构，原正式库及第1—6周冻结提交保持原样。
项目总览、运行方法和测试结果以[根目录README](../../README.md)为准，本页保留第七周的运行细节。

## 范围

第七周：登录/退出、三角色界面、商品增改查及安全删除、库存查询/预警阈值维护、订单查询、草稿创建、明细增改删、
支付方式/备注/店员优惠维护、草稿取消。
第八至九周：顾客购物车和提交订单（`app.SubmitSale`，写入 `app.SaleOwner.SubmittedAt`）、店员/管理员结算
（`app.SettleSale`，调用既有 `dbo.CompleteSale` 扣库存并写流水）、管理员库存调整和库存流水查看、待受理筛选、
环境预检（`tools.doctor`）和旧开发库升级（`tools.upgrade_week9`）。
草稿和待受理订单不扣库存，界面不会把它们展示为已完成销售。采购入库在草稿阶段不增加库存，确认后经 `dbo.ConfirmPurchase` 增加库存并写流水（第八周实现，当时的记录见[第八周](../week8-application/README.md)）。

## 环境与首次运行

第七周当时的验证环境为Windows x64、Python 3.14.2、SQL Server Express、ODBC Driver 18、Flask 3.1.3、pyodbc 5.3.0；
最终验证环境（Windows、SQL Server 2025 Developer 默认实例、Python 3.13.12、ODBC Driver 18）见[验证记录](verification.md)。
数据库实例以SSMS实际连接名为准：Express通常是 `.\SQLEXPRESS`，默认实例写 `"."`。
准备工具使用的Windows账号需有建库权限；应用连接账号需能连接新库并模拟四个受限用户。

在项目根目录执行：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-lock.txt
.\.venv\Scripts\python.exe -m tools.doctor --server '.\SQLEXPRESS'
.\.venv\Scripts\python.exe -m tools.prepare_week7 --server '.\SQLEXPRESS'
.\.venv\Scripts\python.exe -m app --port 5070
```

`tools.doctor` 只读预检Python、依赖、ODBC驱动、SQL Server连接、建库权限以及开发库和
`instance/settings.json`，每项给出通过/失败和修复建议，有失败项时退出码非0；它不创建任何数据库。
默认实例的服务器名写 `"."`，Express通常写 `.\SQLEXPRESS`。
准备、升级和验收工具默认选用已安装的最高版本“ODBC Driver xx for SQL Server”，
可用 `--driver` 指定，所选驱动写入 `instance/settings.json` 的 `DB_DRIVER`。

打开 <http://127.0.0.1:5070>。之后启动只需要最后一行，也可运行
`powershell -NoProfile -ExecutionPolicy Bypass -File tools\Start-Week7.ps1 -Port 5070`（不受脚本执行策略影响）。
准备工具建立 `CampusStoreDB_W7_Development`：从冻结v0.1建立随机W6副本，
执行原baseline.sql和migration.sql，再将新副本改为W7名称并部署应用增量。
它不迁移正式CampusStoreDB，不覆盖已有目标库，不重跑固定名称01/03到正式库。
要另建演示环境可加 `--database CampusStoreDB_W7_Team2`，不要为重演删除已有业务库。
`instance/settings.json` 保存本地配置及随机签名密钥，instance目录不提交仓库。

演示账号密码均为 **Campus2026!**，仅用于本地课程演示：

| 用户名 | 角色 | 员工关联 |
| --- | --- | --- |
| admin | 管理员 | E001，ADMIN |
| staff | 店员 | E003，CASHIER |
| customer | 顾客 | 无 |
| customer2 | 另一顾客，用于验证订单隔离 | 无 |

密码以带盐scrypt哈希保存，不在Employee表或会话中保存明文密码。
服务只监听127.0.0.1；后续部署HTTPS时应启用SESSION_COOKIE_SECURE并配置独立凭据，
不能将演示账号直接作为正式运营账号。

## 配置

默认读取instance/settings.json，可用CAMPUS_SETTINGS指定另一份文件。
CAMPUS_DB_SERVER、CAMPUS_DB_DATABASE、CAMPUS_DB_DRIVER、CAMPUS_SECRET_KEY可覆盖相应配置。
应用只接受CampusStoreDB_W7_*库名，签名密钥至少32字符。
账号、角色及员工状态每次请求重新核实，前端role/employee_id不作为授权依据。
DEFAULT_CASHIER_NO默认E003，顾客草稿由该有效收银员工受理；
用户账号ID始终与EmployeeID分开，不能用顾客ID填员工外键。

## 四层结构

```text
app/templates、app/static     页面：表单、列表、弹窗，调用JSON API
app/routes.py                请求处理：解析输入、会话/CSRF，调用业务服务
app/services.py              业务：验证、角色、草稿状态、整次操作的事务边界
app/repositories.py          DAO：参数化SQL、受限视图/过程调用
app/database.py              连接、执行身份、提交/回滚和释放
sql/week7/application.sql    数据库：账号/归属、视图、过程和授权
```

商品查询：页面 → GET /api/products → StoreService.products → DAO → app.v_Catalog → JSON → 表格。
商品修改：表单 → PUT /api/products/id → 业务校验ADMIN及输入 → DAO绑定参数UPDATE →
数据库约束/更新时间触发器 → 提交 → 重新查询。失败统一处理并回滚。
用户值只通过?参数绑定；准备工具中的标识符来自严格校验的库名及随机串，
属于本地管理操作，不接受Web表单输入。

## 权限与数据库

十张核心业务表不变，新增app.AppUser和app.SaleOwner。
旧订单保持无应用归属，不自动指定给顾客；员工可查旧订单，顾客只查自己的新订单。
WebAuth、WebAdmin、WebStaff、WebCustomer均不是db_owner，业务身份不能读密码表或直接改库存数量。

本机SQL Server仅启用Windows身份验证，本地方案使用Windows连接后立即切换到固定受限用户；
切换失败终止，不回退到管理员执行业务SQL。每请求使用新物理连接，关闭连接池，结束撤销模拟并关闭连接。
后端将账号ID写入只读SESSION_CONTEXT，数据库视图再次过滤顾客订单。
这沿用已有SQL角色模拟思路，不表示已经配置独立低权限登录凭据。
后续部署应使用只具连接/必要模拟权限的专用服务账号，或配置对应受限登录。
详细表结构、权限和边界见[架构与安全说明](architecture.md)。

## 复现验证

完整验收分别使用随机SQL测试库和浏览器测试库，不操作长期开发库：

```powershell
.\.venv\Scripts\python.exe -m playwright install chromium
.\.venv\Scripts\python.exe -m tools.verify_week7 --server '.\SQLEXPRESS'
```

已有Chromium可加 `--browser-executable '浏览器exe绝对路径'`；只测后端可加 `--skip-browser`。
测试库结束清理，开发库保留供课堂演示。验证数、逐项结果、原始输出和截图见[验证记录](verification.md)。

- [操作手册](user-manual.md)
- [架构、状态流转、权限与事务边界](architecture.md)
- [API输入输出与权限](api.md)
- [数据字典：app 架构](data-dictionary.md)
- [第七周报告素材](report-material.md)
- [三人分工填写样例](teamwork-template.md)

AI使用记录见仓库根目录的 `ai_log/`。

## 实现参考

框架组织采用[Flask应用工厂](https://flask.palletsprojects.com/en/stable/patterns/appfactories/)；
异常集中注册[错误处理器](https://flask.palletsprojects.com/en/stable/errorhandling/)；
密码哈希使用[Werkzeug安全工具](https://werkzeug.palletsprojects.com/en/stable/utils/#werkzeug.security.generate_password_hash)；
参数绑定与连接管理参考[pyodbc项目文档](https://github.com/mkleehammer/pyodbc/wiki/Getting-started)。
