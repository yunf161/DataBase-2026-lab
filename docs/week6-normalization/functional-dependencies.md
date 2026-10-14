# 函数依赖清单

记号 `X → Y` 表示 X 的取值唯一决定 Y。`全部非码属性` 包括该表除候选码以外的业务字段、
状态和时间字段。

| 关系 | 候选码与主要函数依赖 | 外键/说明 |
| --- | --- | --- |
| Category | `CategoryID → 全部非码属性`；`CategoryCode → 全部非码属性` | `ParentID → Category.CategoryID`，但 ParentID 不是本表决定因素 |
| Supplier | `SupplierID → 全部非码属性`；`SupplierCode → 全部非码属性` | 无业务外键 |
| Employee | `EmployeeID → 全部非码属性`；`EmployeeNo → 全部非码属性` | `RoleName` 受值域约束 |
| Product | `ProductID → 全部非码属性`；`SKU → 全部非码属性`；非空 `Barcode → 全部非码属性` | `CategoryID → Category.CategoryID` |
| Inventory | `ProductID → Quantity, MinQuantity, UpdatedAt` | ProductID 同时是 PK 和 FK，至多一件商品一行库存 |
| PurchaseOrder | `PurchaseID → 全部非码属性`；`PurchaseNo → 全部非码属性` | SupplierID、EmployeeID 为外键 |
| PurchaseItem | `PurchaseItemID → 全部非码属性`；`(PurchaseID, ProductID) → Quantity, UnitCost, LineAmount`；`(Quantity, UnitCost) → LineAmount` | 每张采购单的同一商品合并为一行 |
| SaleOrder | `SaleID → 全部非码属性`；`SaleNo → 全部非码属性`；`(TotalAmount, DiscountAmount) → PayableAmount` | EmployeeID 为外键 |
| SaleItem | `SaleItemID → 全部非码属性`；`(SaleID, ProductID) → Quantity, UnitPrice, LineAmount`；`(Quantity, UnitPrice) → LineAmount` | UnitPrice 是成交价，不依赖 Product 当前售价 |
| InventoryLog v0.1 | `LogID → ProductID, ChangeType, ChangeQuantity, BeforeQuantity, AfterQuantity, BusinessNo, EmployeeID, Remark, CreatedAt` | BusinessNo 无外键，只靠过程约定 |
| InventoryLog v1.0 | `LogID → ProductID, ChangeType, ChangeQuantity, BeforeQuantity, AfterQuantity, PurchaseID, SaleID, EmployeeID, Remark, CreatedAt` | PurchaseID、SaleID 分别为真实外键；来源类型由 CHECK 约束 |

## 跨关系业务依赖

- 采购单总额由该单所有 `PurchaseItem.LineAmount` 求和得到。
- 销售单总额由该单所有 `SaleItem.LineAmount` 求和得到，应付金额等于总额减优惠。
- 当前库存等于已生效库存流水的累计结果；为了查询效率，系统保存当前快照。
- 订单状态从 `DRAFT` 进入 `RECEIVED` 或 `COMPLETED` 时，必须与总额、库存和流水在同一事务更新。

这些跨关系依赖无法仅靠单表主键表达，所以由 `ConfirmPurchase`、`CompleteSale`、状态保护
触发器和最小权限共同维护。

