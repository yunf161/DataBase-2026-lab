# 迁移前后关键结果

本目录的数字全部来自 2026-11-04 在本机实际运行 `tests\Verify-Week6Migration.ps1` 与 `tests\Verify-CampusStore.ps1` 的输出，原始输出见同目录：

- [verify-week6-migration.txt](verify-week6-migration.txt)：第六周迁移（隔离库 `CampusStoreDB_W6_51149e5d2ade`，运行后已自动删除），退出码 0，耗时 14 秒。
- [verify-campusstore.txt](verify-campusstore.txt)：第 1—4 周主流程（隔离库 `CampusStoreDB_Verify_ad49d2ee6cf5`，运行后已自动删除），退出码 0，耗时 25 秒。

## 运行方式与环境说明

- 先用 `sqlcmd -S . -E -No -b -Q "SELECT @@VERSION"` 确认 `-No` 参数可用（sqlcmd 17.0.1000.7，退出码 0）。
- 运行命令：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\Verify-Week6Migration.ps1 -ServerInstance "."`，`Verify-CampusStore.ps1` 同理。这种写法不受脚本执行策略影响，实际命令记录在两个输出文件的开头。
- 这些 `.ps1` 最初是不带 BOM 的 UTF-8 文件，Windows PowerShell 5.1 按本地编码读取时报“字符串缺少终止符”，脚本一行都没有执行。后来给 `tests\` 和 `tools\` 下全部 7 个 `.ps1` 加了 UTF-8 BOM。本目录的输出是在 Windows PowerShell 5.1 下直接运行仓库脚本得到的，两个脚本的退出码都是 0。

## 迁移前：baseline.sql 保存的基线

| 指标 | 迁移前实际值 |
| --- | --- |
| 分类 / 供应商 / 员工 | 5 / 2 / 3 |
| 商品 / 库存行 | 6 / 6 |
| 采购单 / 采购明细 | 3 / 6 |
| 销售单 / 销售明细 | 3 / 5 |
| 库存流水 | 11 |
| 已收货采购总额 | 222.00 |
| 已完成销售原价总额 | 44.50 |

迁移前 `InventoryLog` 有文本列 `BusinessNo`，没有订单外键。

## 迁移后：regression.sql 与专项验证

| 验证 | 预期 | 实际 |
| --- | --- | --- |
| `migration.sql` | 成功 | 输出“第六周迁移成功：InventoryLog 已改为订单外键引用” |
| `regression.sql` | 21 项全部通过 | “第六周迁移回归全部通过，共 21 项” |
| 10 张业务表行数 | 与基线差异 0 | 差异 0（分类 5、供应商 2、员工 3、商品 6、库存 6、采购单 3、采购明细 6、销售单 3、销售明细 5、流水 11） |
| 已收货采购总额 | 222.00 | 222.00 |
| 已完成销售总额 | 44.50 | 44.50 |
| 当前库存、销售统计、流水展示 | 差异 0 | 差异 0 |
| 采购员 / 收银员 / 浏览者读取完整流水 | 错误 229 | 错误 229 |
| 收银员直接修改库存 | 错误 229 | 错误 229 |
| 非法采购外键、来源冲突、方向错误 | 被拒绝 | 被拒绝（`FK_InventoryLog_PurchaseOrder`、`CK_InventoryLog_Source`、`CK_InventoryLog_Direction`） |
| 订单状态保护专项 | 8 项通过 | “订单状态保护专项 8 项通过”（采购终态 51220、销售终态 51320，正常确认/完成仍可用） |
| 迁移边界 | 重复迁移、来源不匹配、末尾失败都不破坏数据 | 错误 51610、51613、2627；前后数据、列、对象定义与权限完全一致 |
| 用户异常路径清理 | 清理通过 | 错误 51625；探针用户清理通过 |

迁移后 `v_inventory_log_detail` 仍能还原业务单号（来自 `06_demo_observation.sql` 的输出）：

| 业务单号 | 变化类型 | 变化数量 | 变化前 → 变化后 |
| --- | --- | --- | --- |
| PO-DEMO-001 | PURCHASE_IN | +30 / +6 | 0 → 30 / 0 → 6 |
| PO-DEMO-002 | PURCHASE_IN | +40 / +20 / +15 | 0 → 40 / 0 → 20 / 0 → 15 |
| PO-DEMO-003 | PURCHASE_IN | +3 | 0 → 3 |
| SO-DEMO-001 | SALE_OUT | −3 | 30 → 27 |
| SO-DEMO-002 | SALE_OUT | −5 / −2 | 40 → 35 / 20 → 18 |
| SO-DEMO-003 | SALE_OUT | −2 / −3 | 15 → 13 / 3 → 0 |

共 11 行，与迁移前流水行数一致。

## 第 1—4 周主流程（Verify-CampusStore.ps1）

输出依次显示：结构对象验证通过、统计视图验证通过、第 4 周对象验证通过、采购/销售及整单回滚验证通过、真实角色业务和权限回归验证通过、订单状态保护专项 8 项通过、并发状态锁验证通过，最后是“隔离数据库 … 的结构、业务与演示数据验证通过”。

## 最终应用库的只读回归

最终 W7 库上的 30 项检查见上一级目录的 [final-regression.txt](../final-regression.txt)（脚本 `sql/week9/final_regression.sql`）。
