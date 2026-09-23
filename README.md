# 校园小卖部进销存数据库

课程项目使用 SQL Server Express，数据库名为 `CampusStoreDB`。依据 [要求.md](要求.md) 的 10 张核心表设计，包含 3 个查询视图、采购入库和销售结算两个事务存储过程。

## 建库与验证

在 PowerShell 中从项目根目录依次执行：

```powershell
sqlcmd -S '.\SQLEXPRESS' -E -No -b -f 65001 -i 'sql\01_create_campus_store_database.sql'
sqlcmd -S '.\SQLEXPRESS' -E -No -b -f 65001 -i 'sql\02_business_procedures.sql'
sqlcmd -S '.\SQLEXPRESS' -E -No -b -f 65001 -i 'sql\04_verify.sql'
sqlcmd -S '.\SQLEXPRESS' -E -No -b -f 65001 -i 'sql\03_sample_data.sql'
& '.\tests\Verify-CampusStore.ps1'
```

`-E` 使用 Windows 身份验证，`-No` 将加密设为可选，`-b` 在 SQL 出错时返回非零退出码，`-f 65001` 按 UTF-8 读取中文脚本。`01` 和 `03` 只运行一次；重复执行会报错，避免覆盖既有数据。`02` 可重复部署。PowerShell 验证脚本创建一次性数据库运行测试，结束后删除测试库，不改动正式库数据。

## 业务操作

新建商品后，`tr_Product_CreateInventory` 自动建立数量为 0 的库存记录。采购和销售先建立默认状态 `DRAFT` 的订单，再插入明细，最后执行：

```sql
EXEC dbo.ConfirmPurchase @PurchaseID = 1;
EXEC dbo.CompleteSale @SaleID = 1;
```

确认过程会计算订单总额、修改库存、写入库存流水并更新状态。重复确认、空明细、库存不足、优惠超额等情况会报错并回滚。确认后的订单不能退回草稿，明细也不能再改动。销售明细的 `UnitPrice` 记录成交价，不受日后商品调价影响。退货和盘点的流水类型已预留，相关业务过程尚未实现，因此当前销售状态不开放 `REFUNDED`。

在 SSMS 中连接 `(local)\SQLEXPRESS` 后，可执行：

```sql
USE CampusStoreDB;
SELECT * FROM dbo.v_current_inventory;
SELECT * FROM dbo.v_current_inventory WHERE StockStatus IN ('LOW_STOCK','OUT_OF_STOCK');
SELECT * FROM dbo.v_sale_detail;
SELECT * FROM dbo.v_daily_sales;
SELECT * FROM dbo.InventoryLog ORDER BY LogID;
```

原始的 SQL Server 建表草稿保存在 `sql/00_original_campus_store_database.sql`，供对照学习；实际建库使用 `01`。
