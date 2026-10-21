import json
import secrets
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pyodbc
import pytest

from app import create_app
from app.database import one
from app.errors import AppError
from tools.prepare_week7 import administrative_connection


def result(response, status=200, code="OK"):
    assert response.status_code == status, response.json
    assert response.json["code"] == code
    assert set(response.json) == {"ok", "code", "message", "data", "request_id"}
    assert response.headers["X-Request-ID"] == response.json["request_id"]
    return response.json["data"]


def draft(client, items=None):
    return result(client.send("POST", "/orders", {"items": items or []}), 201)


def scalar(settings, sql, *parameters):
    connection = administrative_connection(settings["DB_SERVER"], settings["DB_DATABASE"])
    try:
        return connection.execute(sql, *parameters).fetchone()[0]
    finally:
        connection.close()


def test_public_page_is_served_without_database(client):
    response = client.get("/")
    assert response.status_code == 200
    assert "校园小卖部".encode() in response.data
    assert "frame-ancestors 'none'" in response.headers["Content-Security-Policy"]
    assert client.get("/static/app.js").status_code == 200


@pytest.mark.parametrize("method,path", [("GET", "/products"), ("GET", "/inventory"), ("GET", "/orders"), ("POST", "/orders")])
def test_unauthenticated_requests_are_rejected(client, method, path):
    result(client.open("/api" + path, method=method), 401, "AUTH_REQUIRED")


@pytest.mark.parametrize("username,role", [("admin", "ADMIN"), ("staff", "STAFF"), ("customer", "CUSTOMER")])
def test_roles_come_from_authenticated_account(login, username, role):
    user = login(username)
    assert user.user["role"] == role
    data = result(user.get("/auth/session"))
    assert "password_hash" not in json.dumps(data)
    assert user.client.get_cookie("session").http_only
    assert user.client.get_cookie("session").same_site == "Lax"


@pytest.mark.parametrize("username", ["admin", "does-not-exist", "' OR 1=1--"])
def test_bad_login_does_not_reveal_account_or_accept_injection(client, username):
    token = client.get("/api/auth/session").json["data"]["csrf_token"]
    response = client.post("/api/auth/login", json={"username": username, "password": "wrong-password"},
                           headers={"X-CSRF-Token": token})
    result(response, 401, "AUTH_FAILED")
    assert response.json["message"] == "用户名或密码不正确。"


def test_login_requires_csrf(client):
    result(client.post("/api/auth/login", json={"username": "admin", "password": "Campus2026!"}), 403, "CSRF_INVALID")


def test_write_requires_current_csrf_token(login):
    user = login("admin")
    result(user.client.post("/api/products", json={}), 403, "CSRF_INVALID")


def test_logout_invalidates_access(login):
    user = login("staff")
    result(user.send("POST", "/auth/logout"))
    result(user.get("/orders"), 401, "AUTH_REQUIRED")


def test_read_response_cannot_restore_a_logged_out_cookie(login):
    user = login("admin")
    read = user.get("/inventory")
    result(read)
    assert "Set-Cookie" not in read.headers
    result(user.send("POST", "/auth/logout"))
    result(user.get("/products"), 401, "AUTH_REQUIRED")


def test_unsigned_session_cookie_is_rejected(client):
    client.set_cookie("session", "forged-admin-session")
    result(client.get("/api/products"), 401, "AUTH_REQUIRED")


def test_malformed_json_has_uniform_response(client):
    token = client.get("/api/auth/session").json["data"]["csrf_token"]
    response = client.post("/api/auth/login", data="{bad-json", content_type="application/json",
                           headers={"X-CSRF-Token": token})
    result(response, 400, "INVALID_INPUT")


def test_product_crud_keeps_inventory_consistent(login, product_data, settings):
    admin = login("admin")
    created = result(admin.send("POST", "/products", product_data), 201)
    assert created["quantity"] == 0 and created["sale_price"] == "6.50"
    edited = {**product_data, "product_name": "更新后的文具", "sale_price": "7.20"}
    updated = result(admin.send("PUT", "/products/" + str(created["product_id"]), edited))
    assert updated["product_name"] == edited["product_name"] and updated["status"]
    result(admin.send("DELETE", "/products/" + str(created["product_id"])))
    assert scalar(settings, "SELECT COUNT(*) FROM dbo.Inventory WHERE ProductID=?;", created["product_id"]) == 0


