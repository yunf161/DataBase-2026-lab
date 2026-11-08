# 数据字典：app 架构（第七至九周增量）

最终应用层实体、联系基数和参与约束见[应用层 ER 补充图](app-er.md)。

十张核心业务表的字段见[第二周关系模式](../week2-schema.md)和[v1.0 数据字典](../week6-normalization/data-dictionary.md)，
应用增量没有修改它们。`app` 架构由 [sql/week7/application.sql](../../code/sql/week7/application.sql) 创建，
第九周增量 [sql/week9/application_v2.sql](../../code/sql/week9/application_v2.sql) 只在 `app.SaleOwner` 上增加 `SubmittedAt` 并重建视图和过程。
这两份脚本只能在名称为 `CampusStoreDB_W7_*` 的库上运行。

## app.AppUser

应用账号，与员工表分开：员工是经营职责，账号是登录身份。顾客没有员工记录。

| 字段 | 类型 | 空值 | 键/约束 | 含义 |
| --- | --- | --- | --- | --- |
| UserID | bigint identity | 否 | PK | 账号编号，不等同于 EmployeeID |
| Username | varchar(40) | 否 | UNIQUE | 登录用户名 |
| PasswordHash | varchar(255) | 否 |  | Werkzeug 带盐的 scrypt 哈希，不保存明文 |
| DisplayName | nvarchar(50) | 否 |  | 页面显示名称 |
| RoleName | varchar(20) | 否 | `CK_AppUser_Role` | `ADMIN`、`STAFF` 或 `CUSTOMER` |
| EmployeeID | bigint | 是 | FK → dbo.Employee；非空时唯一（过滤唯一索引 `UX_AppUser_Employee`） | 员工账号必填，顾客必须为空（由 `CK_AppUser_Role` 保证） |
| Status | bit | 否 | 默认 1 | 1 启用、0 停用；每次请求都会重新核对 |
| CreatedAt | datetime2(0) | 否 | 默认 `SYSDATETIME()` | 创建时间 |

`app.AppUser` 只有 `WebAuth` 可以 `SELECT`；`WebAdmin`、`WebStaff`、`WebCustomer` 被显式 `DENY SELECT`。

## app.SaleOwner

订单归属，一张订单至多一个归属；第七周之前的旧订单没有归属行，不猜测归属。

| 字段 | 类型 | 空值 | 键/约束 | 含义 |
| --- | --- | --- | --- | --- |
| SaleID | bigint | 否 | PK，FK → dbo.SaleOrder | 订单编号 |
| UserID | bigint | 否 | FK → app.AppUser；索引 `IX_SaleOwner_User(UserID, SaleID)` | 创建订单的账号，由后端从会话取得 |
| CreatedAt | datetime2(0) | 否 | 默认 `SYSDATETIME()` | 创建时间 |
| SubmittedAt | datetime2(0) | 是 | 第九周新增，无默认值 | 顾客提交订单的时间。空：仍在购物车（或员工自己的草稿）；非空：已提交、待店员受理。只由 `app.SubmitSale` 写入，提交后顾客不能再修改明细 |

`SubmittedAt` 不是订单状态：`dbo.SaleOrder.Status` 仍只有 `DRAFT`、`COMPLETED`、`CANCELLED`。升级脚本用 `IF COL_LENGTH(...) IS NULL ALTER TABLE ... ADD`，可重复执行；已有订单的该列为 NULL。

## 视图

| 视图 | 使用者 | 说明 |
| --- | --- | --- |
| app.v_Catalog | 三角色 | 商品与库存数量；顾客只看到商品和分类都启用的商品 |
| app.v_Categories | 三角色 | 启用分类 |
| app.v_CategoryScope | 三角色 | 分类与其自身及全部子孙分类的对应关系，用于按分类查询商品（第九周） |
| app.v_Cashiers | 三角色 | 启用且职责为收银或管理员的员工编号，供顾客订单指派 |
| app.v_Inventory | 管理员、店员 | 库存数量、预警下限和 `stock_status` |
| app.v_OrderAccess | 三角色 | 订单可见性：管理员/店员看全部，其他身份按会话中的 `WebUserID` 过滤；已完成订单才返回 `payable_amount`；含 `submitted_at` 和 `is_customer_order`（第九周） |
| app.v_OrderItems | 三角色 | 订单明细，通过 `v_OrderAccess` 再次过滤 |
| app.v_InventoryLog | 管理员 | 库存流水，来自 `dbo.v_inventory_log_detail`（第九周） |
| app.v_Suppliers | 管理员 | 启用的供应商（第八周） |
| app.v_PurchaseOrders | 管理员 | 采购单及明细合计（第八周） |
| app.v_PurchaseItems | 管理员 | 采购明细（第八周） |

## 过程

| 过程 | 角色 | 说明 |
| --- | --- | --- |
| app.CreateSaleDraft | 三角色 | 新建草稿并写归属 |
| app.WriteSaleItem / DeleteSaleItem / UpdateSaleDraft | 三角色 | 草稿明细和支付信息；提交后顾客不能再改（错误 51811） |
| app.CancelSaleDraft | 三角色 | 取消草稿 |
| app.DeleteUnusedProduct | 管理员 | 安全删除无库存、无引用的商品 |
| app.SubmitSale | 顾客 | 提交订单（第九周） |
| app.SettleSale | 管理员、店员 | 结算，调用 `dbo.CompleteSale`（第九周） |
| app.AdjustInventory | 管理员 | 盘点调整库存并写流水（第九周） |
| app.CreatePurchaseDraft / WritePurchaseItem / DeletePurchaseItem / CancelPurchaseDraft | 管理员 | 采购草稿和明细维护（第八周） |
| app.ConfirmPurchase | 管理员 | 确认入库，调用 `dbo.ConfirmPurchase`（第八周） |

## 数据库角色与用户

`WebAuthRole`、`WebAdminRole`、`WebStaffRole`、`WebCustomerRole` 分别包含同名去掉 `Role` 的无登录用户（`CREATE USER ... WITHOUT LOGIN`）。
四个角色都不是 `db_owner`，也没有 `dbo.Inventory.Quantity` 的 `UPDATE` 权限。
