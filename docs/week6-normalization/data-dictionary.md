# v1.0 数据字典

未列出的 9 张业务表字段与 [第二周关系模式](../week2-schema.md)一致。第六周只修改
`InventoryLog`，并新增一个兼容查询视图和 `week6` 验证辅助对象。

## dbo.InventoryLog

| 字段 | 类型 | 空值 | 键/约束 | 含义 |
| --- | --- | --- | --- | --- |
| LogID | bigint identity | 否 | PK | 流水代理键 |
| ProductID | bigint | 否 | FK → Product | 发生库存变化的商品 |
| ChangeType | varchar(30) | 否 | CK 类型值域 | 采购入库、销售出库、退货或盘点类型 |
| ChangeQuantity | int | 否 | 非 0 | 正数入库、负数出库 |
| BeforeQuantity | int | 否 | ≥ 0 | 变化前库存 |
| AfterQuantity | int | 否 | ≥ 0，且 `Before + Change` | 变化后库存 |
| PurchaseID | bigint | 是 | FK → PurchaseOrder | 采购类流水来源 |
| SaleID | bigint | 是 | FK → SaleOrder | 销售类流水来源 |
| EmployeeID | bigint | 是 | FK → Employee | 经办员工 |
| Remark | nvarchar(255) | 是 |  | 备注 |
| CreatedAt | datetime2(0) | 否 | 默认当前时间 | 流水时间 |

索引：`(ProductID, CreatedAt)`、过滤索引 `PurchaseID IS NOT NULL`、过滤索引
`SaleID IS NOT NULL`，以及保留的 EmployeeID 索引。`CK_InventoryLog_Source` 保证订单来源类型一致，
`CK_InventoryLog_Direction` 保证入库为正数、出库为负数。`BusinessNo` 实体列已删除。

## dbo.v_inventory_log_detail

在 InventoryLog 基础上联接 Product、Employee、PurchaseOrder、SaleOrder，额外提供 SKU、
商品名、员工编号/姓名和统一展示字段 BusinessNo。它作为查询展示入口，不保存重复单号。
完整流水同时涉及采购、销售和员工信息，迁移后仅 `CampusAdmin` 沿用查询权限；
`CampusViewer`、`CampusPurchaser`、`CampusCashier` 均被显式拒绝读取该视图。

## week6 辅助对象

`BaselineMetric`、`BaselinePurchaseOrder`、`BaselinePurchaseItem`、`BaselineSaleOrder`、`BaselineSaleItem`、`BaselineProductSales`、
`BaselineInventory`、`BaselineInventoryLog` 只用于数据库副本上的迁移对照；
`MigrationHistory` 记录迁移代码与执行时间。它们不属于小卖部业务实体，不计入 10 张业务表。

