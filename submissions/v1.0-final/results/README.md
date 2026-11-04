# 结果目录说明

本目录收录第二阶段（第 5—9 周）的实际运行结果。所有数字和截图来自 2026-11-04 在本机的真实运行（Windows、SQL Server 2025 Developer 默认实例、Python 3.13.12、ODBC Driver 18），没有手工编写的测试结果。找不到来源的内容在文档中标为“待补充”。

## 目录内容

| 路径 | 内容 | 来源 |
| --- | --- | --- |
| [er/](er) | 第 5 周 v0.1 ER 图、第 6 周 v1.0 ER 图，各有 draw.io 源文件、SVG 和 PNG | 复制自 `docs/week5-er/`、`docs/week6-normalization/` |
| [normalization/](normalization) | 函数依赖清单、范式与异常分析、目标结构与无损/依赖保持证明 | 复制自 `docs/week6-normalization/`，只调整了相对链接 |
| [migration/](migration) | 迁移前后关键结果 [key-results.md](migration/key-results.md)；两个验证脚本的完整输出 | `tests\Verify-Week6Migration.ps1`、`tests\Verify-CampusStore.ps1` |
| [app-test/](app-test) | 应用集成测试（295 项）、浏览器验收（25 项）、21 张截图、JUnit 与 JSON 明细 | `python -m tools.verify_week7 --server "."` |
| [doctor.txt](doctor.txt) | 环境预检输出：8 项全部通过 | `python -m tools.doctor --server "."` |
| [prepare-week7.txt](prepare-week7.txt) | 建开发库 `CampusStoreDB_W7_Development` 的输出 | `python -m tools.prepare_week7 --server "."` |
| [final-regression.txt](final-regression.txt) | 开发库上的 30 项只读回归：库存与流水、订单金额、销量统计、外键与流水来源、受限角色权限 | `sql/week9/final_regression.sql` |
| [package-smoke.json](package-smoke.json) | 把交付包解压到临时目录后的空环境复现结果 | `tools/smoke_package.py` |

`app-test/` 中的 `integration-results.json`、`integration-junit.xml`、`integration-output.txt` 是 pytest 的逐项记录，`browser-results.json` 是浏览器验收的逐项预期与实际，`summary.json` 汇总为：集成 295 项通过、浏览器 25 项通过、0 个未捕获 JavaScript 异常、测试库已清理。

## 不同角色的完整业务流程与截图

订单流转：购物车 → 待受理 → 已完成 / 已取消，详见 [操作手册](../docs/week7-application/user-manual.md) 和 [状态流转图](../docs/week7-application/architecture.md)。

| 角色 | 流程步骤 | 截图 |
| --- | --- | --- |
| 所有角色 | 登录页，登录失败提示 | [01](app-test/01-login.png) |
| 顾客 customer | 浏览在售商品（无库存和维护入口） | [06](app-test/06-customer-catalog.png) |
| | 加入购物车，在“我的订单”维护购物车 | [07](app-test/07-customer-draft.png) |
| | 管理员改价后提交，提示价格已更新、需再次确认 | [15](app-test/15-price-changed.png) |
| | 提交订单，状态变为“待受理”，只能取消 | [09](app-test/09-customer-cart-submitted.png) |
| | 店员结算后看到“已完成”和应付金额 | [11](app-test/11-customer-completed.png) |
| | 已取消订单不显示应付金额 | [20](app-test/20-cancelled-no-payable.png) |
| | 手机宽度（390px）下浏览、提交、查看订单详情 | [08](app-test/08-mobile-customer.png)、[16](app-test/16-mobile-order-detail.png) |
| 店员 staff | 查看商品、库存和销售订单，无商品维护入口 | [05](app-test/05-staff-orders.png) |
| | 在“待受理”中确认收款并结算 | [10](app-test/10-staff-settle.png) |
| | 库存不足时结算被拒绝，订单保持待受理 | [13](app-test/13-insufficient-stock.png) |
| | 结算后库存页数量减少，无调整和流水按钮 | [12](app-test/12-staff-inventory-after-sale.png) |
| 管理员 admin | 商品增改查，保存后立即可见 | [02](app-test/02-admin-products.png) |
| | 删除有历史记录的商品被拒绝，显示友好提示 | [03](app-test/03-friendly-business-error.png) |
| | 库存查询与预警状态 | [04](app-test/04-admin-inventory.png) |
| | 调整库存（必填原因）并查看库存流水 | [14](app-test/14-admin-adjust-and-logs.png) |
| | 手机宽度下查看库存流水 | [17](app-test/17-mobile-inventory-logs.png) |
| | 编辑已停用分类下的商品，分类保持不变 | [21](app-test/21-disabled-category-edit.png) |
| 界面反馈 | 提示条显示在弹窗遮罩上方 | [18](app-test/18-toast-over-dialog.png) |
| | 1366×768 下，弹窗内错误滚动到可视范围 | [19](app-test/19-error-in-view-1366.png) |

权限差异的权威矩阵在 [架构说明](../docs/week7-application/architecture.md)：顾客只能操作本人订单且不能结算；店员可结算、不能维护商品或调整库存；管理员可维护商品、调整库存和查看流水。数据库层的权限由 [final-regression.txt](final-regression.txt) 第 15—30 项复核（四个 Web 身份都不是 db_owner、不能直接改 `Inventory.Quantity`；三个业务身份读取 `app.AppUser` 时实际得到错误 229）。

## 错误响应分类与证据

所有失败响应格式一致：`{"ok": false, "code": ..., "message": ..., "data": null, "request_id": ...}`，前端不显示 SQL、堆栈、路径或连接信息。下表的测试名都在 [integration-results.json](app-test/integration-results.json) 中，本次运行均为 passed（括号内是该测试在本次运行中的用例数）；测试源码在 `tests/week7/`。

