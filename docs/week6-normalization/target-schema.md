# v1.0 目标结构与重构证明

## 结构变化

10 张业务表不变，仅修改 `InventoryLog`：

```text
v0.1: InventoryLog.BusinessNo varchar(30) NULL
v1.0: InventoryLog.PurchaseID bigint NULL -> PurchaseOrder.PurchaseID
      InventoryLog.SaleID     bigint NULL -> SaleOrder.SaleID
```

来源一致性规则：

| ChangeType | PurchaseID | SaleID |
| --- | --- | --- |
| PURCHASE_IN / PURCHASE_RETURN | 必填 | 必须为空 |
| SALE_OUT / SALE_RETURN | 必须为空 | 必填 |
| STOCKTAKE_IN / STOCKTAKE_OUT | 必须为空 | 必须为空 |

`v_inventory_log_detail` 联接采购单或销售单，并通过 `COALESCE(PurchaseNo, SaleNo)` 继续输出
名为 `BusinessNo` 的展示列。应用查询不必自行判断单号来自哪张表。

ER 图不是重新建模，而是在第五周 v0.1 图上演进：R01–R12 原样保留；第五周的 R13
“拟议会员购买”因本项目不保存顾客身份而取消；新增 R14“采购单—库存流水”和 R15
“销售单—库存流水”，对应两个实际外键。

## 无损性

迁移前要求每条采购类流水的 BusinessNo 唯一匹配 `PurchaseOrder.PurchaseNo`，每条销售类
流水唯一匹配 `SaleOrder.SaleNo`。这两个订单号均有唯一约束，所以回填是从每条流水到至多
一个订单的多对一映射，不会复制流水。若有未匹配、重复匹配或盘点流水携带文本单号，迁移
在改表前直接拒绝。

迁移后，`InventoryLog JOIN PurchaseOrder/SaleOrder` 可唯一重构原 BusinessNo。回归脚本以
`LogID` 和所有业务字段做双向 `EXCEPT`，实际差异为 0，证明样例数据未丢失、未重复。

## 依赖保持

- PurchaseNo、SaleNo 的唯一性仍由原订单表候选码保持；
- 流水到订单的存在性由两个外键保持；
- ChangeType 与订单来源的组合规则由 `CK_InventoryLog_Source` 保持；
- ChangeType 与 ChangeQuantity 的正负方向由 `CK_InventoryLog_Direction` 保持；
- 数量等式仍由原 `CK_InventoryLog_Quantity` 保持；
- 采购/销售过程改为直接写相应订单 ID，不再依赖文本约定。

原“BusinessNo 能显示”的查询语义转移到视图，而不是继续冗余保存文本。依赖因此可以由
SQL Server 直接验证，写入异常比 v0.1 更早、更明确地被拒绝。

