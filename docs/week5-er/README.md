# 第五周：v0.1 ER 模型

本目录分析当前 SQL Server 数据库的 **10 张已实现表**。实体名、属性名与 [第二周数据字典](../week2-schema.md) 和 [实际建库脚本](../../sql/01_create_campus_store_database.sql) 一致。图中的 `Member` 是为了分析“会员或散客购买”而提出的**第六周候选设计**，不属于 v0.1，当前库也没有 `SaleOrder.MemberID`。第五周只交分析成果；不要用图去替代建库脚本或直接改正式库。

## 提交文件与看图方法

| 文件 | 用途 |
| --- | --- |
| [week5-er.drawio](week5-er.drawio) | 可在 diagrams.net / draw.io 打开并继续编辑的源文件 |
| [week5-er.svg](week5-er.svg) | 可放大查看或插入报告的清晰矢量图 |
| [week5-er.png](week5-er.png) | 便于预览和粘贴到报告的位图导出 |
| [business-rules.md](business-rules.md) | 每条联系两端的最小/最大基数、适用条件、外码和实现情况 |
| [v0.1-issues.md](v0.1-issues.md) | 问题证据、影响、保留理由及第六周迁移方向 |
| [verification.sql](verification.sql)、[verification.md](verification.md) | 只读 SQL 与预期结果、图和数据库的对应说明 |

图统一使用 **最小..最大基数**：某实体旁的 `0..N` 表示，对于另一端的一条记录，此端可以关联零到多条。`1..1` 表示必须且只能有一条。黑色实线表示 v0.1 存在的外键；蓝色虚线表示拟议的会员联系。框内 `PK` 是主码，`AK` 是非空候选码，`FK` 是外码，`UQ` 是可空列上的唯一限制。`PurchaseItem`、`SaleItem` 用浅色框表示关联实体。具体“至少一条明细”只对确认/结算后的订单成立，不能把草稿订单标成始终 `1..N`；图中统一按 v0.1 全状态的 `0..N` 标记，条件规则见 [业务规则表](business-rules.md)。

## 从表识别实体、属性与一行记录的含义

各对象均需要独立保存：商品主数据可被多张订单重复引用，库存是商品的可变现量，订单头与明细分别保存整单状态和逐商品交易事实，流水保存历史变化。它们合并成一个大表会重复商品资料，也难以正确记录多商品订单。下表列主要业务属性；`CreatedAt`、`UpdatedAt` 等审计属性仍以[数据字典](../week2-schema.md)为准。

