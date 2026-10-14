# 范式与异常分析

## 1. 用未规范化销售宽表解释异常

假设把业务放在一张宽表：

`SaleFactWide(SaleNo, SaleTime, EmployeeNo, EmployeeName, SKU, ProductName, CategoryCode, CategoryName, Quantity, UnitPrice)`

其候选码为 `(SaleNo, SKU)`，但存在：

- `SaleNo → SaleTime, EmployeeNo`：订单头字段只依赖组合码的一部分；
- `SKU → ProductName, CategoryCode`：商品字段只依赖组合码的另一部分；
- `EmployeeNo → EmployeeName`、`CategoryCode → CategoryName`：存在传递依赖。

因此它只有 1NF，没有达到 2NF/3NF，并会产生三类异常：

- 插入异常：尚未销售的新商品无法在不虚构 SaleNo 的情况下录入；
- 更新异常：商品名、员工名重复在多行，漏改一行就互相矛盾；
- 删除异常：删除某商品最后一条销售明细时，可能连商品和分类信息一起丢失。

现有设计将宽表分解成 `SaleOrder`、`SaleItem`、`Employee`、`Product`、`Category`，上述信息
可独立插入、只在一处更新，也不会因删除销售明细而丢失基础资料。

## 2. 各表范式判断

| 表 | 1NF | 2NF | 3NF | 决策 |
| --- | --- | --- | --- | --- |
| Category / Supplier / Employee / Product | 是 | 是 | 是 | 保留；码决定全部非码属性 |
| PurchaseOrder / SaleOrder | 是 | 是 | 是 | 保留订单头；总额属于受控冗余，见下文 |
| PurchaseItem / SaleItem | 是 | 是 | 是 | 组合候选码的非码属性依赖整个候选码，不存在部分依赖 |
| Inventory | 是 | 是 | 是 | 单属性主码；作为性能快照保留 |
| InventoryLog v0.1 | 是 | 是 | 形式上满足 | 文本 BusinessNo 缺少参照完整性，仍有语义异常，进行外键化 |
| InventoryLog v1.0 | 是 | 是 | 是 | 订单来源由两个外键和类型 CHECK 联合保证 |

这里特别区分“范式”和“完整性”：v0.1 的窄流水表从表内函数依赖看并不必然违反 3NF，
但 `BusinessNo` 同时承载采购号、销售号甚至任意文本，数据库无法证明它指向真实订单。
例如订单号改名会造成流水失联，删除订单时也没有外键阻止孤儿流水。这是必须修复的
参照完整性问题，而不是为了凑分机械拆表。

## 3. 保留的受控反规范化

### Inventory.Quantity

理论上可从全部流水累加得到，但每次查看库存都扫描历史流水，成本随数据增长。系统保留
一行一商品的当前库存快照，由采购/销售事务过程更新；业务角色被拒绝直接改数量，且流水
保存变更前后数量。因此收益明确、维护路径受控，予以保留。

### PurchaseOrder.TotalAmount / SaleOrder.TotalAmount

总额可由明细求和，保存在订单头能快速查询和保留确认时的业务结果。它只在确认/结算过程
内根据锁定的明细重算；完成后的明细被触发器禁止修改。由此避免“订单头旧金额、明细新金额”
的不一致，予以保留。

### 计算列

`PurchaseItem.LineAmount`、`SaleItem.LineAmount`、`SaleOrder.PayableAmount` 由 SQL Server
表达式计算，调用者不能写入，不属于人工同步的重复字段。

## 4. 其他问题的取舍

- 会员：校园小卖部当前边界只有管理员、采购员、收银员和匿名顾客，不保存顾客身份；不建空壳会员表。
- `(OrderID, ProductID)` 唯一：规则是同一订单同一商品合并数量，属于业务候选码，保留。
- 商品与库存：PK+FK 保证每商品最多一行，商品插入触发器创建零库存行；回归继续验证业务角色不能删除/改数量。

