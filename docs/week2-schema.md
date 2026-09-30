# 第 2 周 关系模式、属性与码

本文件对应实际运行的 SQL Server 脚本 [`01_create_campus_store_database.sql`](../sql/01_create_campus_store_database.sql)。以下“域”是 SQL Server 类型和允许值；`PK` 表示主码，`AK` 表示非空候选码，`FK` 表示外码，`UQ` 表示唯一但可为空。每张表的 `ID` 是系统生成的 `bigint IDENTITY`，不由业务人员手填。

## Category 商品分类

| 属性 | 域与含义 | 码 |
| --- | --- | --- |
| CategoryID | `bigint`，分类标识 | PK |
| CategoryCode | `varchar(20)`，分类编号 | AK |
| CategoryName | `nvarchar(50)`，分类名称 | — |
| ParentID | 可空 `bigint`，上级分类 | FK → Category.CategoryID |
| Description | 可空 `nvarchar(255)`，说明 | — |
| Status | `bit`，1 启用、0 停用 | — |
| CreatedAt | `datetime2(0)`，创建时间 | — |
| UpdatedAt | `datetime2(0)`，资料修改时间 | — |

`ParentID` 是自关联，可表示“食品 → 饮料”；为空表示顶层分类。

## Supplier 供应商

| 属性 | 域与含义 | 码 |
| --- | --- | --- |
| SupplierID | `bigint`，供应商标识 | PK |
| SupplierCode | `varchar(20)`，供应商编号 | AK |
| SupplierName | `nvarchar(100)`，名称 | — |
| ContactName | 可空 `nvarchar(50)`，联系人 | — |
| Phone | 可空 `varchar(30)`，联系电话 | — |
| Address | 可空 `nvarchar(255)`，地址 | — |
| Status | `bit`，1 正常、0 停用 | — |
| CreatedAt | `datetime2(0)`，创建时间 | — |
| UpdatedAt | `datetime2(0)`，资料修改时间 | — |

## Employee 员工

| 属性 | 域与含义 | 码 |
| --- | --- | --- |
| EmployeeID | `bigint`，员工标识 | PK |
| EmployeeNo | `varchar(20)`，员工编号 | AK |
| EmployeeName | `nvarchar(50)`，姓名 | — |
| RoleName | `varchar(20)`，`ADMIN`、`PURCHASER` 或 `CASHIER` | — |
| Phone | 可空 `varchar(30)`，电话 | — |
| Status | `bit`，1 在职、0 停用 | — |
| CreatedAt | `datetime2(0)`，创建时间 | — |

## Product 商品

| 属性 | 域与含义 | 码 |
| --- | --- | --- |
| ProductID | `bigint`，商品标识 | PK |
| SKU | `varchar(30)`，店内商品编号 | AK |
| Barcode | 可空 `varchar(32)`，商品条码 | UQ |
| ProductName | `nvarchar(100)`，名称 | — |
| CategoryID | `bigint`，所属分类 | FK → Category.CategoryID |
| Specification | 可空 `nvarchar(100)`，如 500ml | — |
| Unit | `nvarchar(20)`，如瓶、包 | — |
| SalePrice | `decimal(10,2)` 且非负，当前售价 | — |
| Status | `bit`，1 在售、0 停用 | — |
| CreatedAt | `datetime2(0)`，创建时间 | — |
| UpdatedAt | `datetime2(0)`，资料修改时间 | — |

条码是字符串，以保留前导零。`Barcode` 允许空值，虽然非空条码有唯一索引，但严格按“候选码必须能标识每个元组”的定义，它不是整张表的候选码。

## Inventory 当前库存

| 属性 | 域与含义 | 码 |
| --- | --- | --- |
| ProductID | `bigint`，商品标识；每种商品至多一行库存 | PK、FK → Product.ProductID |
| Quantity | 非负 `int`，现存数量 | — |
| MinQuantity | 非负 `int`，预警下限 | — |
| UpdatedAt | `datetime2(0)`，库存最近变化时间 | — |

新增商品时触发器建立零库存记录；确认采购和销售时由存储过程修改数量。

## PurchaseOrder 采购单头

| 属性 | 域与含义 | 码 |
| --- | --- | --- |
| PurchaseID | `bigint`，采购单标识 | PK |
| PurchaseNo | `varchar(30)`，采购单号 | AK |
| SupplierID | `bigint`，供货方 | FK → Supplier.SupplierID |
| EmployeeID | `bigint`，经办员工 | FK → Employee.EmployeeID |
| OrderTime | `datetime2(0)`，下单时间 | — |
| ReceivedTime | 可空 `datetime2(0)`，确认入库时间 | — |
| Status | `varchar(20)`，`DRAFT`、`RECEIVED`、`CANCELLED` | — |
| TotalAmount | 非负 `decimal(12,2)`，采购总金额 | — |
| Remark | 可空 `nvarchar(255)`，备注 | — |
| CreatedAt | `datetime2(0)`，创建时间 | — |
| UpdatedAt | `datetime2(0)`，修改时间 | — |

## PurchaseItem 采购明细

| 属性 | 域与含义 | 码 |
| --- | --- | --- |
| PurchaseItemID | `bigint`，明细标识 | PK |
| PurchaseID | `bigint`，所属采购单 | FK → PurchaseOrder.PurchaseID；与 ProductID 组成 AK |
| ProductID | `bigint`，采购商品 | FK → Product.ProductID；与 PurchaseID 组成 AK |
| Quantity | 正 `int`，采购件数 | — |
| UnitCost | 非负 `decimal(10,2)`，本次进价 | — |
| LineAmount | 计算列 `decimal(12,2)`，`Quantity × UnitCost` | — |

