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
| PATCH /inventory/id/quantity | new_quantity、reason | 管理员盘点调整库存，返回product_id、quantity |
| GET /inventory/id/logs | page、page_size | 管理员查看该商品库存流水，items/total/page/page_size，新记录在前 |
| GET /orders | q、status、pending、page、page_size | 员工全店/顾客本人订单；pending=1只返回待受理订单 |
| POST /orders | 可选payment_method/remark/items | 原子创建草稿，返回订单及明细 |
| GET /orders/id | 无 | 可见订单与items，不可见404 |
| PATCH /orders/id | payment_method、discount_amount、remark | 修改草稿，顾客不能改变优惠金额 |
| POST /orders/id/items | product_id、quantity；员工可选unit_price | 加入明细，返回订单 |
| PATCH /orders/id/items/item_id | quantity；员工可选unit_price | 修改明细，保留原成交价 |
| DELETE /orders/id/items/item_id | 空对象 | 移除草稿行 |
| POST /orders/id/cancel | 空对象 | 取消可见草稿 |
| POST /orders/id/submit | 空对象 | 仅顾客提交本人草稿，返回submitted、price_changed、order |
| POST /orders/id/settle | 可选payment_method、discount_amount | 仅管理员/店员结算，返回已完成订单 |
| POST /cart/items | product_id、quantity | 所有登录角色，加入当前草稿，返回订单 |

商品PUT提交完整业务字段，订单PATCH提交需修改字段。
SKU/条码允许字母、数字、下划线及短横线；名称支持中文/普通文本。
金额以十进制字符串传输，最多两位小数。数量1—1000000整数，page从1开始，每页最多100，
创建一次最多100条明细，搜索词最长100字。payment_method为CASH/WECHAT/ALIPAY/BANK_CARD。
未知字段被拒绝，订单owner_user_id、employee_id、status、total_amount不允许由前端指定。

## 提交、结算、购物车与库存调整

所有接口都要求登录；写操作需X-CSRF-Token，缺失或不符返回403 CSRF_INVALID；未登录返回401 AUTH_REQUIRED。
路径编号必须是正整数，业务校验在服务层完成，失败时整个事务回滚。文本长度按SQL Server的nvarchar单位
（UTF-16代码单元）计算：一个汉字1个单位，一个emoji 2个单位，去掉首尾空白后超过上限返回400，孤立代理项也返回400。

### POST /orders/id/submit

- 权限：仅CUSTOMER；管理员/店员403。顾客只能提交本人订单，他人或不存在的订单404。
- 输入：空对象。
- 成功200，data为`{"submitted": bool, "price_changed": bool, "order": 订单及items}`。
  订单提交后submitted_at非空，顾客不能再改明细，库存仍不预留，结算时才扣减。
- 提交时商品现价与明细单价不同：返回200，price_changed=true、submitted=false，order为已刷新单价的最新订单，
  message为“部分商品价格已更新，请确认后重新提交。”，顾客确认后再次提交才生效。
- 错误：空订单409（51302）、含停用商品或分类409（51304）、库存不足409（51305）、已提交409（51811）、
  非草稿409（51803）。均为BUSINESS_RULE，提交时间不变。

### POST /orders/id/settle

- 权限：ADMIN、STAFF；顾客403。订单不存在404。
- 输入：可选payment_method（CASH/WECHAT/ALIPAY/BANK_CARD）、discount_amount（0—9999999999.99，最多两位小数）；
  校验规则与PATCH /orders/id相同，其他字段（含remark）400。空对象表示不修改。
- 处理：同一事务内先更新草稿再结算，任一步失败（例如库存不足）整体回滚，包括刚提交的支付方式和优惠。
- 成功200，data为已完成订单（status=COMPLETED、payable_amount已计算）。结算按提交时确认的单价成交，
  经办员工记为结算人。
- 错误：库存不足409（51305，message含“库存不足”）、顾客尚未提交409（51812）、空订单409（51302）、
  优惠超过合计409（51303）、含停用商品409（51304）、非草稿409。均为BUSINESS_RULE。

