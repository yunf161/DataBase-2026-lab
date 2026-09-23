# Campus Store SQL Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 SQL Server Express 建立可演示的校园小卖部进销存数据库。

**Architecture:** 用四个顺序执行的 T-SQL 文件分别处理结构、事务过程、演示数据和验证；订单确认过程是库存变化的唯一业务入口。保留课程项目所需的 10 张表，避免扩展会员与前端。

**Tech Stack:** SQL Server Express 17, T-SQL, sqlcmd, PowerShell

---

### Task 1: 需求映射与可失败验证

**Files:** `sql/04_verify.sql`, `sql/05_business_verify.sql`, `要求.md`, `要求.docx`

- [x] 写结构验证 SQL：查询 10 张表、3 个视图和 2 个存储过程，断言不存在时 `THROW`。
- [x] 对未建立的 `CampusStoreDB` 运行验证，确认因缺少目标数据库失败。

### Task 2: 数据结构

**Files:** `sql/01_create_campus_store_database.sql`

- [x] 建立 `CampusStoreDB`、10 张表、主外键、唯一约束、金额和数量检查约束、生成列与常用索引。
- [x] 建立库存预警、销售明细和每日销售视图。
- [x] 在空数据库中执行结构脚本，重跑结构存在断言。

### Task 3: 采购入库

**Files:** `sql/02_business_procedures.sql`, `sql/05_business_verify.sql`

- [x] 先加失败用例：草稿采购入库后金额、库存和流水一致；重复确认报错。
- [x] 用 `TRY/CATCH`、`XACT_ABORT` 与事务实现 `ConfirmPurchase`，仅允许 `DRAFT`，空明细报错。
- [x] 运行用例并核对事务回滚后的数据库状态。

### Task 4: 销售结算

**Files:** `sql/02_business_procedures.sql`, `sql/05_business_verify.sql`

- [x] 先加失败用例：结算扣库存并保存历史成交价；库存不足和重复结算报错且不留部分修改。
- [x] 用事务实现 `CompleteSale`，检验支付方式、优惠额与库存，计算总额并写库存流水。
- [x] 运行全部验证用例，确认无负库存和重复流水。

### Task 5: 演示与部署

**Files:** `sql/03_sample_data.sql`, `tests/Verify-CampusStore.ps1`, `README.md`

- [x] 添加最小示例分类、商品、供应商、员工和两张订单，明确仅首次执行。
- [x] 说明 `sqlcmd -S .\SQLEXPRESS -E -No -b -i ...` 的执行顺序和演示查询。
- [x] 在本机实例执行全部脚本，并用一次性数据库隔离验证业务；检查对象数量、金额、库存和流水，以及 `git diff`。
