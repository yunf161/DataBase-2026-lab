# AI 使用记录：校园小卖部进销存数据库

**项目名称：**校园小卖部进销存数据库  
**记录范围：**2026 年 9 月至 2026 年 10 月  
**使用工具：**Codex 对话式编程助手  
**项目环境：**SQL Server Express、SSMS、T-SQL、PowerShell、Git

## 一、使用目的与输入资料

本项目用 AI 辅助理解数据库课程要求、设计并实现可复现的 SQL Server 数据库、编写课堂演示脚本、检查运行结果以及整理说明文档。主要输入资料是仓库中的 [`要求.docx`](../要求.docx)、[`要求.md`](../要求.md)、原有 SQL 草稿，以及使用者在对话中提供的第 1–4 周课程任务。

原要求文档以 MySQL 为例。使用者明确选择 **SQL Server Express**，并确认继续按该方案建立数据库。因此项目脚本采用 T-SQL，不能直接在 MySQL 中执行。

使用者提出过的关键指令包括“查看要求文档，建立 sql 数据库等等”“SQL Server Express（推荐）”“按推荐方案继续”“好的，做完 push”，以及后续要求核对四周任务、完善 README 和讲解复现流程。AI 根据这些指令推进工作；数据库选型与交付方向由使用者决定。

## 二、AI 辅助内容与可核查产物

| 阶段 | AI 辅助工作 | 产物或依据 |
| --- | --- | --- |
| 基础数据库实现 | 对照要求整理 10 张核心表，编写建库、采购确认、销售结算、样例数据和隔离验证脚本；协助将代码提交到仓库。 | 提交 `9463f03`；[`sql/01_create_campus_store_database.sql`](../sql/01_create_campus_store_database.sql)、[`sql/02_business_procedures.sql`](../sql/02_business_procedures.sql)、[`sql/03_sample_data.sql`](../sql/03_sample_data.sql) |
| 后续仓库更新的核对 | 拉取并检查仓库中关于分类循环、库存数量和更新时间保护的更新，在该版本基础上继续完善课程交付。此条只记录 AI 的核对与集成工作，不把该更新的代码作者归于 AI。 | 提交 `33c19f6`；[`sql/04_verify.sql`](../sql/04_verify.sql)、[`sql/05_business_verify.sql`](../sql/05_business_verify.sql) |
| 第 1–4 周课程交付 | 整理业务边界、角色职责、关系模式与样例元组；补充 CRUD、多表查询、统计视图、约束检查、角色权限和越权演示；完善复现说明并推送。 | 提交 `3ac5458`；[`docs/week1-business.md`](week1-business.md)、[`docs/week2-schema.md`](week2-schema.md)、[`sql/crud.sql`](../sql/crud.sql)、[`sql/query.sql`](../sql/query.sql)、[`sql/view.sql`](../sql/view.sql)、[`sql/constraint.sql`](../sql/constraint.sql)、[`sql/role.sql`](../sql/role.sql)、[`README.md`](../README.md) |
| 使用指导与复核 | 解释如何在 SSMS 查看表、打开脚本、执行查询和查看结果；再次拉取仓库并对照课程任务检查提交内容。 | 本项目对话记录；[`tests/Verify-CampusStore.ps1`](../tests/Verify-CampusStore.ps1) |

## 三、验证方式与实际结果

AI 使用 `tests/Verify-CampusStore.ps1` 在随机命名的一次性数据库中，从空库依次运行建表、业务过程、样例数据和课堂脚本；测试结束后删除临时数据库，不依靠“代码看起来正确”来判断结果。2026 年 10 月 5 日的完整隔离验证退出码为 **0**，包括采购与销售的事务回滚、统计视图、两次 CRUD、非法售价和外键数据被拒绝、角色越权修改库存被拒绝。

在本机 SQL Server Express 的正式 `CampusStoreDB` 中，核对到 10 张核心表、5 个视图、12 个启用触发器和 4 个数据库角色。演示数据中可乐库存为 27、纸巾库存为 6；采购金额为 84.00，销售应付金额为 10.00。这些是课程演示数据，不是真实商店经营数据。

## 四、人工决策、局限与提交前检查

使用者提供课程要求，选择 SQL Server Express，确认实施方向，并在 SSMS 中查看数据库和询问复现方法。AI 负责辅助生成、解释和检查；最终提交者仍需理解脚本含义、按 [`README.md`](../README.md) 亲自演示，并核对教师对数据库类型和文件格式的具体要求。

复核时发现一处尚未修正的流程差异：[`sql/role.sql`](../sql/role.sql) 给收银员销售单头的 `INSERT` 权限，但没有后续 `UPDATE` 权限。因此若严格按照第 1 周文档所写“建立草稿、添加明细后再选择支付方式和优惠”操作，收银员角色不能补填这些字段。当前演示数据是在插入销售草稿时直接填写支付信息；提交前应修正权限与保护规则，或明确调整演示流程。角色演示已验证越权修改库存会失败，但尚未以收银员身份完成整笔销售的端到端测试。

本记录只描述上述对话和仓库中可核查的使用情况，不代替课程报告，也不声称 AI 输出无需人工审查。
