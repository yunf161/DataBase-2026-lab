# 函数依赖清单

`X → Y` 表示同一关系中 X 的取值唯一决定 Y；依赖来自业务规则和约束，不能仅凭样例值唯一推断。
下文“全体属性”包括代理主码、其他候选码、业务字段和时间字段；候选码必须决定其他候选码字段。
字段全集及类型见[第二周关系模式](../week2-schema.md)与[v1.0 数据字典](data-dictionary.md)。

| 关系 | 候选码 | 主要函数依赖 | 外键与条件说明 |
| --- | --- | --- | --- |
| Category | CategoryID；CategoryCode | 两个候选码分别 → 全体属性 | ParentID 引用本表 CategoryID，这是参照关系，不是“ParentID 决定本行属性” |
| Supplier | SupplierID；SupplierCode | 两个候选码分别 → 全体属性 | 联系电话、供应商名称无唯一业务规则，不能作为码 |
| Employee | EmployeeID；EmployeeNo | 两个候选码分别 → 全体属性 | RoleName 为职责值域，多名员工可同职责 |
| Product | ProductID；SKU | 两个候选码分别 → 全体属性 | CategoryID 引用 Category；Barcode 可空，仅非空子集唯一，不是全表候选码 |
| Inventory | ProductID | ProductID → Quantity, MinQuantity, UpdatedAt | ProductID 同时为 PK 与 FK |
| PurchaseOrder | PurchaseID；PurchaseNo | 两个候选码分别 → 全体属性 | SupplierID、EmployeeID 引用独立关系 |
| PurchaseItem | PurchaseItemID；(PurchaseID, ProductID) | 两个候选码分别 → 全体属性；(Quantity, UnitCost) → LineAmount | 复合候选码也决定 PurchaseItemID；订单内同商品合并为一行 |
| SaleOrder | SaleID；SaleNo | 两个候选码分别 → 全体属性；(TotalAmount, DiscountAmount) → PayableAmount | EmployeeID 为 FK |
| SaleItem | SaleItemID；(SaleID, ProductID) | 两个候选码分别 → 全体属性；(Quantity, UnitPrice) → LineAmount | 复合候选码也决定 SaleItemID；UnitPrice 为历史成交价 |
| InventoryLog v0.1 | LogID | LogID → 全体属性；(BeforeQuantity, ChangeQuantity) → AfterQuantity | BusinessNo 是可空文本，无订单 FK |
| InventoryLog v1.0 | LogID | LogID → 全体属性；(BeforeQuantity, ChangeQuantity) → AfterQuantity | PurchaseID、SaleID 分别为订单 FK，来源互斥由 CHECK 保证 |

在 Barcode 非空的商品子集中，可写条件依赖 `Barcode → 全体属性`，必须注明其适用范围。
`ProductID → SaleItem.UnitPrice` 不是有效依赖：同一商品可在不同订单以不同价格成交；
例如 P0001 当前售价 3.50 不决定过去每一笔成交价，商品也没有统一历史采购价。

## 表内派生依赖

计算列和数量等式仍属于函数依赖分析：

- PurchaseItem：`(Quantity, UnitCost) → LineAmount`；
- SaleItem：`(Quantity, UnitPrice) → LineAmount`；
- SaleOrder：`(TotalAmount, DiscountAmount) → PayableAmount`；
- InventoryLog：`(BeforeQuantity, ChangeQuantity) → AfterQuantity`。

上述决定因素不是超码，被决定属性不是主属性。因此包含这些字段的完整物理关系严格判断不满足 3NF。
计算列或 CHECK 可控制一致性，却不会改变范式结论。逐表取舍见[范式与异常分析](normalization-analysis.md)。

## 跨关系维护规则

采购、销售头的 TotalAmount 分别来自全部明细 LineAmount 求和；Inventory.Quantity 是已生效库存变化的当前快照。
这些跨关系维护规则不能直接当作单表普通函数依赖，也不能仅因保存总额就判定采购头违反 3NF。
确认/结算在同一事务更新订单、库存和流水；普通业务角色通过过程维护，管理员的对象维护权限仍需按运维规则使用。

