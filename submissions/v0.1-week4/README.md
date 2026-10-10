# 校园小卖部进销存数据库

本项目使用 **SQL Server Express / T-SQL**，数据库名为 `CampusStoreDB`。最初的[要求文档](要求.md)以 MySQL 为例；本项目按已选定的 SQL Server 实现，不能在 MySQL 客户端中查找或运行。完整业务链是：建商品 → 建采购草稿并确认入库 → 建销售草稿并结算 → 查询库存和流水。核心数据是 10 张表，另有 5 个视图、7 个业务存储过程和完整性触发器。

## 第 1–4 周完成情况

| 周次 | 交付内容 | 对应文件 | 现场展示 |
| --- | --- | --- | --- |
| 1：业务边界 | 小卖部场景、管理员/采购员/收银员职责、采购和销售流程，以及暂不纳入的数据 | [业务说明](docs/week1-business.md) | 解释哪些信息存入数据库、哪些暂不存入 |
| 2：关系与码 | 10 张表的字段、SQL Server 类型、主码/候选码/外码及样例元组 | [关系模式说明](docs/week2-schema.md)、[建库脚本](sql/01_create_campus_store_database.sql) | 指出 `Product.CategoryID` 等外键及 `(SaleID, ProductID)` 等组合候选码 |
| 3：DDL 与 CRUD | 从空库建表、导入样例数据，以及可重复的商品增删改查 | [建库脚本](sql/01_create_campus_store_database.sql)、[样例数据](sql/03_sample_data.sql)、[CRUD 演示](sql/crud.sql) | 连续执行两次 `crud.sql`，每次创建、查询、改价并清理测试记录 |
| 4：连接、视图、完整性、授权 | 多表查询、商品销售与供应商采购统计视图、主外键和检查约束、数据库角色及越权测试 | [query.sql](sql/query.sql)、[view.sql](sql/view.sql)、[constraint.sql](sql/constraint.sql)、[role.sql](sql/role.sql)、[role_demo.sql](sql/role_demo.sql) | 展示正确统计、非法数据被拒绝、角色直接改库存被拒绝 |

第 4 周的主键、外键和 `CHECK` 的 **DDL 在建库脚本中**；`constraint.sql` 列出并验证约束对象，`role_demo.sql` 列出角色授权。所有非法操作统一在 `sql/negative_cases.sql` 中执行，使用新增测试记录和临时无登录名用户；项目没有创建真实登录账号。`Employee.RoleName` 是员工的经营职责，与 SQL Server 的数据库角色不同。

## 准备环境

安装 SQL Server Express、SQL Server Management Studio（SSMS）及 `sqlcmd`。用 Windows 身份验证连接有建库权限的 SQL Server 实例。先看 SSMS 左侧“对象资源管理器”顶部的服务器名：如果显示 `(local)\SQLEXPRESS`，下文的 `$ServerInstance` 写 `.\SQLEXPRESS`；如果是默认实例，可能写 `localhost`。**命令行与 SSMS 必须连接同一个实例**，否则会出现脚本运行成功却在 SSMS 看不到数据库的情况。

在 PowerShell 中进入本仓库根目录，设置实例名：

```powershell
Set-Location '你的仓库路径'
$ServerInstance = '.\SQLEXPRESS'  # 按 SSMS 中实际连接的服务器名修改
```

`-E` 表示 Windows 身份验证，`-No` 将连接加密设为可选，`-b` 让 SQL 错误使命令返回失败，`-f 65001` 按 UTF-8 读取中文脚本。如果系统提示找不到 `sqlcmd`，先安装命令行工具或改用下面的 SSMS 方式。

## 从空库复现

以下命令按顺序执行。`01` 会新建固定名称 `CampusStoreDB`，`03` 会导入固定单号的样例业务，**二者只在空环境执行一次**。已经有正式库时，直接看下一节的隔离验证；不要为了演示删除现有库。

```powershell
sqlcmd -S $ServerInstance -E -No -b -f 65001 -i 'sql\01_create_campus_store_database.sql'
sqlcmd -S $ServerInstance -E -No -b -f 65001 -i 'sql\02_business_procedures.sql'
sqlcmd -S $ServerInstance -E -No -b -f 65001 -i 'sql\view.sql'
sqlcmd -S $ServerInstance -E -No -b -f 65001 -i 'sql\role.sql'
sqlcmd -S $ServerInstance -E -No -b -f 65001 -i 'sql\04_verify.sql'
sqlcmd -S $ServerInstance -E -No -b -f 65001 -i 'sql\06_week4_verify.sql'
sqlcmd -S $ServerInstance -E -No -b -f 65001 -i 'sql\03_sample_data.sql'
```