@pytest.mark.parametrize("username", ["staff", "customer"])
def test_product_maintenance_requires_admin(login, product_data, username):
    user = login(username)
    result(user.send("POST", "/products", product_data), 403, "FORBIDDEN")
    result(user.send("PUT", "/products/1", product_data), 403, "FORBIDDEN")
    result(user.send("DELETE", "/products/1"), 403, "FORBIDDEN")


def test_product_duplicate_is_a_friendly_conflict(login, product_data):
    admin = login("admin")
    result(admin.send("POST", "/products", product_data), 201)
    response = admin.send("POST", "/products", product_data)
    result(response, 409, "DUPLICATE_RECORD")
    assert "INSERT" not in response.json["message"] and "SQL Server" not in response.json["message"]


@pytest.mark.parametrize("key,value", [("sale_price", "-1"), ("sale_price", "NaN"), ("sale_price", "1.234"),
                                     ("sale_price", True), ("category_id", True), ("status", 4),
                                     ("sku", "bad' OR 1=1--"), ("product_name", "")])
def test_bad_product_input_is_rejected(login, product_data, key, value):
    result(login("admin").send("POST", "/products", {**product_data, key: value}), 400, "INVALID_INPUT")


def test_invalid_category_uses_database_constraint(login, product_data):
    response = login("admin").send("POST", "/products", {**product_data, "category_id": 99999999})
    result(response, 409, "CONSTRAINT_CONFLICT")


def test_product_with_history_cannot_be_deleted(login):
    result(login("admin").send("DELETE", "/products/1"), 409, "BUSINESS_RULE")


def test_search_is_parameterized_and_wildcards_are_literal(login, product_data):
    admin = login("admin")
    before = result(admin.get("/products"))["total"]
    assert result(admin.get("/products", query_string={"q": "' OR 1=1--"}))["total"] == 0
    assert result(admin.get("/products", query_string={"q": "%"}))["total"] == 0
    assert result(admin.get("/products"))["total"] == before
    product = {**product_data, "product_name": "测试'引号<script>alert(1)</script>"}
    created = result(admin.send("POST", "/products", product), 201)
    assert created["product_name"] == product["product_name"]
    result(admin.send("DELETE", "/products/" + str(created["product_id"])))


@pytest.mark.parametrize("query", [{"page": "0"}, {"page_size": "101"}, {"page": "'"}, {"status": "wrong"}])
def test_invalid_list_parameters_are_rejected(login, query):
    result(login("staff").get("/products", query_string=query), 400, "INVALID_INPUT")


def test_customer_cannot_access_inventory_or_inactive_catalog(login, product_data):
    admin = login("admin")
    created = result(admin.send("POST", "/products", {**product_data, "status": 0}), 201)
    customer = login("customer")
    result(customer.get("/inventory"), 403, "FORBIDDEN")
    result(customer.get("/products", query_string={"status": "all"}), 400, "INVALID_INPUT")
    assert result(customer.get("/products", query_string={"q": product_data["sku"]}))["total"] == 0
    result(admin.send("DELETE", "/products/" + str(created["product_id"])))


def test_inventory_threshold_does_not_change_quantity(login):
    admin = login("admin")
    inventory = result(admin.get("/inventory"))
    before = next(row for row in inventory if row["product_id"] == 1)
    result(admin.send("PATCH", "/inventory/1", {"min_quantity": before["min_quantity"] + 1}))
    after = next(row for row in result(admin.get("/inventory")) if row["product_id"] == 1)
    assert after["quantity"] == before["quantity"]
    result(admin.send("PATCH", "/inventory/1", {"min_quantity": before["min_quantity"]}))
    result(login("staff").send("PATCH", "/inventory/1", {"min_quantity": 2}), 403, "FORBIDDEN")
    result(admin.send("PATCH", "/inventory/1", {"quantity": 100}), 400, "INVALID_INPUT")


def test_customer_draft_ownership_and_price(login, settings):
    customer = login("customer")
    before_quantity = scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;")
    order = draft(customer, [{"product_id": 1, "quantity": 2}])
    assert order["draft_amount"] == "7.00" and order["items"][0]["unit_price"] == "3.50"
    assert order["owner_user_id"] == customer.user["user_id"]
    assert order["employee_id"] != customer.user["user_id"] or scalar(
        settings, "SELECT RoleName FROM dbo.Employee WHERE EmployeeID=?;", order["employee_id"]) == "CASHIER"
    assert scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;") == before_quantity
    assert scalar(settings, "SELECT COUNT(*) FROM dbo.InventoryLog WHERE SaleID=?;", order["sale_id"]) == 0
    other = login("customer2")
    result(other.get("/orders/" + str(order["sale_id"])), 404, "NOT_FOUND")
    result(other.send("PATCH", "/orders/" + str(order["sale_id"]), {"remark": "越权"}), 404, "NOT_FOUND")
    result(other.send("POST", "/orders/" + str(order["sale_id"]) + "/cancel"), 404, "NOT_FOUND")


