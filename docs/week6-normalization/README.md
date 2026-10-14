# 第六周：函数依赖、范式分析与迁移

本目录对应第六周“关系规范化、反规范化取舍与迁移验证”。分析基线固定为
`submissions/v0.1-week4`，该目录保持不变；第六周只在数据库副本上执行
`sql/week6` 中的脚本。

## 结论

现有 10 张业务表已经按分类、商品、库存、订单头、订单明细和流水拆分，所有属性均为
原子值，订单明细不存在对组合候选码的部分依赖，主要业务表达到 3NF。第六周不为了
“表越多越规范”而大拆表，而是修复一个可验证的参照完整性缺口：v0.1 的
`InventoryLog.BusinessNo` 是无外键文本，可能写入不存在或类型不匹配的订单号。

v1.0 将该字段替换为可空的 `PurchaseID`、`SaleID` 外键，并用
`CK_InventoryLog_Source` 规定每种流水只能引用正确的一类订单。查询显示仍通过
`v_inventory_log_detail.BusinessNo` 提供统一业务单号，因而不损失原有可读性。
`CK_InventoryLog_Direction` 同时保证入库/退货入库为正数、出库/退货出库为负数。

保留的反规范化包括 `Inventory.Quantity` 当前库存快照，以及订单头的 `TotalAmount`。
两者能显著降低日常查询成本，并且只能由事务过程维护，已有权限、触发器和回归测试
防止随意修改，因此本周选择保留。`LineAmount`、`PayableAmount` 是持久化计算列，不是
人工维护的重复数据。

## 文件导航

- [函数依赖清单](functional-dependencies.md)
- [范式与异常分析](normalization-analysis.md)
- [目标结构与无损性说明](target-schema.md)
- [v1.0 数据字典](data-dictionary.md)
- [迁移步骤与运行方式](migration-notes.md)
- [回归结果](regression-results.md)
- [v1.0 ER 图源文件](week6-er.drawio) / [SVG](week6-er.svg) / [PNG](week6-er.png)：直接沿用第五周图的实体位置、R01–R12 联系和视觉样式；取消未实施的拟议会员 R13，以 R14/R15 标出本周新增的采购/销售流水外键。
- [本周分析记录](ai-log.md)

## 推荐执行顺序

1. 完整备份数据库，并将副本命名为 `CampusStoreDB_W6_*`，例如 `CampusStoreDB_W6_Group1`。
2. 在副本中复现 v0.1：依次执行第一阶段的 `01`、`02`、`view.sql`、`role.sql`、`03`。
3. 执行 `sql/week6/baseline.sql`，保存迁移前明细、统计、库存和流水。
4. 执行 `sql/week6/migration.sql`，完成外键化迁移。
5. 每次执行前先在 SSMS 工具栏选择该副本；执行 `sql/week6/regression.sql`，看到 21 项均“通过”。

迁移完成后不要再次运行 v0.1 的 `02_business_procedures.sql`，因为迁移脚本已经把其中两个
库存流水写入点升级为外键写法。若需要重新演示完整迁移，应重新建立数据库副本并从基线开始。

自动隔离验证可在仓库根目录运行：

```powershell
& '.\tests\Verify-Week6Migration.ps1' -ServerInstance 'localhost'
```

脚本会使用随机临时数据库并在结束时删除，不修改正式 `CampusStoreDB`。

