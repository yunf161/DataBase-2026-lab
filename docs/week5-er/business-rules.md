# 业务规则与关系映射清单

本表写法为“**给定左端一行，可关联右端多少行**”和“**给定右端一行，可关联左端多少行**”。`N` 表示任意多。基数来自业务规则和全部合法状态，而不是样例行数。除最后一行的虚线方案外，关系均与 [建库脚本](../../sql/01_create_campus_store_database.sql) 的外键对应。图中的端点标记与本表一致：左端旁的数是“每个右端对应多少左端”，右端旁的数是“每个左端对应多少右端”。

| 图中编号；左端 → 右端 / 联系 | 左→右 | 右→左 | 适用条件、外码和当前实现 |
| --- | --- | --- | --- |
| R01 `Category` → 子 `Category` / 上下级 | `0..N` | `0..1` | 子类的 `ParentID` 可空 FK；空值为顶级分类。`tr_Category_PreventCycle` 拒绝自指和多级环。|
| R02 `Category` → `Product` / 归类 | `0..N` | `1..1` | `Product.CategoryID` 非空 FK；空分类合法，已存在的商品必须且只能属一个分类。|
| R03 `Supplier` → `PurchaseOrder` / 供货 | `0..N` | `1..1` | `PurchaseOrder.SupplierID` 非空 FK；一张采购单恰有一个供应商。|
| R04 `Employee` → `PurchaseOrder` / 经办采购 | `0..N` | `1..1` | `PurchaseOrder.EmployeeID` 非空 FK。FK 不检查该员工是否仍在职或 `RoleName` 是否为采购员。|
| R05 `PurchaseOrder` → `PurchaseItem` / 包含采购明细 | `0..N`（`RECEIVED` 时业务要求 `1..N`） | `1..1` | `PurchaseItem.PurchaseID` 非空 FK。`DRAFT` 可暂时无明细；`ConfirmPurchase` 在确认时以 `SUM(LineAmount) IS NULL` 拒绝空单，`tr_PurchaseItem_DraftOnly` 阻止确认后改明细。**外键自身不保证至少一条明细**。|
| R06 `Product` → `PurchaseItem` / 被采购 | `0..N` | `1..1` | `PurchaseItem.ProductID` 非空 FK；`UNIQUE(PurchaseID, ProductID)` 限定同一单同一商品至多一行。|
| R07 `Employee` → `SaleOrder` / 经办销售 | `0..N` | `1..1` | `SaleOrder.EmployeeID` 非空 FK。FK 不检查员工是否在职或有收银职责。|
| R08 `SaleOrder` → `SaleItem` / 包含销售明细 | `0..N`（`COMPLETED` 时业务要求 `1..N`） | `1..1` | `SaleItem.SaleID` 非空 FK。`DRAFT` 可无明细；`CompleteSale` 在结算时拒绝空单，`tr_SaleItem_DraftOnly` 阻止结算后改明细。|
| R09 `Product` → `SaleItem` / 被售出 | `0..N` | `1..1` | `SaleItem.ProductID` 非空 FK；`UNIQUE(SaleID, ProductID)` 限定同一单同一商品至多一行。结算过程还检查商品启用和库存足够。|
| R10 `Product` → `Inventory` / 拥有当前库存 | **业务目标 `1..1`；库内实际 `0..1`** | `1..1` | `Inventory.ProductID` 同时为 PK 与非空 FK，使库存行必有商品且每商品至多一行；`tr_Product_CreateInventory` 新增商品时补零库存。现有约束不能禁止之后删除库存行，确认/结算过程会在缺行时失败。|
| R11 `Product` → `InventoryLog` / 发生库存变化 | `0..N` | `1..1` | `InventoryLog.ProductID` 非空 FK；从未交易的商品可以没有流水。数量前后关系由 `CK_InventoryLog_Quantity` 检查，业务过程负责与库存同步。|
| R12 `Employee` → `InventoryLog` / 执行变化 | `0..N` | `0..1` | `InventoryLog.EmployeeID` 可空 FK；人工或系统来源可为空。非空时必须是已存在员工。|
| R13 `Member` → `SaleOrder` / 会员购买（**第六周拟议**） | `0..N` | `0..1` | **v0.1 尚无此关系。** 若确认会员需求，拟新增 `Member` 和 `SaleOrder.MemberID NULL` FK；`NULL` 表示散客。不可把现有订单自动认定为散客，也不可从现有字段反推出会员。|

采购订单与商品、销售订单与商品在概念上都为 **M:N**：一单可含多种商品，一商品可出现于多单。通过 `PurchaseItem` / `SaleItem` 关联实体拆成两组 1:N，并把数量、单价放在关联实体中。商品与库存是业务上的 1:1，实际强制程度见上表。可选会员联系是 1:N，不是“每人只能买一次”。

`InventoryLog.BusinessNo` 是普通字符串，不是指向 `PurchaseOrder.PurchaseNo` 或 `SaleOrder.SaleNo` 的外键，因此图中不画订单头到流水的外键线。现有业务过程写入单号，但数据库未强制该单号能唯一对应采购或销售；区分来源还需看 `ChangeType`。这点属于 [v0.1 问题](v0.1-issues.md)。