def test_draft_items_add_update_delete_cancel(login):
    staff = login("staff")
    order = draft(staff)
    path = "/orders/" + str(order["sale_id"])
    added = result(staff.send("POST", path + "/items", {"product_id": 1, "quantity": 2}), 201)
    item = added["items"][0]
    changed = result(staff.send("PATCH", path + "/items/" + str(item["item_id"]), {"quantity": 3}))
    assert changed["draft_amount"] == "10.50"
    result(staff.send("PATCH", path, {"payment_method": "WECHAT", "remark": "课后领取", "discount_amount": "0.50"}))
    assert result(staff.get(path))["remark"] == "课后领取"
    result(staff.send("DELETE", path + "/items/" + str(item["item_id"])))
    assert result(staff.get(path))["items"] == []
    result(staff.send("POST", path + "/cancel"))
    assert result(staff.get(path))["status"] == "CANCELLED"
    result(staff.send("POST", path + "/items", {"product_id": 1, "quantity": 1}), 409, "BUSINESS_RULE")


def test_customer_cannot_override_price_owner_employee_or_status(login):
    user = login("customer")
    result(user.send("POST", "/orders", {"items": [{"product_id": 1, "quantity": 1, "unit_price": "0.01"}]}), 403, "FORBIDDEN")
    for key in ["owner_user_id", "employee_id", "status", "total_amount", "user_id"]:
        result(user.send("POST", "/orders", {key: 1}), 400, "INVALID_INPUT")
    order = draft(user)
    result(user.send("PATCH", "/orders/" + str(order["sale_id"]), {"discount_amount": "1"}), 403, "FORBIDDEN")


@pytest.mark.parametrize("payment", [None, [], {}, False])
def test_invalid_payment_types_are_input_errors(login, payment):
    result(login("staff").send("POST", "/orders", {"payment_method": payment}), 400, "INVALID_INPUT")


def test_order_creation_rolls_back_all_partial_writes(login, settings):
    customer = login("customer")
    before = scalar(settings, "SELECT COUNT(*) FROM dbo.SaleOrder;")
    before_owners = scalar(settings, "SELECT COUNT(*) FROM app.SaleOwner;")
    response = customer.send("POST", "/orders", {"items": [{"product_id": 1, "quantity": 1}, {"product_id": 99999999, "quantity": 1}]})
    result(response, 409, "BUSINESS_RULE")
    assert scalar(settings, "SELECT COUNT(*) FROM dbo.SaleOrder;") == before
    assert scalar(settings, "SELECT COUNT(*) FROM app.SaleOwner;") == before_owners


def test_duplicate_order_lines_roll_back_header_and_first_line(login, settings):
    customer = login("customer")
    before = scalar(settings, "SELECT COUNT(*) FROM dbo.SaleOrder;")
    response = customer.send("POST", "/orders", {"items": [{"product_id": 1, "quantity": 1}, {"product_id": 1, "quantity": 2}]})
    result(response, 409, "DUPLICATE_RECORD")
    assert scalar(settings, "SELECT COUNT(*) FROM dbo.SaleOrder;") == before


def test_completed_orders_reject_mutations(login):
    staff = login("staff")
    order = next(row for row in result(staff.get("/orders", query_string={"status": "COMPLETED"}))["items"])
    path = "/orders/" + str(order["sale_id"])
    result(staff.send("PATCH", path, {"remark": "改历史"}), 409, "BUSINESS_RULE")
    result(staff.send("POST", path + "/cancel"), 409, "BUSINESS_RULE")
    result(staff.send("POST", path + "/items", {"product_id": 1, "quantity": 1}), 409, "BUSINESS_RULE")


