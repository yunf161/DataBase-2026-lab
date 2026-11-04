# 第八周操作手册

## 启动与页面查看

按[README 的复现命令](README.md)准备隔离应用库并启动 Flask，浏览器打开 <http://127.0.0.1:5070>。PowerShell 窗口要保持运行；按 Ctrl+C 停止服务。SSMS 顶部必须连接同一个 SQL Server 实例（本机通常 `(local)\SQLEXPRESS`），左侧“数据库”右键刷新后展开 `CampusStoreDB_W7_Development`。Web 应用与第一阶段正式 `CampusStoreDB` 是两个库。

## 课堂演示顺序

1. 用 `admin` / `Campus2026!` 登录。左侧“采购入库”→“新建采购”，选“校园供货商”，建立草稿；在明细中选可口可乐 3 瓶、进价 2.00 元，再选纸巾 4 包、进价 1.50 元。合计应为 12.00 元。商品多于100件时可在“搜索可采购商品”输入名称或编号。可试着更新数量、删除明细再加回。点“确认入库”并在确认框再次确认；状态变“已入库”。
2. 关闭明细，进入“库存查询”。可口可乐和纸巾库存比确认前各增加 3、4。点可口可乐行的“盘点调整”，填 `-2`，原因为“课堂盘点复核”，确认后可口可乐库存再减少 2。
3. 退出后用 `staff` 登录。左侧“销售订单”→“新建草稿”，加可口可乐 2 瓶；草稿不扣库存。可把支付方式改为微信、优惠填 1.00、备注填“课堂现结”，直接点击“完成结算”并确认；当前表单值和结算会一次保存。订单变“已完成”，可口可乐库存减少 2；再次结算会被拒绝。
4. 退出后用 `customer` 登录。顾客可建自己的销售草稿，但看不到“采购入库”“库存查询”和“完成结算”；访问相应 API 仍会被后端拒绝。`customer2` 可证明不同顾客互相看不到订单。

每一步的结果会在列表、明细或右上角提示显示。失败时页面给出错误提示及参考编号，可用编号在 `instance/logs/application.jsonl` 中查对应服务端事件。

## 在 SSMS 看完整数据

打开 SSMS → 连接同一实例 →“数据库”→`CampusStoreDB_W7_Development`→“表”。核心表在 `dbo` 下：`Product`、`Inventory`、`PurchaseOrder`、`PurchaseItem`、`SaleOrder`、`SaleItem`、`InventoryLog`；账号与顾客订单归属在 `app.AppUser`、`app.SaleOwner`。右键表 →“选择前 1000 行”，或点“新建查询”，工具栏数据库下拉选择该库，执行：

```sql
SELECT TOP (20) PurchaseID,PurchaseNo,Status,TotalAmount,ReceivedTime
FROM dbo.PurchaseOrder ORDER BY PurchaseID DESC;
SELECT TOP (20) SaleID,SaleNo,Status,TotalAmount
FROM dbo.SaleOrder ORDER BY SaleID DESC;
SELECT ProductID,Quantity,MinQuantity FROM dbo.Inventory ORDER BY ProductID;
SELECT TOP (30) ProductID,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,
       PurchaseID,SaleID,Remark
FROM dbo.InventoryLog ORDER BY LogID DESC;
```

按 **F5** 运行。`PurchaseID` 有值的流水对应采购；`SaleID` 有值的对应销售；盘点流水二者均为空，`ChangeType` 为 `STOCKTAKE_IN/OUT`，`Remark` 保存原因。明细表可按新订单的 `PurchaseID` / `SaleID` 过滤。查询不改数据，可反复运行。

如果页面失败但 SSMS 能看到数据库，先核对应用 `instance/settings.json` 中的 `DB_SERVER`、`DB_DATABASE` 是否与 SSMS 相同，并确认第八周增量已部署。不要在 MySQL 中查找本项目数据库。
