# 迁移说明与执行记录

## 适用初始状态

`migration.sql` 只适用于名称为 `CampusStoreDB_W6_*` 的第一阶段 v0.1 副本：`InventoryLog` 存在 `BusinessNo`，尚不存在
`PurchaseID`、`SaleID`，且已先运行 `baseline.sql`。脚本故意不是可重复迁移；重复运行会
明确报错，防止误操作。三个脚本不再写死 `USE CampusStoreDB`，而是校验当前数据库名称；
迁移前必须有可恢复的副本，禁止直接拿唯一正式库试验。

## 执行步骤

1. 检查旧列、新列和基线表；
2. 验证采购/销售流水的文本单号能且只能匹配一张正确类型订单；
3. 在事务中增加 PurchaseID、SaleID 并按 ChangeType 回填；
4. 再次检查是否有未解析或来源冲突行；
5. 增加两个外键、来源 CHECK、变化方向 CHECK 和过滤索引；
6. 将 ConfirmPurchase、CompleteSale 的流水写入改为订单 ID，并限制采购/收银员工职责；
7. 删除旧 BusinessNo 索引和列；
8. 创建 `v_inventory_log_detail`，恢复统一业务单号显示；
9. 保持最小权限：库存流水明细视图仅供管理员查询，并显式拒绝浏览、采购、收银角色读取；
10. 写入 MigrationHistory 并提交。任一步异常时整体回滚。

## SSMS 执行顺序

在数据库副本中依次打开并按 F5：

1. `sql/week6/baseline.sql`
2. `sql/week6/migration.sql`
3. `sql/week6/regression.sql`

建议截图：基线指标与 11 条样例流水、迁移成功消息、21项回归结果全部“通过”、对象资源管理器中
InventoryLog 的新外键，以及 `SELECT * FROM dbo.v_inventory_log_detail ORDER BY LogID`。

迁移完成后不得再次执行 v0.1 的 `02_business_procedures.sql`，否则它会尝试恢复对已删除
BusinessNo 列的写入。要重新演示时，应重新复制 v0.1 数据库，再按本页顺序运行。

## 已验证样例基线（2026-10-14）

| 指标 | 值 |
| --- | ---: |
| 分类 / 商品 / 员工 / 供应商 | 5 / 6 / 3 / 2 |
| 采购单 / 采购明细 | 3 / 6 |
| 销售单 / 销售明细 | 3 / 5 |
| 库存行 / 流水行 | 6 / 11 |
| 已收货采购总额 | 222.00 |
| 已完成销售原价总额 | 44.50 |

隔离验证使用随机数据库 `CampusStoreDB_W6_*`，结束后已成功删除。回归覆盖双向数据差异、逐表行数、逐订单金额、
商品销售统计、当前库存、流水备注、新外键、两类 CHECK、员工职责、合法采购销售、收银员直接改库存、三类普通角色越权读取被拒绝及管理员读取成功
被拒绝。具体结果见 [回归结果](regression-results.md)。

