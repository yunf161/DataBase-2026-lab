# 第七周验证记录

执行日期：2026-10-21。真实SQL Server Express，Python 3.14.2，Flask 3.1.3，pyodbc 5.3.0，
Playwright/Chromium实际浏览器。不是SQLite替代测试或静态页面截图。

统一入口先建立随机W7集成测试库，再建立另一随机浏览器测试库，均在退出时删除；
临时HTTP服务使用本机随机端口，长期开发库不参与统一验收。正式CampusStoreDB不作为写入目标。

## 实际结果

| 验证 | 实际结果 |
| --- | --- |
| 真实SQL集成测试 | 59项通过，0失败 |
| 实际浏览器 | 10项通过，0未捕获JavaScript异常 |
| 截图 | 8张，来自真实界面操作 |
| 事务原子性 | 第2件无效/重复时，订单头、归属、第一条明细均回滚 |
| 权限 | 后台角色检查与受限数据库身份同时生效，实际库存UPDATE/密码表SELECT被拒绝 |
| 归属隔离 | 另一顾客订单GET/PATCH/取消均404；直接查询数据库视图也隔离 |
| 连接失败 | 连接本机关闭端口实际返回503，前端无SQL/驱动/路径信息，后端保留详细错误 |
| 测试库清理 | 0个随机测试库残留；保留CampusStoreDB_W7_Development用于展示 |
| 保留核对 | 135个文件SHA-256一致；正式库快照与10月14日验证结果相同 |

第七周后台会话与路径编号范围修正后重跑全部59项；手机退出按钮修正后在新独立库复验浏览器流程。
每项通过都包含HTTP响应、数据或数据库权限断言，不以“页面能打开”替代业务验证。

## 关键预期与实际

| 场景 | 预期 | 实际 |
| --- | --- | --- |
| 未登录读取/创建订单 | 401 AUTH_REQUIRED | 401，统一响应 |
| 管理员/店员/顾客登录 | 角色来自账号，密码不返回 | 三角色验证通过 |
| 错误密码/不存在账号/登录注入 | 统一401，不透露账号是否存在 | AUTH_FAILED，相同友好提示 |
| 缺失CSRF写操作 | 403 | CSRF_INVALID |
| 商品CRUD | 新增201，编辑/安全删除200，零库存 | 6.50→7.20，库存关联一并安全删除 |
| 负价/NaN/小数超精度/布尔ID/未知支付类型 | 400 | INVALID_INPUT |
| 重复SKU/无效分类 | 409，不泄露SQL | DUPLICATE_RECORD/CONSTRAINT_CONFLICT |
| 有历史记录商品删除 | 409 | BUSINESS_RULE |
| 参数化搜索 | 引号注入不扩展结果，%按字面 | 查询0项，原数据仍可查询 |
| 顾客跨订单访问 | 404，不能改/取消别人的订单 | 全部拒绝 |
| 顾客改价/优惠/指定归属或员工 | 403或未知字段400 | 拒绝，成交价仍按数据库商品售价 |
| 创建2件可乐草稿 | 7.00，库存仍27，无新销售流水 | 全部符合 |
| 已完成订单修改/取消 | 409 | BUSINESS_RULE |
| 业务连接权限 | USER_NAME为Web角色，db_owner=0 | 四类执行身份明确，三业务角色均非db_owner |
| 旧读取响应与退出并发 | 读取不刷新认证Cookie | 无Set-Cookie，退出后读取401 |
| 前端/后端错误区别 | 前端友好提示，日志可定位 | 503及请求ID可与后台详细事件对应 |

## 集成测试逐项记录

完整预期与断言见[测试源码](../../tests/week7/test_application.py)；
以下为实际pytest逐项结果，参数化用例分别计数。