@pytest.mark.parametrize("role,username,principal", [("ADMIN", "admin", "WebAdmin"), ("STAFF", "staff", "WebStaff"), ("CUSTOMER", "customer", "WebCustomer")])
def test_database_execution_identity_has_no_owner_or_sensitive_table_access(app, login, role, username, principal):
    user = login(username)
    database = app.extensions["database"]
    with database.transaction(role, user.user["user_id"]) as connection:
        identity = one(connection, "SELECT USER_NAME() AS principal,IS_MEMBER('db_owner') AS owner;")
        assert identity == {"principal": principal, "owner": 0}
    with pytest.raises(pyodbc.Error):
        with database.transaction(role, user.user["user_id"]) as connection:
            connection.execute("SELECT PasswordHash FROM app.AppUser;").fetchall()
    with pytest.raises(pyodbc.Error):
        with database.transaction(role, user.user["user_id"]) as connection:
            connection.execute("UPDATE dbo.Inventory SET Quantity=Quantity+1 WHERE ProductID=1;")


def test_database_view_enforces_ownership_without_api_filter(app, login):
    a, b = login("customer"), login("customer2")
    order_a, order_b = draft(a), draft(b)
    def ids(user):
        with app.extensions["database"].transaction("CUSTOMER", user.user["user_id"]) as connection:
            return {row[0] for row in connection.execute("SELECT sale_id FROM app.v_OrderAccess;").fetchall()}
    with ThreadPoolExecutor(max_workers=2) as executor:
        seen_a, seen_b = list(executor.map(ids, [a, b]))
    assert order_a["sale_id"] in seen_a and order_b["sale_id"] not in seen_a
    assert order_b["sale_id"] in seen_b and order_a["sale_id"] not in seen_b
    with pytest.raises(pyodbc.Error):
        with app.extensions["database"].transaction("CUSTOMER", a.user["user_id"]) as connection:
            connection.execute("EXEC sys.sp_set_session_context @key=N'WebUserID',@value=?,@read_only=1;", b.user["user_id"])


def test_disabled_account_is_rechecked_for_existing_session(login, settings):
    user = login("customer2")
    connection = administrative_connection(settings["DB_SERVER"], settings["DB_DATABASE"])
    try:
        connection.execute("UPDATE app.AppUser SET Status=0 WHERE Username='customer2';")
        result(user.get("/orders"), 401, "AUTH_REQUIRED")
    finally:
        connection.execute("UPDATE app.AppUser SET Status=1 WHERE Username='customer2';")
        connection.close()


def test_sql_connection_failure_is_friendly_and_logged(settings):
    failing = create_app({**settings, "DB_SERVER": "tcp:127.0.0.1,1", "DB_TIMEOUT": 1,
                          "LOG_PATH": str(Path(settings["LOG_PATH"]).with_name("connection-failure.jsonl"))})
    client = failing.test_client()
    token = client.get("/api/auth/session").json["data"]["csrf_token"]
    response = client.post("/api/auth/login", json={"username": "admin", "password": "not-in-logs"},
                           headers={"X-CSRF-Token": token})
    result(response, 503, "DATABASE_UNAVAILABLE")
    payload = response.get_data(as_text=True)
    assert all(word not in payload for word in ["ODBC", "SQL Server", "tcp:", "Traceback", "SELECT"])
    for handler in failing.extensions["audit_logger"].handlers:
        handler.flush()
    log = Path(failing.config["LOG_PATH"]).read_text(encoding="utf-8")
    assert response.json["request_id"] in log and "database_error" in log and "not-in-logs" not in log
    for handler in failing.extensions["audit_logger"].handlers:
        handler.close()


def test_unknown_endpoint_and_invalid_method_share_error_format(login):
    user = login("admin")
    result(user.get("/does-not-exist"), 404, "NOT_FOUND")
    result(user.send("PATCH", "/products"), 405, "METHOD_NOT_ALLOWED")


@pytest.mark.parametrize("method,path", [
    ("GET", "/orders/9223372036854775808"),
    ("DELETE", "/products/0"),
    ("PATCH", "/orders/1/items/9999999999999999999999999999"),
])
def test_path_identifiers_are_bounded_before_database_access(login, method, path):
    result(login("admin").send(method, path, {"quantity": 1}), 400, "INVALID_INPUT")


def test_request_log_has_trace_role_code_and_result(app, login):
    user = login("customer")
    response = user.get("/inventory")
    for handler in app.extensions["audit_logger"].handlers:
        handler.flush()
    logs = [json.loads(line) for line in Path(app.config["LOG_PATH"]).read_text(encoding="utf-8").splitlines()]
    event = next(row for row in logs if row.get("event") == "request" and row.get("request_id") == response.json["request_id"])
    assert event["role"] == "CUSTOMER" and event["error_code"] == "FORBIDDEN" and event["result"] == "failure"
    assert "time" in event and "operation" in event
