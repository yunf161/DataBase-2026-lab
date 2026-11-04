# v1.0 目标结构与重构证明

## 属性、码与联系

十张核心业务表保留，九张字段不变，其字段与码见[第二周关系模式](../week2-schema.md)。
改造后的关系为：

```text
InventoryLog(LogID PK, ProductID FK, ChangeType, ChangeQuantity,
             BeforeQuantity, AfterQuantity, PurchaseID NULL FK,
             SaleID NULL FK, EmployeeID NULL FK, Remark, CreatedAt)
```

LogID 是唯一候选码；原文本 BusinessNo 及其索引删除。
PurchaseID 引用 PurchaseOrder.PurchaseID，SaleID 引用 SaleOrder.SaleID，
ProductID 和 EmployeeID 的原外键保留。字段类型与其余索引见[数据字典](data-dictionary.md)。

| ChangeType | PurchaseID | SaleID | ChangeQuantity |
| --- | --- | --- | --- |
| PURCHASE_IN / PURCHASE_RETURN | 必填 | 必须空 | 入库正、退货出库负 |
| SALE_OUT / SALE_RETURN | 必须空 | 必填 | 出库负、退货入库正 |
| STOCKTAKE_IN / STOCKTAKE_OUT | 必须空 | 必须空 | 入库正、出库负 |

退货/盘点是预留类型，没有实现相应业务过程，不能视为已完成功能。
v_inventory_log_detail 用 LEFT JOIN 联系订单，COALESCE 输出兼容 BusinessNo；
空来源盘点行保留，不能用内连接过滤它们。完整流水视图仅管理员读取。

## ER 延续与基数

R01–R12 的左右方向、基数及条件沿用[第五周业务规则](../week5-er/business-rules.md)。
第五周拟议会员 R13 因超出业务边界取消，新增真实订单来源外键：

| 编号；左端 → 右端 | 左→右 a | 右→左 b | 参与条件 |
| --- | --- | --- | --- |
| R14 PurchaseOrder → InventoryLog | 0..N | 0..1 | 采购类流水必须引用一张采购单；其他类型不得引用 |
| R15 SaleOrder → InventoryLog | 0..N | 0..1 | 销售类流水必须引用一张销售单；其他类型不得引用 |

图中央标签 a / b 对应上表顺序，不能当成实体旁的端点标注。
R10 的业务目标仍是商品→库存 1..1，实际 PK+FK 强制 0..1；
商品插入触发器补库存，业务角色无删除权限，过程缺行时拒绝。
全状态订单可有零明细，只有成功确认/结算才要求至少一条。

## 设计层面的可逆重构

此改造是来源表达替换，不是将库存流水拆成多张业务表。
前提是旧采购类 BusinessNo 唯一匹配采购号，旧销售类唯一匹配销售号，盘点来源为空。
非空唯一 PurchaseNo/SaleNo 分别与各自订单 ID 一一对应；
由 ChangeType 确定哪种订单表，旧单号可唯一转成对应 ID，不会复制流水。
相反，两个 FK 加来源 CHECK 保证迁移后的引用有效且互斥，
LEFT JOIN 到唯一订单 ID 能重构旧单号，盘点仍重构为空。
其他字段直接保留，所以在这些前提下业务表示可逆、信息无损。
匹配不成立时拒绝迁移，不推测来源或丢弃行。

终态订单编号由状态触发器保护，不允许普通流程改号。
视图展示的是当前被引用订单的编号；管理员若绕过保护改号，
它不会保留旧文本快照。因此这里的历史等价以订单编号保护规则为前提，
不能把外键视图当成独立的历史编号快照。

## 依赖与约束保持

- PurchaseNo、SaleNo 与对应 ID 的唯一决定关系仍在订单表内；
- LogID → 全体库存流水属性保持；
- (BeforeQuantity, ChangeQuantity) → AfterQuantity 仍由原数量 CHECK 维护；
- 跨表引用存在性由两个 FK 强制；
- ChangeType、来源非空/互斥及数量正负方向是业务约束，分别由新增 CHECK 保持；
- 两个过程改为写订单 ID，状态保护同时升级，普通角色权限继续有效。

外键和 CHECK 改善业务完整性，并不消除审计数量依赖的 3NF 例外。
教学宽表分解的无损连接与依赖保持证明另见[范式分析](normalization-analysis.md)。

## 实际回归证据的作用

regression.sql 以业务编号和 SKU 比较订单头/明细，以 LogID 及完整展示字段双向 EXCEPT 比较流水，
同时核对销售统计、库存、金额和权限。[实际结果](regression-results.md)中的样例差异为 0，
用于发现迁移实现错误；样例成功不能替代以上依赖与唯一性前提的论证。