| 表 / 实体 | 一行代表什么、为什么独立保存 | 主要属性 | 主码 PK | 候选码 AK、唯一限制 UQ | 外码 FK |
| --- | --- | --- | --- | --- | --- |
| `Category` 分类 | 一种可供多件商品复用的分类 | `CategoryCode`, `CategoryName`, `ParentID`, `Status` | `CategoryID` | `CategoryCode` AK | `ParentID → Category`，可空 |
| `Supplier` 供应商 | 一个供货对象，可关联多次采购 | `SupplierCode`, `SupplierName`, `ContactName`, `Phone` | `SupplierID` | `SupplierCode` AK | 无 |
| `Employee` 员工 | 一位经办人，供采购、销售和流水追溯 | `EmployeeNo`, `EmployeeName`, `RoleName`, `Status` | `EmployeeID` | `EmployeeNo` AK | 无 |
| `Product` 商品 | 一种可销售的商品，不是某次交易行 | `SKU`, `Barcode`, `ProductName`, `CategoryID`, `Unit`, `SalePrice` | `ProductID` | `SKU` AK；`Barcode` 非空时 UQ | `CategoryID → Category`，非空 |
| `Inventory` 当前库存 | 某商品当前总量及预警下限，随交易变化 | `ProductID`, `Quantity`, `MinQuantity` | `ProductID`，**同时是 FK** | 无其他 AK | `ProductID → Product`，非空 |
| `PurchaseOrder` 采购单头 | 一次采购业务的供应商、经办人和状态 | `PurchaseNo`, `SupplierID`, `EmployeeID`, `Status`, `TotalAmount` | `PurchaseID` | `PurchaseNo` AK | `SupplierID → Supplier`、`EmployeeID → Employee`，均非空 |
| `PurchaseItem` 采购明细 | 某采购单中的一个商品行，保存当次数量和进价 | `PurchaseID`, `ProductID`, `Quantity`, `UnitCost`, `LineAmount` | `PurchaseItemID` | **复合 AK** `(PurchaseID, ProductID)` | 两列分别指向 `PurchaseOrder`、`Product`，均非空 |
| `SaleOrder` 销售单头 | 一次结账业务的经办人、金额、支付方式和状态 | `SaleNo`, `EmployeeID`, `Status`, `DiscountAmount`, `PaymentMethod` | `SaleID` | `SaleNo` AK | `EmployeeID → Employee`，非空 |
| `SaleItem` 销售明细 | 某销售单中的一个商品行，保存成交数量和当时单价 | `SaleID`, `ProductID`, `Quantity`, `UnitPrice`, `LineAmount` | `SaleItemID` | **复合 AK** `(SaleID, ProductID)` | 两列分别指向 `SaleOrder`、`Product`，均非空 |
| `InventoryLog` 库存流水 | 一次商品库存变化的前后数量与来源单号 | `ProductID`, `ChangeType`, `ChangeQuantity`, `BeforeQuantity`, `AfterQuantity`, `BusinessNo`, `EmployeeID` | `LogID` | 无 | `ProductID → Product` 非空；`EmployeeID → Employee` 可空 |
| `Member` 会员（**拟议**） | 若第六周决定管理会员，才需独立保存一个会员身份并供多笔销售复用 | 拟议 `MemberID`, `MemberNo`, `MemberName`, `Phone` | 拟议 `MemberID` | 拟议 `MemberNo` AK；电话可空且不作为候选码 | 拟议在 `SaleOrder` 增加可空 `MemberID` FK |

**主码与复合码的区别：**`PurchaseItemID` 和 `SaleItemID` 是现有主码；两张明细表的 `(订单 ID, ProductID)` 是**复合候选码**，不是复合主码。这个唯一约束目前禁止同一商品在一单中重复出现多个明细行。若业务允许按批次、活动价或退换记录分多行，第六周需先确认规则，再考虑移除该唯一约束并保留明细 ID 作为主码。`Barcode` 虽然非空值唯一，却可为空，不能当作覆盖所有商品的候选码。

## 业务情境与图的对应

**多商品订单。** 现有 `PO-DEMO-001` 是一张 `PurchaseOrder`，对应两条 `PurchaseItem`：可乐 `P0001` 30 瓶、纸巾 `P0002` 6 包。两条明细各引用一个 `Product`，因此 `PurchaseOrder` 与 `Product` 的 M:N 联系通过 `PurchaseItem` 表达。销售的 M:N 同理由 `SaleItem` 表达。每张单可有不同商品，但现有唯一键限定同一商品每单最多一行。

**会员或散客。** 当前销售单没有会员字段，`SO-DEMO-001` 只能说明一笔销售，**无法从数据库判断是会员还是散客**。图中虚线方案让销售单的 `MemberID` 可空：空值表示散客，非空则关联一个已存在会员；一个会员可关联零到多笔销售。是否真的纳入会员、需要哪些属性，留待第六周确认并迁移。

**库存查询。** `Product` 与 `Inventory` 用相同的 `ProductID` 相连。样例采购把可乐从 0 加到 30，销售 3 瓶后为 27；`InventoryLog` 分别记录变化。可从 [verification.sql](verification.sql) 看 `Product`、`Inventory` 与流水的实际连接结果。业务上希望每个商品恰有一条库存记录；现有插入触发器会创建它，但外键本身只保证“库存行一定有商品”，不能阻止之后删除库存行。这一差别记入[问题清单](v0.1-issues.md)。

报告可引用本页的实体映射和三个情境、[业务规则](business-rules.md)的基数表，以及[问题清单](v0.1-issues.md)的保留/调整决策。验证时先看 SVG，再在 SSMS 对 `CampusStoreDB` 执行只读脚本；不需要重建正式库。
