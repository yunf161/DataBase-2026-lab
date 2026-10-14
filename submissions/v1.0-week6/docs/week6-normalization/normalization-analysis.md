# 范式、异常与保留方案

## 判断范围

以冻结 v0.1 和[函数依赖清单](functional-dependencies.md)为依据。字段原子化，满足 1NF。
2NF 检查全部候选码：明细表既有单字段代理码，也有 (订单 ID, ProductID) 复合码；
数量、成交价格等非主属性不部分依赖复合码的真子集，满足 2NF。
3NF 对非平凡依赖 X → A 要求 X 是超码或 A 是主属性。增加自增主码不能消除其他非码依赖。
定义参考[Emory University 的 3NF 说明](https://www.cs.emory.edu/~cheung/Courses/377/Syllabus/9-NormalForms/New/3NF.html)。

“基础属性关系”是分析时去掉派生字段的模式，不是本次迁移实际创建的新表。
完整物理关系包括计算列及保存的审计字段。

| 核心表 | 1NF / 2NF | 基础属性关系的 3NF | 完整物理关系的 3NF 与理由 | 方案 |
| --- | --- | --- | --- | --- |
| Category | 是 / 是 | 是 | 是；所列决定因素为 CategoryID 或 CategoryCode | 保留分类及自关联 |
| Supplier | 是 / 是 | 是 | 是；SupplierID、SupplierCode 分别决定其余属性 | 保留供应商资料 |
| Employee | 是 / 是 | 是 | 是；EmployeeID、EmployeeNo 分别决定其余属性 | 保留经办人、职责和状态 |
| Product | 是 / 是 | 是 | 是；ProductID、SKU 为码，未重复存分类名称 | 保留当前售价，历史成交价留明细 |
| Inventory | 是 / 是 | 是 | 是；ProductID 为单属性码，库存与流水同步是跨关系规则 | 保留当前快照 |
| PurchaseOrder | 是 / 是 | 是 | 是；PurchaseID、PurchaseNo 为码，明细求和不构成本表内非码决定关系 | 保留头部总额 |
| PurchaseItem | 是 / 是 | 去掉 LineAmount 后是 | 否；(Quantity, UnitCost) → LineAmount 的决定因素非超码、结果非主属性 | 保留持久化计算列 |
| SaleOrder | 是 / 是 | 去掉 PayableAmount 后是 | 否；(TotalAmount, DiscountAmount) → PayableAmount 同理 | 保留计算列及受控总额 |
| SaleItem | 是 / 是 | 去掉 LineAmount 后是 | 否；(Quantity, UnitPrice) → LineAmount 同理 | 保留成交价及计算列 |
| InventoryLog（两个版本） | 是 / 是 | 去掉 AfterQuantity 后，在所列依赖下是 | 否；(BeforeQuantity, ChangeQuantity) → AfterQuantity 的决定因素非超码 | 保留审计前后值及 CHECK；v1.0 将来源外键化 |

判定限于已确认依赖。来源外键化改善参照完整性，不消除数量等式，
不能声称迁移后十张完整物理表全部达到 3NF。

## 逐表插入、修改、删除异常

| 表 | 插入分析及例子 | 修改分析及例子 | 删除分析及例子 |
| --- | --- | --- | --- |
| Category | 可先建“饮料”而无商品，不必虚构交易 | 分类名只改一处，商品用 FK 查名称 | 有商品引用时 FK 拒绝删除，不会随最后一次销售丢失分类 |
| Supplier | 可录供应商而无采购单 | 联系方式只改供应商行，不重复在明细 | 历史采购引用阻止删除，可停用 |
| Employee | 可先录员工而无订单 | 姓名只存员工表，职责按管理规则修改 | 订单/流水引用阻止删除，离职用停用 |
| Product | 可录 P0001 而无销售，触发器补零库存 | 主数据改名/调价不覆盖历史 UnitPrice | 有交易则拒绝删商品，删最后一条草稿明细不删商品 |
| Inventory | 插入商品创建库存，PK 不允许同商品第二行 | 若独立改 Quantity 会与流水不一致；普通角色被拒绝改数量 | PK+FK 本身仍允许删库存行；普通角色无 DELETE，缺行时过程拒绝 |
| PurchaseOrder | 可先建无明细 DRAFT，空单确认被拒绝 | 草稿总额可暂未核算；确认按锁定明细重算，终态关键字段和明细受保护 | 明细/流水引用阻止删订单，不会带走供应商 |
| PurchaseItem | 数量 2、进价 1.00 自动得 LineAmount=2.00 | 草稿改数量自动重算，终态明细不可修改 | 草稿删行不删商品/供应商，终态明细不可删 |
| SaleOrder | 可建 DRAFT 后用 UpdateSaleDraft 补支付/优惠 | 总额 10.50、优惠 0.50 自动得应付 10.00，结算重算总额 | 明细/流水引用阻止删除，不带走商品和员工 |
| SaleItem | 保存当次 UnitPrice，自动计算行金额 | 草稿改价自动重算；P0001 调当前售价不改变历史销售 | 删草稿行不删商品资料，终态明细不可删 |
| InventoryLog | v0.1 可写失联文本；v1.0 FK 和来源 CHECK 拒绝缺失/错型订单 | Before=0、Change=30 时 After 必须为 30；CHECK 拒绝错改，来源升级为稳定 ID | 流水独立于订单明细；v1.0 FK 阻止删被引用来源订单，审计按权限保留 |

独立实体避免宽表中的典型异常；库存、总额和审计前后值仍有冗余维护责任。
控制措施降低不一致风险，不能当作派生依赖不存在的理由。

## 独立宽表示例与分解证明

教学关系
`SaleFactWide(SaleNo, SaleTime, EmployeeNo, EmployeeName, SKU, ProductName, CategoryCode, CategoryName, Quantity, UnitPrice)`
假设一单一商品一行，候选码为 (SaleNo, SKU)。
存在 SaleNo → SaleTime, EmployeeNo；SKU → ProductName, CategoryCode；
EmployeeNo → EmployeeName；CategoryCode → CategoryName；数量及成交价依赖完整组合码。
此宽表仅满足 1NF：没有销售的新商品无法单独插入，分类改名需改许多行，
删除最后销售记录可能丢失唯一保存的商品资料。

分解为以下示例关系：

- EmployeeDemo(EmployeeNo PK, EmployeeName)；
- CategoryDemo(CategoryCode PK, CategoryName)；
- ProductDemo(SKU PK, ProductName, CategoryCode FK)；
- SaleOrderDemo(SaleNo PK, SaleTime, EmployeeNo FK)；
- SaleItemDemo(SaleNo FK, SKU FK, Quantity, UnitPrice)，PK=(SaleNo, SKU)。

依次提取员工、分类、商品、订单头时，每次分解的交集分别为 EmployeeNo、
CategoryCode、SKU、SaleNo，均决定被提取关系全部属性，满足二元无损分解条件；
逐次无损所以整体无损。各业务依赖在对应子关系内直接保持，明细组合码依赖也保留。
这是设计层面的证明，有限样例连接成功不能替代。教学关系用于解释现有实体拆分，不新增到业务库。

## 冗余收益与维护

Inventory.Quantity 避免库存查询扫描全部流水；订单 TotalAmount 保存确认时结果并加快统计。
ConfirmPurchase / CompleteSale 用事务和 UPDLOCK,HOLDLOCK 锁定订单、明细及相关状态，
核算金额、更新库存、记流水后改终态；保存点支持调用者外层事务，失败不提前提交。
普通角色不能直接改库存，触发器拒绝直接插入终态、无有效过程标记的终态更新及终态明细修改。

LineAmount、PayableAmount 由 SQL Server 计算，不能人为写入；AfterQuantity 保存审计后的数量，
由数量 CHECK 校验。这是有理由保留的物理冗余，不是严格 3NF 的例外。
SESSION_CONTEXT 不是面向管理员的安全凭据；权限边界还依赖普通角色没有订单头 UPDATE、
库存数量写入和触发器修改权限，管理员仍能维护对象。

会员超出“不保存顾客身份”的业务边界，本周不新增；同商品一单一行规则保留。
本次业务结构变化是来源外键化，见[目标结构](target-schema.md)。