| 类别 | code（HTTP） | 触发场景与用户看到的消息 | 证据 |
| --- | --- | --- | --- |
| 输入错误 | `INVALID_INPUT`（400） | 负价、NaN、超精度、布尔值、非法 JSON、超长文本等，如“提交内容格式不正确。” | `test_bad_product_input_is_rejected`（8）、`test_malformed_json_has_uniform_response`、`test_overlong_reason_is_rejected_by_utf16_length`（4）、`test_lone_surrogate_password_is_invalid_input_not_server_error`、`test_settle_rejects_bad_input_before_changing_anything`（14） |
| 未登录 | `AUTH_REQUIRED`（401） | 未登录访问接口，“请先登录后继续。”；登录失败为 `AUTH_FAILED`（401）“用户名或密码不正确。”，不区分账号是否存在 | `test_unauthenticated_requests_are_rejected`（4）、`test_anonymous_requests_are_rejected`（5）、`test_bad_login_does_not_reveal_account_or_accept_injection`（3）；浏览器验收“登录失败友好提示” |
| 无权限 | `FORBIDDEN`（403）；CSRF 缺失为 `CSRF_INVALID`（403） | 顾客读库存、店员维护商品、顾客结算，“当前角色没有执行此操作的权限。”；数据库层 229/230 也映射为此类 | `test_unauthorised_roles_are_forbidden`（5）、`test_permission_matrix_is_denied`（10）、`test_customer_cannot_access_inventory_or_inactive_catalog`、`test_column_permission_denied_230_is_forbidden_like_229`、`test_writes_without_csrf_token_are_rejected`（4）；浏览器验收“顾客直接请求库存接口被拒绝”（403） |
| 数据不存在 | `NOT_FOUND`（404） | 他人的订单或不存在的记录，“记录不存在或当前账号无法访问。”（不泄露是否存在） | `test_other_customer_cannot_submit_or_see_the_order`、`test_user_data_number_does_not_hide_51804`、`test_adjust_inventory_rejects_unchanged_quantity_and_unknown_product`；浏览器验收“另一顾客无法访问订单”（404） |
| 业务规则 | `BUSINESS_RULE`（409） | 库存不足“部分商品库存不足，订单未结算，请调整数量后重试。”、有历史记录的商品不能删除、已完成订单不能修改、顾客未提交不能结算等 | `test_business_rule_messages`（19）、`test_settle_with_insufficient_stock_rolls_back_payment_and_discount`、`test_product_with_history_cannot_be_deleted`、`test_settle_rejects_disabled_category_after_submit`；截图 [13](app-test/13-insufficient-stock.png)、[03](app-test/03-friendly-business-error.png) |
| 连接失败 | `DATABASE_UNAVAILABLE`（503） | 连接 SQL Server 失败或连接阶段超时，“系统暂时无法连接数据服务，请稍后重试。”，详细原因只写后端日志 | `test_sql_connection_failure_is_friendly_and_logged`（连接本机关闭端口，响应不含 ODBC/SQL Server/tcp/Traceback，日志含请求编号）、`test_connection_timeout_is_unavailable`（2） |
| 约束冲突 | `DUPLICATE_RECORD`（409）、`CONSTRAINT_CONFLICT`（409） | 重复 SKU/条码/订单明细“编号、条码或订单中的商品已存在，请检查后重试。”；外键、检查约束冲突“数据与现有记录或数量、金额限制冲突……” | `test_product_duplicate_is_a_friendly_conflict`、`test_numeric_duplicate_sku_is_duplicate_not_forbidden`（SKU 为 `229`）、`test_invalid_category_uses_database_constraint`、`test_duplicate_order_lines_roll_back_header_and_first_line` |
| 事务失败 | `TRANSACTION_FAILED`（409） | 死锁、锁等待超时、语句执行超时、并发冲突，“操作因并发冲突未生效，请稍后重试。”，事务已整体回滚 | `test_blocked_inventory_update_times_out_as_transaction_conflict`（真实锁阻塞后返回 409 且数据未改）、`test_query_timeout_is_transaction_conflict`（2）、`test_transaction_failures_by_number`（4）、`test_transaction_failure_by_sqlstate`；回滚证据：`test_settle_failure_rolls_back_every_line_and_can_be_retried`、`test_order_creation_rolls_back_all_partial_writes` |
| 内部错误（补充） | `INTERNAL_ERROR`（500） | 未知异常，“系统暂时无法完成操作，请稍后重试。”，堆栈只写日志 | `test_unknown_error_is_internal` |

## 安全性与参数化查询的证据

- 参数化：`test_search_is_parameterized_and_wildcards_are_literal`（引号注入不扩大结果，`%`、`_`、`[` 按字面处理）、`test_bad_login_does_not_reveal_account_or_accept_injection`（`' OR 1=1--` 登录被拒）、`test_bad_product_input_is_rejected` 中的注入型 SKU。SQL 只出现在 `app/repositories.py` 和 `sql/` 下，用户输入全部以 `?` 绑定。
- 身份与权限：`test_business_code_cannot_revert_the_restricted_identity`（4 个身份执行 `REVERT` 都回不到 dbo）、`test_database_execution_identity_has_no_owner_or_sensitive_table_access`（3）、`test_database_view_enforces_ownership_without_api_filter`。
- 并发与一致性：`test_concurrent_cart_adds_keep_a_single_draft_and_the_full_quantity`、`test_same_order_settled_twice_deducts_once`、`test_adjust_and_settle_race_keeps_log_chain`。
- 统一异常：`test_request_log_has_trace_role_code_and_result`（请求日志含请求编号、角色、错误码和结果）；`test_sql_connection_failure_is_friendly_and_logged` 另外断言登录密码不出现在日志中。
