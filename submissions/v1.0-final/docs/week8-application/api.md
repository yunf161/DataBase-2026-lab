# 第八周 API 与权限

共用第七周登录、签名 Cookie、`X-CSRF-Token`、JSON 响应和统一错误格式；见[第七周 API 说明](../week7-application/api.md)。下表只列增量接口，路径前缀为 `/api`。所有写操作接收 JSON 对象；金额用最多两位小数的字符串。

| 接口 | 输入 | ADMIN | STAFF | CUSTOMER |
| --- | --- | --- | --- | --- |
| `POST /orders/{id}/complete` | 可选 `payment_method,discount_amount,remark` | 同事务保存信息并结算 | 同事务保存信息并结算 | 403 |
| `GET /suppliers` | 无 | 查询启用供应商 | 403 | 403 |
| `GET /purchases`、`GET /purchases/{id}` | 无 | 查询采购单/明细 | 403 | 403 |
| `POST /purchases` | `supplier_id`，可选 `items:[{product_id,quantity,unit_cost}]` | 建草稿 | 403 | 403 |
| `POST /purchases/{id}/items` | `product_id,quantity,unit_cost` | 加明细 | 403 | 403 |
| `PATCH /purchases/{id}/items/{item_id}` | `quantity,unit_cost` | 改明细 | 403 | 403 |
| `DELETE /purchases/{id}/items/{item_id}` | 空对象 | 移除明细 | 403 | 403 |
| `POST /purchases/{id}/confirm` | 空对象 | 确认入库 | 403 | 403 |
| `POST /purchases/{id}/cancel` | 空对象 | 取消草稿 | 403 | 403 |
| `POST /inventory/{product_id}/adjust` | `delta,reason` | 盘点 | 403 | 403 |

`quantity` 为 1—1000000 的整数，`unit_cost` 不小于 0，`delta` 为绝对值不大于 1000000 的非零整数，`reason` 为 1—255 字。采购草稿必须有明细才能确认；确认和结算不可重复。盘点不能使库存小于零或超过 SQL Server `int` 范围。未知字段、无效输入返回 400；无会话返回 401；无权限返回 403；状态或库存冲突返回 409。原数据库错误文本只进服务端审计日志，响应是友好提示和请求编号。

角色权限同时在 service 层和数据库 `WebAdminRole` / `WebStaffRole` 授权中限制。前端隐藏入口只是交互提示，不能代替后端检查。结算时可携带当前表单值，若扣库存失败，支付信息一并回滚。采购商品选择器按名称或 SKU 搜索，能找到首批100件之外的商品；一次搜索最多显示100件，结果过多时应缩小关键词。采购单列表当前在服务端返回全部记录，前端做编号/供应商及状态筛选；大量采购单仍需增加服务端分页。
