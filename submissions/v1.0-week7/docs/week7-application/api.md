# API输入、处理与输出

前缀/api，写操作JSON对象并带X-CSRF-Token。先GET /auth/session取令牌，
再POST /auth/login，之后使用响应新令牌；签名Cookie维持会话，role请求体或请求头不决定身份。

| 方法/路径 | 输入 | 输出与权限 |
| --- | --- | --- |
| GET /auth/session | 无 | user或null、csrf_token |
| POST /auth/login | username、password | 公开账号和新令牌 |
| POST /auth/logout | 空对象 | 清除登录、新匿名令牌 |
| GET /categories | 无 | 启用分类 |
| GET /products | q、status、page、page_size | 按角色过滤的items/total/page/page_size |
| POST /products | sku、product_name、category_id、sale_price；可选barcode/specification/unit/status | 管理员新增，返回零库存商品 |
| PUT /products/id | 同新增字段 | 管理员完整更新 |
| DELETE /products/id | 空对象 | 管理员安全删除 |
| GET /inventory | q、stock_status | 管理员/店员库存查询 |
| PATCH /inventory/id | min_quantity | 管理员改预警，不改数量 |
| GET /orders | q、status、page、page_size | 员工全店/顾客本人订单 |
| POST /orders | 可选payment_method/remark/items | 原子创建草稿，返回订单及明细 |
| GET /orders/id | 无 | 可见订单与items，不可见404 |
| PATCH /orders/id | payment_method、discount_amount、remark | 修改草稿，顾客优惠只能0 |
| POST /orders/id/items | product_id、quantity；员工可选unit_price | 加入明细，返回订单 |
| PATCH /orders/id/items/item_id | quantity；员工可选unit_price | 修改明细，保留原成交价 |
| DELETE /orders/id/items/item_id | 空对象 | 移除草稿行 |
| POST /orders/id/cancel | 空对象 | 取消可见草稿 |

商品PUT提交完整业务字段，订单PATCH提交需修改字段。
SKU/条码允许字母、数字、下划线及短横线；名称支持中文/普通文本。
金额以十进制字符串传输，最多两位小数。数量1—1000000整数，page从1开始，每页最多100，
创建一次最多100条明细，搜索词最长100字。payment_method为CASH/WECHAT/ALIPAY/BANK_CARD。
未知字段被拒绝，订单owner_user_id、employee_id、status、total_amount不允许由前端指定。

```json
{"ok": true, "code": "OK", "message": "操作成功。", "data": {}, "request_id": "服务端请求ID"}
```

失败ok=false、data=null。code区分INVALID_INPUT、AUTH_REQUIRED、AUTH_FAILED、FORBIDDEN、
CSRF_INVALID、NOT_FOUND、DUPLICATE_RECORD、BUSINESS_RULE、CONSTRAINT_CONFLICT、
DATABASE_UNAVAILABLE、INTERNAL_ERROR。message为用户提示，内部错误只写后端日志。