### POST /cart/items

- 权限：ADMIN、STAFF、CUSTOMER；加入的是当前登录账号自己的草稿。
- 输入：product_id（正整数）、quantity（1—1000000整数），必填，不接受其他字段。
- 处理：同一事务内查找当前草稿（本人名下、status=DRAFT且未提交，取编号最大的一张），没有则新建；
  商品已在草稿中则数量累加，保留原单价，否则新增明细。同一账号的并发加购串行执行。
  累加后超过1000000返回400 INVALID_INPUT，原数量不变。
- 成功200，data为订单及items。订单提交后再加购会新建草稿，不影响已提交订单。
- 错误：商品不存在或已停用409 BUSINESS_RULE，此时不会留下空草稿。

### PATCH /inventory/id/quantity

- 权限：仅ADMIN；店员、顾客403。商品不存在404。
- 输入：new_quantity（0—1000000整数，不接受字符串、布尔、小数）、reason（必填，去空白后1—255个UTF-16单位，
  纯空白400）。不接受其他字段，其中quantity、min_quantity也会被拒绝。
- 成功200，data为`{"product_id": 编号, "quantity": 新数量}`，同时写入库存流水（STOCKTAKE_IN/STOCKTAKE_OUT）。
- 新数量与现有数量相同返回409 BUSINESS_RULE（51813）。
- 原PATCH /inventory/id仍只修改预警下限min_quantity，行为不变。

### GET /inventory/id/logs

- 权限：仅ADMIN；商品不存在404。
- 查询参数：page（默认1）、page_size（默认20，最大100），格式错误400。
- 成功200，data为`{"items": [...], "total": n, "page": n, "page_size": n}`，按log_id倒序。每条含log_id、
  product_id、sku、product_name、change_type、change_quantity、before_quantity、after_quantity、business_no、
  employee_no、remark、created_at。

### GET /orders?pending=1

pending只接受1，表示只返回status=DRAFT且submitted_at非空（顾客已提交、等待店员受理）的订单，可与q、status、
分页组合；顾客只看到本人订单。其他取值（包括0、空字符串）返回400 INVALID_INPUT。

### PATCH /orders/id 的顾客优惠规则

顾客只有在请求中明确带discount_amount且与订单现有优惠不同时返回403 FORBIDDEN。不带该字段，或带与现值相同的
金额，都可以正常修改备注和支付方式；店员设置优惠后，顾客仍可改备注。

```json
{"ok": true, "code": "OK", "message": "操作成功。", "data": {}, "request_id": "服务端请求ID"}
```

失败ok=false、data=null。code区分INVALID_INPUT、AUTH_REQUIRED、AUTH_FAILED、FORBIDDEN、
CSRF_INVALID、NOT_FOUND、DUPLICATE_RECORD、BUSINESS_RULE、CONSTRAINT_CONFLICT、
TRANSACTION_FAILED、DATABASE_UNAVAILABLE、INTERNAL_ERROR。message为用户提示，内部错误只写后端日志。
数据库错误号只取驱动文本中后面紧跟(SQLxxx)、分号或结尾的括号数字，用户数据里的括号数字不参与分类。
BUSINESS_RULE（409）按错误号给出具体提示，如库存不足(51305)、空订单(51302)、订单状态已变化(51300等)。
TRANSACTION_FAILED（409）对应死锁/锁超时/事务回滚(1205、1222、3960、3930)及SQLSTATE 40001，提示稍后重试。
执行阶段的SQLSTATE HYT00、HYT01（语句因等锁等原因超过查询超时）同样归入TRANSACTION_FAILED；
发生在连接阶段（SQLDriverConnect）的HYT00、HYT01归入DATABASE_UNAVAILABLE。
SQLSTATE 28000、错误号18456和4060归入DATABASE_UNAVAILABLE（503）。
权限错误229和230（对象或列没有权限）都归入FORBIDDEN（403）。
配置项DB_QUERY_TIMEOUT是单条语句的执行超时秒数，默认15秒；DB_TIMEOUT是连接超时，默认5秒。
