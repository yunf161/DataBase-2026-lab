# 校园小卖部进销存数据库

本项目使用 **SQL Server Express / T-SQL**，数据库名为 `CampusStoreDB`。最初的[要求文档](要求.md)以 MySQL 为例；本项目按已选定的 SQL Server 实现，不能在 MySQL 客户端中查找或运行。完整业务链是：建商品 → 建采购草稿并确认入库 → 建销售草稿并结算 → 查询库存和流水。核心数据是 10 张表，另有 5 个视图、2 个业务存储过程和完整性触发器。

## 第 1–4 周完成情况

| 周次 | 交付内容 | 对应文件 | 现场展示 |
| --- | --- | --- | --- |
| 1：业务边界 | 小卖部场景、管理员/采购员/收银员职责、采购和销售流程，以及暂不纳入的数据 | [业务说明](docs/week1-business.md) | 解释哪些信息存入数据库、哪些暂不存入 |
| 2：关系与码 | 10 张表的字段、SQL Server 类型、主码/候选码/外码及样例元组 | [关系模式说明](docs/week2-schema.md)、[建库脚本](sql/01_create_campus_store_database.sql) | 指出 `Product.CategoryID` 等外键及 `(SaleID, ProductID)` 等组合候选码 |
| 3：DDL 与 CRUD | 从空库建表、导入样例数据，以及可重复的商品增删改查 | [建库脚本](sql/01_create_campus_store_database.sql)、[样例数据](sql/03_sample_data.sql)、[CRUD 演示](sql/crud.sql) | 连续执行两次 `crud.sql`，每次创建、查询、改价并清理测试记录 |
| 4：连接、视图、完整性、授权 | 多表查询、商品销售与供应商采购统计视图、主外键和检查约束、数据库角色及越权测试 | [query.sql](sql/query.sql)、[view.sql](sql/view.sql)、[constraint.sql](sql/constraint.sql)、[role.sql](sql/role.sql)、[role_demo.sql](sql/role_demo.sql) | 展示正确统计、非法数据被拒绝、角色直接改库存被拒绝 |

第 4 周的主键、外键和 `CHECK` 的 **DDL 在建库脚本中**；`constraint.sql` 用于列出并验证这些约束。`role.sql` 建立数据库角色并授权，`role_demo.sql` 使用临时的无登录名用户模拟角色；项目没有创建真实登录账号。`Employee.RoleName` 是员工的经营职责，与 SQL Server 的数据库角色不同。

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
& '.\tests\Verify-CampusStore.ps1' -ServerInstance $ServerInstance
```

测试包含采购/销售正常与回滚场景、统计视图核对、非法售价/外键/重复 SKU、连续两次 CRUD，以及角色越权拒绝。成功末尾会显示“隔离数据库 … 验证通过”；任何脚本失败会使测试停止并报出文件名。`05_business_verify.sql` 是隔离测试专用，**不要在正式库直接运行**。

若需要在 SSMS 展示结果，连接同一实例后逐个打开以下脚本并按 F5：

1. [query.sql](sql/query.sql)：多表连接查询采购、销售及低库存，并查看统计视图。
2. [06_demo_observation.sql](sql/06_demo_observation.sql)：查看演示订单、库存和库存流水。
3. [crud.sql](sql/crud.sql)：插入临时分类与商品、查询、改价、删除；脚本会清理自己建立的记录，可重复运行。
4. [constraint.sql](sql/constraint.sql)：列出主键、外键和检查约束，并尝试非法数据；“被拒绝”的提示是预期的成功结果。
5. [role_demo.sql](sql/role_demo.sql)：模拟只读、收银和采购用户；直接读商品表或改库存被拒绝后，脚本会删除临时用户。需使用有管理数据库角色和模拟用户权限的账号运行。

首次导入样例数据后，可核对这些具体结果：可乐库存 **27**（采购 30 瓶、售出 3 瓶），纸巾库存 **6** 并触发低库存提示；示例采购总额 **84.00**；示例销售原价合计 **10.50**、优惠后应付 **10.00**；`v_product_sales` 中可乐销量 **3**、销售额 **10.50**。这些数值对应本仓库的固定演示数据；如果正式库后续录入了新业务，统计值会随之变化。

## 业务规则和范围

新建商品会自动生成数量为 0 的库存行。采购和销售先建 `DRAFT` 订单并写入明细，再分别执行 `dbo.ConfirmPurchase` 与 `dbo.CompleteSale`。过程在事务中核对明细、金额和库存，更新订单状态并记录库存流水；库存不足等错误会回滚。已确认订单不能改回草稿，已完成订单的明细不能改动。分类不能形成循环，库存数量只能由业务过程变动，带 `UpdatedAt` 的相关表由触发器维护更新时间。销售明细保留成交价，商品日后调价不会改写历史销售金额。

本版不含会员、真实支付流水、员工密码、退货、盘点和多门店业务；相关流水类型可预留，但不能把尚未实现的退货或盘点当作已完成功能。原始 SQL Server 建表草稿保存在 [sql/00_original_campus_store_database.sql](sql/00_original_campus_store_database.sql)，实际运行请使用 `01_create_campus_store_database.sql`。