| 测试标识 | 实际 | 耗时/秒 |
| --- | --- | --- |
| test_public_page_is_served_without_database | 通过 | 0.089 |
| test_unauthenticated_requests_are_rejected[GET-/products] | 通过 | 0.001 |
| test_unauthenticated_requests_are_rejected[GET-/inventory] | 通过 | 0.001 |
| test_unauthenticated_requests_are_rejected[GET-/orders] | 通过 | 0.001 |
| test_unauthenticated_requests_are_rejected[POST-/orders] | 通过 | 0.001 |
| test_roles_come_from_authenticated_account[admin-ADMIN] | 通过 | 0.212 |
| test_roles_come_from_authenticated_account[staff-STAFF] | 通过 | 0.205 |
| test_roles_come_from_authenticated_account[customer-CUSTOMER] | 通过 | 0.24 |
| test_bad_login_does_not_reveal_account_or_accept_injection[admin] | 通过 | 0.142 |
| test_bad_login_does_not_reveal_account_or_accept_injection[does-not-exist] | 通过 | 0.228 |
| test_bad_login_does_not_reveal_account_or_accept_injection[' OR 1=1--] | 通过 | 0.228 |
| test_login_requires_csrf | 通过 | 0.001 |
| test_write_requires_current_csrf_token | 通过 | 0.333 |
| test_logout_invalidates_access | 通过 | 0.261 |
| test_read_response_cannot_restore_a_logged_out_cookie | 通过 | 0.306 |
| test_unsigned_session_cookie_is_rejected | 通过 | 0.001 |
| test_malformed_json_has_uniform_response | 通过 | 0.002 |
| test_product_crud_keeps_inventory_consistent | 通过 | 0.486 |
| test_product_maintenance_requires_admin[staff] | 通过 | 0.3 |
| test_product_maintenance_requires_admin[customer] | 通过 | 0.313 |
| test_product_duplicate_is_a_friendly_conflict | 通过 | 0.351 |
| test_bad_product_input_is_rejected[sale_price--1] | 通过 | 0.356 |
| test_bad_product_input_is_rejected[sale_price-NaN] | 通过 | 0.25 |
| test_bad_product_input_is_rejected[sale_price-1.234] | 通过 | 0.247 |
| test_bad_product_input_is_rejected[sale_price-True] | 通过 | 0.248 |
| test_bad_product_input_is_rejected[category_id-True] | 通过 | 0.247 |
| test_bad_product_input_is_rejected[status-4] | 通过 | 0.244 |
| test_bad_product_input_is_rejected[sku-bad' OR 1=1--] | 通过 | 0.254 |
| test_bad_product_input_is_rejected[product_name-] | 通过 | 0.248 |
| test_invalid_category_uses_database_constraint | 通过 | 0.282 |
| test_product_with_history_cannot_be_deleted | 通过 | 0.295 |
| test_search_is_parameterized_and_wildcards_are_literal | 通过 | 0.733 |
| test_invalid_list_parameters_are_rejected[query0] | 通过 | 0.262 |
| test_invalid_list_parameters_are_rejected[query1] | 通过 | 0.271 |
| test_invalid_list_parameters_are_rejected[query2] | 通过 | 0.258 |
| test_invalid_list_parameters_are_rejected[query3] | 通过 | 0.257 |
| test_customer_cannot_access_inventory_or_inactive_catalog | 通过 | 0.757 |
| test_inventory_threshold_does_not_change_quantity | 通过 | 0.79 |
| test_customer_draft_ownership_and_price | 通过 | 0.948 |
| test_draft_items_add_update_delete_cancel | 通过 | 1.349 |
| test_customer_cannot_override_price_owner_employee_or_status | 通过 | 0.699 |
| test_invalid_payment_types_are_input_errors[None] | 通过 | 0.24 |
| test_invalid_payment_types_are_input_errors[payment1] | 通过 | 0.265 |
| test_invalid_payment_types_are_input_errors[payment2] | 通过 | 0.247 |
| test_invalid_payment_types_are_input_errors[False] | 通过 | 0.246 |
| test_order_creation_rolls_back_all_partial_writes | 通过 | 0.469 |
| test_duplicate_order_lines_roll_back_header_and_first_line | 通过 | 0.339 |
| test_completed_orders_reject_mutations | 通过 | 0.629 |
| test_database_execution_identity_has_no_owner_or_sensitive_table_access[ADMIN-admin-WebAdmin] | 通过 | 0.283 |
| test_database_execution_identity_has_no_owner_or_sensitive_table_access[STAFF-staff-WebStaff] | 通过 | 0.291 |
| test_database_execution_identity_has_no_owner_or_sensitive_table_access[CUSTOMER-customer-WebCustomer] | 通过 | 0.281 |
| test_database_view_enforces_ownership_without_api_filter | 通过 | 0.699 |
| test_disabled_account_is_rechecked_for_existing_session | 通过 | 0.274 |
| test_sql_connection_failure_is_friendly_and_logged | 通过 | 1.265 |
| test_unknown_endpoint_and_invalid_method_share_error_format | 通过 | 0.364 |
| test_path_identifiers_are_bounded_before_database_access[GET-/orders/9223372036854775808] | 通过 | 0.268 |
| test_path_identifiers_are_bounded_before_database_access[DELETE-/products/0] | 通过 | 0.273 |
| test_path_identifiers_are_bounded_before_database_access[PATCH-/orders/1/items/9999999999999999999999999999] | 通过 | 0.253 |
| test_request_log_has_trace_role_code_and_result | 通过 | 0.267 |

## 浏览器逐项记录

| 场景 | 实际证据 | 结果 |
| --- | --- | --- |
| 登录失败友好提示 | 用户名或密码不正确。 | 通过 |
| 管理员通过界面完成商品增改删 | 6.80 → 7.20，商品保持在售，零库存商品删除成功 | 通过 |
| 删除有历史记录商品被拒绝 | 409，前端显示友好业务提示与参考编号 | 通过 |
| 管理员库存查询 | 6件商品的库存与预警状态 | 通过 |
| 店员界面与权限 | 可查库存和订单，无商品维护入口 | 通过 |
| 顾客直接请求库存接口被拒绝 | FORBIDDEN | 通过 |
| 顾客草稿完整界面流程 | 创建、2件可乐7.00、加水9.00、保存备注/支付、移除明细、取消 | 通过 |
| 另一顾客无法访问订单 | NOT_FOUND | 通过 |
| 390px手机布局 | 页面无整体横向溢出，表格卡片内横向滚动，手机可退出登录 | 通过 |
| 浏览器脚本运行 | 无未捕获JavaScript异常 | 通过 |

## 原始证据

- [集成原始输出](results/integration-output.txt)、[逐项JSON](results/integration-results.json)、[JUnit XML](results/integration-junit.xml)
- [浏览器原始输出](results/browser-output.txt)、[逐项JSON](results/browser-results.json)
- [汇总](results/summary.json)
- [独立提交目录复现](results/package-smoke.json)：从包内初始化真实数据库，登录200、商品查询200/6件、草稿创建201/7.00，随后清理测试库
- [后端真实连接失败日志示例](results/backend-error-example.jsonl)：仅将项目绝对路径替换为占位符，完整原日志留在instance/tests
- [保留检查](results/preservation-check.json)、[受保护文件SHA-256](results/protected-files.sha256.json)

## 真实界面截图

1. [登录](results/01-login.png)
2. [管理员商品管理](results/02-admin-products.png)
3. [拒绝删除历史商品的友好提示](results/03-friendly-business-error.png)
4. [管理员库存查询](results/04-admin-inventory.png)
5. [店员销售订单](results/05-staff-orders.png)
6. [顾客货架](results/06-customer-catalog.png)
7. [顾客本人草稿明细](results/07-customer-draft.png)
8. [390px手机布局](results/08-mobile-customer.png)

当前不将草稿视为已完成销售：本周界面没有销售结算、采购确认或盘点数量调整。
第八周再接入这些完整业务过程。AI记录仍按组内安排另行整理。
