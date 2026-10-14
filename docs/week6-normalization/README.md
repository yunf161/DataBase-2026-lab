# 第六周：函数依赖、范式分析与迁移

对应第六周“关系规范化、冗余取舍与迁移验证”。分析基线为冻结的
`submissions/v0.1-week4`，迁移只在完整 v0.1 数据库副本上运行。

实体已经分离，基础业务属性关系在所列依赖下达到 3NF；完整物理关系中的 LineAmount、
PayableAmount 和库存 AfterQuantity 有非码派生依赖，严格判断不满足 3NF。
本周保留有明确维护措施的物理冗余，不能概括为“全部十表已达 3NF”。

实际变化是将 InventoryLog.BusinessNo 文本替换为 PurchaseID / SaleID 订单外键，
用来源 CHECK 保证类型和空值组合，用方向 CHECK 保证入出库正负号。
`v_inventory_log_detail` 用 LEFT JOIN 与 COALESCE 重构业务单号，仅允许管理员读完整流水。
迁移同时升级两类订单状态保护，拒绝缺失/不可转换的过程标记。

## 文件导航

- [逐表函数依赖及候选码](functional-dependencies.md)
- [逐表范式、三类异常及分解证明](normalization-analysis.md)
- [目标结构、无损性与依赖保持](target-schema.md)
- [v1.0 数据字典](data-dictionary.md)
- [迁移步骤、冲突与恢复](migration-notes.md)
- [实际回归结果及原始输出](regression-results.md)
- [报告素材：设计、过程、总结](report-material.md)
- ER 可编辑源 [draw.io](week6-er.drawio)，导出 [SVG](week6-er.svg) / [PNG](week6-er.png)
- [原有 AI 分析记录](ai-log.md)（本次不调整，按组内安排另行核对）

## 两种执行路径

**保留结果供 SSMS 展示：**完整备份 v0.1，在 SSMS“还原数据库”建立新副本，
目标名如 `CampusStoreDB_W6_Group1`，数据库文件也选择新的目标路径。
确认它已含十张业务表、过程、视图、角色及已有业务数据。
在工具栏选该副本后依次运行
[baseline.sql](../../sql/week6/baseline.sql) →
[migration.sql](../../sql/week6/migration.sql) →
[regression.sql](../../sql/week6/regression.sql)。
副本已有结构和数据，**不要再运行固定库名的 01 建库和 03 样例脚本**。
基线只在迁移前采集，迁移成功后不得覆盖原基线。

**自动从冻结提交复现并验证：**在仓库根目录运行：

```powershell
& '.\tests\Verify-Week6Migration.ps1' -ServerInstance '.\SQLEXPRESS'
```

脚本把冻结 01/02 等脚本中的库名改为随机 `CampusStoreDB_W6_*`，
完成基线、迁移、21 项回归、8 项状态专项、3 项迁移边界与1项用户异常清理验证，
随后删除自己创建的临时库。它不用于留下展示数据库，也不修改正式库。
具体实例名以 SSMS 连接为准，执行账号需有建库和模拟角色权限。

迁移后不能重跑 v0.1 的 02 业务过程脚本，否则会恢复已删除 BusinessNo 的写法。
再次演示迁移须重新还原一份 v0.1 副本；失败恢复方式见[迁移说明](migration-notes.md)。

## 图文件更新

draw.io 源图可直接编辑。使用现有生成器时，在仓库根目录运行
`python docs/week5-er/generate_diagram.py` 与
`python docs/week6-normalization/generate_diagram.py` 生成 SVG/draw.io；
PNG 再由 `node tests/Render-ErDiagrams.cjs` 从 SVG 渲染，需要 Node.js 环境中已安装 sharp，
可用 NODE_PATH 指向其安装位置。重新导图不需要执行数据库脚本。