组合候选码 `(PurchaseID, ProductID)` 保证同一张单里同一商品只有一行。进价存在明细中，因为不同采购批次的价格可以不同。

## SaleOrder 销售单头

| 属性 | 域与含义 | 码 |
| --- | --- | --- |
| SaleID | `bigint`，销售单标识 | PK |
| SaleNo | `varchar(30)`，销售单号 | AK |
| EmployeeID | `bigint`，收银员工 | FK → Employee.EmployeeID |
| SaleTime | `datetime2(0)`，结算时间 | — |
| Status | `varchar(20)`，`DRAFT`、`COMPLETED`、`CANCELLED` | — |
| TotalAmount | 非负 `decimal(12,2)`，商品原始总额 | — |
| DiscountAmount | 非负 `decimal(12,2)`，优惠金额 | — |
| PayableAmount | 计算列 `decimal(12,2)`，总额减优惠 | — |
| PaymentMethod | 可空 `varchar(20)`，现金、微信、支付宝、银行卡代码 | — |
| Remark | 可空 `nvarchar(255)`，备注 | — |
| CreatedAt | `datetime2(0)`，创建时间 | — |

`PaymentMethod` 在草稿阶段可空；结算过程要求填写且优惠不得超过总额。

## SaleItem 销售明细

| 属性 | 域与含义 | 码 |
| --- | --- | --- |
| SaleItemID | `bigint`，明细标识 | PK |
| SaleID | `bigint`，所属销售单 | FK → SaleOrder.SaleID；与 ProductID 组成 AK |
| ProductID | `bigint`，售出商品 | FK → Product.ProductID；与 SaleID 组成 AK |
| Quantity | 正 `int`，销售件数 | — |
| UnitPrice | 非负 `decimal(10,2)`，成交当时单价 | — |
| LineAmount | 计算列 `decimal(12,2)`，`Quantity × UnitPrice` | — |

`UnitPrice` 不从商品当前价实时计算，因此调价后历史销售金额保持不变。

## InventoryLog 库存流水

| 属性 | 域与含义 | 码 |
| --- | --- | --- |
| LogID | `bigint`，流水标识 | PK |
| ProductID | `bigint`，变动商品 | FK → Product.ProductID |
| ChangeType | `varchar(30)`，采购入库、销售出库等业务代码 | — |
| ChangeQuantity | 非零 `int`，增加为正、减少为负 | — |
| BeforeQuantity | 非负 `int`，变动前库存 | — |
| AfterQuantity | 非负 `int`，变动后库存，等于前值加变化量 | — |
| BusinessNo | 可空 `varchar(30)`，关联采购或销售单号 | — |
| EmployeeID | 可空 `bigint`，操作员工 | FK → Employee.EmployeeID |
| Remark | 可空 `nvarchar(255)`，说明 | — |
| CreatedAt | `datetime2(0)`，发生时间 | — |

## 示例元组与关系解释

演示脚本 [`03_sample_data.sql`](../sql/03_sample_data.sql) 产生以下样例元组。表中的 `ID` 由数据库自动生成，因此这里用业务编号表示关系，不假设主键一定为 1。

| 表 | 样例元组中的关键字段 |
| --- | --- |
| Category | `CategoryCode='DRINK'`，`CategoryName='饮料'` |
| Supplier | `SupplierCode='S001'`，`SupplierName='校园供货商'` |
| Employee | `EmployeeNo='E001'`，`RoleName='ADMIN'` |
| Product | `SKU='P0001'`，`ProductName='可口可乐'`，`SalePrice=3.50`，所属分类为 `DRINK` |
| Inventory | `P0001` 对应 `Quantity=27`、`MinQuantity=20`（采购并销售后） |
| PurchaseOrder | `PurchaseNo='PO-DEMO-001'`，供应商 `S001`，`Status='RECEIVED'`，`TotalAmount=84.00` |
| PurchaseItem | `PO-DEMO-001` 的 `P0001` 明细：`Quantity=30`，`UnitCost=2.20`，`LineAmount=66.00` |
| SaleOrder | `SaleNo='SO-DEMO-001'`，`Status='COMPLETED'`，`TotalAmount=10.50`，`DiscountAmount=0.50` |
| SaleItem | `SO-DEMO-001` 的 `P0001` 明细：`Quantity=3`，`UnitPrice=3.50`，`LineAmount=10.50` |
| InventoryLog | `SO-DEMO-001` 的 `SALE_OUT`：`ChangeQuantity=-3`，`BeforeQuantity=30`，`AfterQuantity=27` |

采购单还包含纸巾 6 包、进价 3.00，合计 18.00；确认后可乐库存从 0 变为 30。销售单售出 3 瓶后，可乐库存变为 27，流水留下 `30 → 27` 的记录。

分类对商品、供应商对采购单、订单头对明细都是一对多；商品对库存是一对一；订单与商品之间的多对多关系通过采购或销售明细拆开。`CreatedAt` 等字段有插入默认值。`Category`、`Supplier`、`Product`、`Inventory` 和 `PurchaseOrder` 的 `UpdatedAt` 由触发器在修改后维护；SQL Server 本身没有 MySQL 示例中的 `ON UPDATE CURRENT_TIMESTAMP` 语法。