`view.sql` 必须在 `role.sql` 之前执行，因为角色要获得新视图的查询权限。`02`、`view.sql` 和 `role.sql` 可重复执行，用于更新存储过程、触发器、视图和授权。结构验证成功时会看到“结构对象验证通过”和“第 4 周对象验证通过”。SSMS 用户也可按同样顺序从“文件 → 打开 → 文件”打开脚本，确认工具栏的连接实例正确，按 **F5** 执行；运行后在“数据库”节点右键刷新，展开 `CampusStoreDB`。

## 验证与课堂演示

对已有数据库，推荐先运行隔离测试。它会创建随机命名的临时数据库，执行建库、业务和第 1–4 周脚本，完成后删除该临时库；正式 `CampusStoreDB` 的订单和库存不会被测试改动。

```powershell
& '.\auto_tests\Verify-CampusStore.ps1' -ServerInstance $ServerInstance
```

测试包含正常演示和统一反例脚本，另由 `auto_tests/Verify-DeploymentConcurrency.ps1` 检查已有库误运行与商品停用并发锁。反例脚本已合并原 05、08、09 的场景，供自动测试和 SSMS 共同使用。自动测试末尾还会执行“清空临时库数据 → 再次导入 → 再次查询”。成功末尾显示“隔离数据库 … 验证通过”；非预期失败会使自动测试停止。

若需要在 SSMS 展示结果，连接同一实例后逐个打开以下脚本并按 F5：

1. [query.sql](sql/query.sql)：多表连接查询采购、销售及低库存，查看统计视图，并演示 `GROUP BY`、`HAVING` 和平均销售额子查询。
2. [06_demo_observation.sql](sql/06_demo_observation.sql)：查看演示订单、库存和库存流水。
3. [crud.sql](sql/crud.sql)：依次输出插入前、插入后、修改后和删除后的查询结果；脚本会清理自己建立的记录，可重复运行。
4. [constraint.sql](sql/constraint.sql)：列出并检查主键、外键和检查约束对象。
5. [role_demo.sql](sql/role_demo.sql)：只读展示四个数据库角色的授权。
6. [negative_cases.sql](sql/negative_cases.sql)：在同一个已部署数据库中统一执行非法数据、业务保护、角色越权和事务边界测试。先在工具栏选择 `CampusStoreDB`，取消选中文本后按 F5 完整执行。预期错误由 TRY/CATCH 捕获，继续后面的测试；非预期错误记为失败，其他组仍继续，最后汇总。脚本新增随机标识的测试数据并保留供观察，不清空原有样例。需要维护账号运行，且执行前不能有未结束的外层事务。执行顺序与截图时机见 [第一阶段实验报告](docs/第一阶段报告.docx)第 5.0 节，实际反例汇总见第 8 节。

首次导入样例数据后，可核对这些具体结果：可乐库存 **27**（采购 30 瓶、售出 3 瓶），纸巾库存 **6** 并触发低库存提示；示例采购总额 **84.00**；示例销售原价合计 **10.50**、优惠后应付 **10.00**；`v_product_sales` 中可乐销量 **3**、销售额 **10.50**。这些数值对应本仓库的固定演示数据；如果正式库后续录入了新业务，统计值会随之变化。

## 业务规则和范围

新建商品会自动生成数量为 0 的库存行。采购和销售先建 `DRAFT` 订单并写入明细，再分别执行 `dbo.ConfirmPurchase` 与 `dbo.CompleteSale`。过程在事务中核对明细、金额和库存，更新订单状态并记录库存流水；库存不足等错误会回滚。已确认订单不能改回草稿，已完成订单的明细不能改动。分类不能形成循环，库存数量只能由业务过程变动，带 `UpdatedAt` 的相关表由触发器维护更新时间。销售明细保留成交价，商品日后调价不会改写历史销售金额。

本版不含会员、真实支付流水、员工密码、退货、盘点和多门店业务；相关流水类型可预留，但不能把尚未实现的退货或盘点当作已完成功能。提交材料只保留当前实现，建库建表统一使用 `01_create_campus_store_database.sql`。

## 权限与业务回归检查

`sql/negative_cases.sql` 的“角色全流程”组使用真实采购、收银和业务管理员角色执行创建、查询、草稿修改、完成或取消流程，核对合法操作成功及越权操作被拒绝。课堂运行使用当前数据库并保留新增测试记录；自动运行由外部 runner 使用临时库，结束后删除临时库。课堂反例应放在固定样例视图截图之后，否则新增的已完成测试订单会影响全库统计，`view_verify.sql` 的固定样例断言也可能不再成立。

