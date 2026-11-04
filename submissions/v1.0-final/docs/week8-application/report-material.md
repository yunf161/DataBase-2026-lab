# 第二阶段报告素材：第八周应用开发（二）

## 目标与完成内容

以第六周迁移后的 SQL Server 数据库和第七周 Flask 应用为基础，完成按角色可用的采购、销售、盘点业务。管理员可以采购草稿增改删、确认入库、库存盘点；店员可以创建销售草稿、结算；顾客只能操作本人订单。页面提供业务提示与二次确认，服务层限制角色和输入，数据库层以受限角色授权、状态检查、外键/检查约束及业务过程维护数据。

## 关键业务链

| 链路 | 状态与数据变化 | 事务边界 |
| --- | --- | --- |
| 采购草稿→入库 | 建单/明细时库存不变；确认后 `DRAFT→RECEIVED`，每条明细增库并写 `InventoryLog.PurchaseID` | 一次确认调用既有 `dbo.ConfirmPurchase`，失败整单回滚 |
| 销售草稿→结算 | 草稿不扣库存；结算后 `DRAFT→COMPLETED`，每条明细扣库并写 `InventoryLog.SaleID` | 一次结算调用既有 `dbo.CompleteSale`，库存不足整单回滚 |
| 库存盘点 | 有理由的正负变化写当前量与 `STOCKTAKE_IN/OUT` 流水，来源订单外键均为空 | 应用事务与 SQL 过程保存点共同保护两表，失败回滚 |

应用保留页面 → route → service → repository → SQL 的四层路径；用户数据由 pyodbc 占位符绑定。管理员/店员/顾客的差异由前端显示、后端检查和 SQL 角色授权共同实现。`request_id` 将页面报错与服务端日志关联。

## 展示与证据

课堂可以按[操作手册](user-manual.md)依次演示双商品采购、盘点、销售结算和顾客越权失败；在 SSMS 查看 `PurchaseOrder`、`PurchaseItem`、`SaleOrder`、`SaleItem`、`Inventory`、`InventoryLog`。真实数据库隔离测试 72 项和浏览器 7 条检查均通过，原始记录和截图在[验证记录](verification.md)中。第八周不改 v0.1 冻结提交或正式库。

## 待第九周补充

最终报告可加入系统部署截图、成员分工与演示视频；若课程要求提交压缩包，可基于 `lzq` 当前提交打包，不应把 `instance/settings.json`、测试数据库或真实密码纳入提交。