订单状态保护同时覆盖新增和修改，新订单必须为 `DRAFT`。非草稿订单的业务编号、金额和参与方不可改写，销售支付方式和优惠也受保护；管理员运行样例脚本所需的日期调整仍允许。确认过程从汇总明细开始持有更新锁及范围锁，直至事务结束，保证总额与库存处理使用一致的明细。

权限边界是这四个数据库角色；`Employee.RoleName` 不会自动认证数据库用户，也没有按员工划分订单的行级权限。`SESSION_CONTEXT` 是会话标记，不是安全凭证，任何会话可设置自己的标记；直接表写入仍依赖最小授权。拥有 `sysadmin`、`db_owner` 或修改触发器权限的维护账号属于可信管理边界。

视图金额口径：商品销售与销售明细按折扣前明细金额统计，样例合计 44.50；每日销售按订单应付金额统计，优惠 1.50 后合计 43.00。样例日期相对于导入日生成，报告截图日期代表截图当天的数据。

## 普通角色的订单操作入口

已有数据库应用本次补充时，依次重跑 `02_business_procedures.sql`、`role.sql` 和 `04_verify.sql`，不需要删除数据或重新建库。

| 过程 | 授权角色 | 功能 |
| --- | --- | --- |
| QueryPurchaseOrders | CampusPurchaser | 不传参数查询采购订单列表；传 PurchaseID 查询指定订单，草稿显示明细预估金额 DraftAmount |
| QuerySaleOrders | CampusCashier | 不传参数查询销售订单列表；传 SaleID 查询指定订单，只有 COMPLETED 显示有效 PayableAmount |
| UpdateSaleDraft | CampusCashier | 明确传入 SaleID、PaymentMethod、DiscountAmount 和可选 Remark，覆盖草稿支付方式、优惠和备注 |
| CancelPurchase | CampusPurchaser | 仅取消草稿采购单，保留明细，不改库存和流水 |
| CancelSale | CampusCashier | 仅取消草稿销售单，保留明细及未结算优惠，不改库存和流水 |

这 5 个过程加原有 ConfirmPurchase、CompleteSale，共 7 个。普通角色仍无订单头直接 UPDATE 权限；取消单不能再次确认、结算或修改明细。查询按业务角色开放，不代表只允许访问本人订单，员工与数据库用户映射及行级权限仍不在本阶段范围内。

查询示例（只读）：

```sql
EXEC dbo.QueryPurchaseOrders;
EXEC dbo.QuerySaleOrders;
```

草稿操作示例（应将参数中的订单 ID 换成实际草稿 ID；以下是互斥的结算或取消分支）：

```sql
-- EXEC dbo.UpdateSaleDraft @SaleID=实际草稿ID, @PaymentMethod='WECHAT', @DiscountAmount=1.00, @Remark=N'补填支付方式';
-- EXEC dbo.CompleteSale @SaleID=实际草稿ID;
-- 或 EXEC dbo.CancelSale @SaleID=实际草稿ID;
-- EXEC dbo.CancelPurchase @PurchaseID=实际采购草稿ID;
```

价格仍允许保留实际成交价；本次没有增加统一售价校验。草稿和取消单的数据库计算应付金额可能为负，查询过程将其展示为空，不能作为有效收款金额。

## 建库与事务安全补充

建库脚本使用当前连接的临时许可表跨 `GO` 检查。库已存在时不产生许可；每个后续部署批次先检查许可，前一批次失败则撤销许可。即使普通查询窗口继续发送后续批次，也不能继续创建对象。不需要启用 SSMS 的 SQLCMD 模式；请在同一查询连接中完整执行脚本。创建触发器和视图的语句使用动态批次，是为了同时满足“先检查许可”和“创建对象必须是批次首语句”的要求。中途部署失败可能留下新建的部分数据库，需先检查失败原因，不承诺整个建库操作自动回滚。

5 个写入过程无外层事务时自行开始、提交或回滚；有外层事务时建立保存点，成功不提前提交，普通业务校验失败只撤销当前过程操作。过程使用 `XACT_ABORT OFF`，失败捕获中仍明确处理回滚。若 `XACT_STATE()=-1`，保存点不能恢复事务：独立调用自行回滚；嵌套调用保留不可提交状态并抛错，由外层调用者整体回滚。保存点不支持分布式事务，本项目只支持本地事务。

销售过程以 `HOLDLOCK` 保持商品启用状态检查所需的锁，直到所属事务结束。专项测试先锁库存，让另一连接的销售通过商品状态检查后等待库存；第三连接尝试停用商品必须超时。释放库存锁后结算成功，商品才可停用。该测试验证这个并发窗口，不代表已穷尽所有死锁或并发场景。
