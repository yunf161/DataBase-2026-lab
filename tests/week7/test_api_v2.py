"""提交、结算、购物车和库存调整接口：全部走真实 HTTP 响应，并核对数据库最终状态。"""
import json
import secrets
from concurrent.futures import ThreadPoolExecutor

import pytest
from werkzeug.security import generate_password_hash

from test_application import result, scalar
from tools.prepare_week7 import DEMO_PASSWORD, administrative_connection

LEAKS = ("SQL", "ODBC", "dbo.", "Traceback")
ORDER_KEYS = {"sale_id", "sale_no", "status", "employee_id", "payment_method", "discount_amount",
              "total_amount", "payable_amount", "draft_amount", "remark", "created_at", "owner_user_id",
              "submitted_at", "is_customer_order", "items"}
ITEM_KEYS = {"item_id", "sale_id", "product_id", "sku", "product_name", "quantity", "unit_price", "line_amount"}
LOG_KEYS = {"log_id", "product_id", "sku", "product_name", "change_type", "change_quantity", "before_quantity",
            "after_quantity", "business_no", "employee_no", "remark", "created_at"}


def failure(response, status, code):
    """失败响应统一信封，且不能把 SQL、驱动、对象名或堆栈带给用户。"""
    result(response, status, code)
    assert response.json["ok"] is False and response.json["data"] is None
    payload = response.get_data(as_text=True)
    assert all(word not in payload for word in LEAKS), payload
    return response.json["message"]


@pytest.fixture
def new_customer(settings, login):
    def make():
        username = "buyer_" + secrets.token_hex(4)
        connection = administrative_connection(settings["DB_SERVER"], settings["DB_DATABASE"])
        try:
            connection.execute(
                "INSERT app.AppUser(Username,PasswordHash,DisplayName,RoleName,EmployeeID) VALUES(?,?,?,?,NULL);",
                username, generate_password_hash(DEMO_PASSWORD), "测试顾客", "CUSTOMER")
        finally:
            connection.close()
        return login(username)
    return make


@pytest.fixture
def stocked(login, product_data):
    admin = login("admin")

    def make(stock=10, price="6.50"):
        created = result(admin.send("POST", "/products", {
            **product_data, "sku": "A" + secrets.token_hex(6), "sale_price": price}), 201)
        if stock:
            result(admin.send("PATCH", f"/inventory/{created['product_id']}/quantity",
                              {"new_quantity": stock, "reason": "测试备货"}))
        return created["product_id"]
    return make


def add(user, product_id, quantity=1):
    return result(user.send("POST", "/cart/items", {"product_id": product_id, "quantity": quantity}))


def submitted(user, product_id, quantity=1):
    sale_id = add(user, product_id, quantity)["sale_id"]
    result(user.send("POST", f"/orders/{sale_id}/submit"))
    return sale_id


def drafts(user):
    return result(user.get("/orders", query_string={"status": "DRAFT"}))


def stock(settings, product_id):
    return scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=?;", product_id)


def logs(admin, product_id, **query):
    return result(admin.get(f"/inventory/{product_id}/logs", query_string=query))


ENDPOINTS = [
    ("POST", "/orders/1/submit", {}, "customer", {"admin", "staff"}),
    ("POST", "/orders/1/settle", {}, "staff", {"customer"}),
    ("POST", "/cart/items", {"product_id": 1, "quantity": 1}, "customer", set()),
    ("PATCH", "/inventory/1/quantity", {"new_quantity": 5, "reason": "x"}, "admin", {"staff", "customer"}),
    ("GET", "/inventory/1/logs", None, "admin", {"staff", "customer"}),
]
IDS = [f"{method}-{path}" for method, path, *_ in ENDPOINTS]


# ---------- 通用：401 / 403 / CSRF ----------

@pytest.mark.parametrize("method,path,body,allowed,denied", ENDPOINTS, ids=IDS)
def test_anonymous_requests_are_rejected(client, method, path, body, allowed, denied):
    failure(client.open("/api" + path, method=method, json=body), 401, "AUTH_REQUIRED")


@pytest.mark.parametrize("method,path,body,allowed,denied", ENDPOINTS, ids=IDS)
def test_unauthorised_roles_are_forbidden(login, method, path, body, allowed, denied):
    for username in denied:
        user = login(username)
        response = user.get(path) if method == "GET" else user.send(method, path, body)
        failure(response, 403, "FORBIDDEN")


@pytest.mark.parametrize("method,path,body,allowed,denied", [row for row in ENDPOINTS if row[0] != "GET"],
                         ids=[i for i, row in zip(IDS, ENDPOINTS) if row[0] != "GET"])
def test_writes_without_csrf_token_are_rejected(login, method, path, body, allowed, denied):
    user = login(allowed)
    failure(user.client.open("/api" + path, method=method, json=body), 403, "CSRF_INVALID")
    failure(user.client.open("/api" + path, method=method, json=body,
                             headers={"X-CSRF-Token": "forged"}), 403, "CSRF_INVALID")


# ---------- POST /orders/<id>/submit ----------

def test_submit_succeeds_and_returns_the_submitted_order(new_customer, stocked, settings):
    customer, product_id = new_customer(), stocked(10)
    sale_id = add(customer, product_id, 2)["sale_id"]
    response = customer.send("POST", f"/orders/{sale_id}/submit")
    data = result(response)
    assert response.json["message"] == "订单已提交，请等待店员受理。"
    assert set(data) == {"submitted", "price_changed", "order"}
    assert data["submitted"] is True and data["price_changed"] is False
    order = data["order"]
    assert set(order) == ORDER_KEYS and set(order["items"][0]) == ITEM_KEYS
    assert order["sale_id"] == sale_id and order["status"] == "DRAFT" and order["submitted_at"]
    assert stock(settings, product_id) == 10


def test_submit_with_changed_price_returns_latest_order_and_needs_confirmation(login, new_customer, stocked, product_data):
    admin, customer, product_id = login("admin"), new_customer(), stocked(10, "6.50")
    sale_id = add(customer, product_id, 2)["sale_id"]
    sku = result(admin.get("/products", query_string={"q": "A", "status": "all", "page_size": "100"}))
    sku = next(row["sku"] for row in sku["items"] if row["product_id"] == product_id)
    result(admin.send("PUT", f"/products/{product_id}", {**product_data, "sku": sku, "sale_price": "8.00"}))
    response = customer.send("POST", f"/orders/{sale_id}/submit")
    data = result(response)
    assert response.json["message"] == "部分商品价格已更新，请确认后重新提交。"
    assert data["price_changed"] is True and data["submitted"] is False
    assert data["order"]["items"][0]["unit_price"] == "8.00" and data["order"]["draft_amount"] == "16.00"
    assert data["order"]["submitted_at"] is None
    again = result(customer.send("POST", f"/orders/{sale_id}/submit"))
    assert again["submitted"] is True and again["price_changed"] is False and again["order"]["submitted_at"]


def test_submit_rejects_resubmission_empty_order_and_stale_orders(new_customer, stocked):
    customer, product_id = new_customer(), stocked(10)
    sale_id = submitted(customer, product_id)
    assert "已提交" in failure(customer.send("POST", f"/orders/{sale_id}/submit"), 409, "BUSINESS_RULE")
    empty = result(customer.send("POST", "/orders", {}), 201)["sale_id"]
    assert "没有商品" in failure(customer.send("POST", f"/orders/{empty}/submit"), 409, "BUSINESS_RULE")
    result(customer.send("POST", f"/orders/{sale_id}/cancel"))
    failure(customer.send("POST", f"/orders/{sale_id}/submit"), 409, "BUSINESS_RULE")


def test_submit_rejects_insufficient_stock_without_marking_submitted(new_customer, stocked):
    customer, product_id = new_customer(), stocked(1)
    sale_id = add(customer, product_id, 2)["sale_id"]
    assert "库存不足" in failure(customer.send("POST", f"/orders/{sale_id}/submit"), 409, "BUSINESS_RULE")
    assert result(customer.get(f"/orders/{sale_id}"))["submitted_at"] is None


def test_other_customer_cannot_submit_or_see_the_order(new_customer, stocked):
    owner, other = new_customer(), new_customer()
    sale_id = add(owner, stocked(10))["sale_id"]
    failure(other.send("POST", f"/orders/{sale_id}/submit"), 404, "NOT_FOUND")
    failure(other.get(f"/orders/{sale_id}"), 404, "NOT_FOUND")
    assert result(owner.get(f"/orders/{sale_id}"))["submitted_at"] is None
    failure(owner.send("POST", "/orders/999999999/submit"), 404, "NOT_FOUND")


# ---------- POST /orders/<id>/settle ----------

def test_staff_settles_a_submitted_order_with_payment_and_discount(login, new_customer, stocked, settings):
    admin, staff, customer, product_id = login("admin"), login("staff"), new_customer(), stocked(10)
    sale_id = submitted(customer, product_id, 2)
    response = staff.send("POST", f"/orders/{sale_id}/settle", {"payment_method": "ALIPAY", "discount_amount": "1.50"})
    order = result(response)
    assert response.json["message"] == "订单已结算，库存已扣减。"
    assert set(order) == ORDER_KEYS
    assert order["status"] == "COMPLETED" and order["payment_method"] == "ALIPAY"
    assert order["discount_amount"] == "1.50" and order["total_amount"] == "13.00" and order["payable_amount"] == "11.50"
    assert order["owner_user_id"] == customer.user["user_id"]
    assert scalar(settings, "SELECT EmployeeNo FROM dbo.Employee WHERE EmployeeID=?;", order["employee_id"]) == "E003"
    assert stock(settings, product_id) == 8
    latest = logs(admin, product_id)["items"][0]
    assert latest["change_type"] == "SALE_OUT" and latest["change_quantity"] == -2
    assert latest["business_no"] == order["sale_no"] and latest["employee_no"] == "E003"
    assert result(customer.get(f"/orders/{sale_id}"))["status"] == "COMPLETED"
    failure(staff.send("POST", f"/orders/{sale_id}/settle"), 409, "BUSINESS_RULE")
    assert stock(settings, product_id) == 8


def test_admin_settles_a_staff_order_without_changes(login, stocked, settings):
    admin, staff, product_id = login("admin"), login("staff"), stocked(10)
    sale_id = result(staff.send("POST", "/orders", {"items": [{"product_id": product_id, "quantity": 3}],
                                                    "payment_method": "WECHAT"}), 201)["sale_id"]
    order = result(admin.send("POST", f"/orders/{sale_id}/settle", {}))
    assert order["status"] == "COMPLETED" and order["payment_method"] == "WECHAT" and order["discount_amount"] == "0.00"
    assert stock(settings, product_id) == 7


def test_settle_with_insufficient_stock_rolls_back_payment_and_discount(login, stocked, settings):
    admin, staff, product_id = login("admin"), login("staff"), stocked(5)
    sale_id = result(staff.send("POST", "/orders", {"items": [{"product_id": product_id, "quantity": 4}]}), 201)["sale_id"]
    result(admin.send("PATCH", f"/inventory/{product_id}/quantity", {"new_quantity": 1, "reason": "盘点减少"}))
    data = {"payment_method": "WECHAT", "discount_amount": "1.00"}
    assert "库存不足" in failure(staff.send("POST", f"/orders/{sale_id}/settle", data), 409, "BUSINESS_RULE")
    order = result(staff.get(f"/orders/{sale_id}"))
    assert (order["status"], order["payment_method"], order["discount_amount"]) == ("DRAFT", "CASH", "0.00")
    assert stock(settings, product_id) == 1
    assert [row["change_type"] for row in logs(admin, product_id)["items"]] == ["STOCKTAKE_OUT", "STOCKTAKE_IN"]
    result(admin.send("PATCH", f"/inventory/{product_id}/quantity", {"new_quantity": 5, "reason": "补货"}))
    done = result(staff.send("POST", f"/orders/{sale_id}/settle", data))
    assert (done["status"], done["payment_method"], done["payable_amount"]) == ("COMPLETED", "WECHAT", "25.00")
    assert stock(settings, product_id) == 1


def test_settle_of_unsubmitted_customer_order_is_rejected_and_rolled_back(login, new_customer, stocked):
    staff, customer = login("staff"), new_customer()
    sale_id = add(customer, stocked(10))["sale_id"]
    failure(staff.send("POST", f"/orders/{sale_id}/settle", {"payment_method": "ALIPAY", "discount_amount": "1.00"}),
            409, "BUSINESS_RULE")
    order = result(staff.get(f"/orders/{sale_id}"))
    assert (order["status"], order["payment_method"], order["discount_amount"]) == ("DRAFT", "CASH", "0.00")


def test_settle_rejects_discount_above_total_and_keeps_the_draft(login, stocked, settings):
    staff, product_id = login("staff"), stocked(10)
    sale_id = result(staff.send("POST", "/orders", {"items": [{"product_id": product_id, "quantity": 1}]}), 201)["sale_id"]
    failure(staff.send("POST", f"/orders/{sale_id}/settle", {"discount_amount": "100.00"}), 409, "BUSINESS_RULE")
    assert result(staff.get(f"/orders/{sale_id}"))["discount_amount"] == "0.00" and stock(settings, product_id) == 10


@pytest.mark.parametrize("data", [
    {"payment_method": "CHEQUE"}, {"payment_method": None}, {"payment_method": 1}, {"payment_method": ["CASH"]},
    {"discount_amount": "abc"}, {"discount_amount": "-1"}, {"discount_amount": "1.234"}, {"discount_amount": True},
    {"discount_amount": None}, {"discount_amount": "10000000000.00"},
    {"remark": "x"}, {"status": "COMPLETED"}, {"total_amount": "0"}, {"unknown": 1},
])
def test_settle_rejects_bad_input_before_changing_anything(login, stocked, settings, data):
    staff, product_id = login("staff"), stocked(10)
    sale_id = result(staff.send("POST", "/orders", {"items": [{"product_id": product_id, "quantity": 1}]}), 201)["sale_id"]
    failure(staff.send("POST", f"/orders/{sale_id}/settle", data), 400, "INVALID_INPUT")
    assert result(staff.get(f"/orders/{sale_id}"))["status"] == "DRAFT" and stock(settings, product_id) == 10


def test_customer_and_missing_orders_cannot_be_settled(login, new_customer, stocked):
    staff, customer, other = login("staff"), new_customer(), new_customer()
    sale_id = submitted(customer, stocked(10))
    failure(other.send("POST", f"/orders/{sale_id}/settle"), 403, "FORBIDDEN")
    failure(customer.send("POST", f"/orders/{sale_id}/settle"), 403, "FORBIDDEN")
    failure(staff.send("POST", "/orders/999999999/settle"), 404, "NOT_FOUND")


# ---------- POST /cart/items ----------

def test_cart_creates_a_draft_and_returns_the_order(new_customer, stocked, settings):
    customer, product_id = new_customer(), stocked(10)
    response = customer.send("POST", "/cart/items", {"product_id": product_id, "quantity": 2})
    order = result(response)
    assert response.json["message"] == "商品已加入购物车。"
    assert set(order) == ORDER_KEYS and set(order["items"][0]) == ITEM_KEYS
    assert order["status"] == "DRAFT" and order["submitted_at"] is None
    assert order["owner_user_id"] == customer.user["user_id"] and order["is_customer_order"] == 1
    assert [(i["product_id"], i["quantity"], i["unit_price"]) for i in order["items"]] == [(product_id, 2, "6.50")]
    assert order["draft_amount"] == "13.00" and stock(settings, product_id) == 10


def test_same_product_added_twice_merges_into_one_line_of_one_draft(new_customer, stocked):
    customer, first, second = new_customer(), stocked(10), stocked(10)
    one = add(customer, first, 2)
    two = add(customer, first, 3)
    assert two["sale_id"] == one["sale_id"]
    assert [(i["product_id"], i["quantity"]) for i in two["items"]] == [(first, 5)]
    three = add(customer, second, 1)
    assert three["sale_id"] == one["sale_id"] and len(three["items"]) == 2
    listing = drafts(customer)
    assert listing["total"] == 1 and listing["items"][0]["sale_id"] == one["sale_id"]
    assert result(customer.get(f"/orders/{one['sale_id']}"))["draft_amount"] == "39.00"


def test_adding_after_submit_starts_a_new_draft_and_leaves_the_submitted_order(new_customer, stocked):
    customer, product_id = new_customer(), stocked(10)
    old = submitted(customer, product_id, 2)
    before = result(customer.get(f"/orders/{old}"))
    fresh = add(customer, product_id, 1)
    assert fresh["sale_id"] != old and fresh["submitted_at"] is None
    assert [(i["product_id"], i["quantity"]) for i in fresh["items"]] == [(product_id, 1)]
    assert result(customer.get(f"/orders/{old}")) == before
    assert drafts(customer)["total"] == 2
    assert add(customer, product_id, 4)["sale_id"] == fresh["sale_id"]


def test_cart_is_private_to_each_customer(new_customer, stocked):
    first, second, product_id = new_customer(), new_customer(), stocked(10)
    mine, theirs = add(first, product_id), add(second, product_id)
    assert mine["sale_id"] != theirs["sale_id"]
    failure(second.get(f"/orders/{mine['sale_id']}"), 404, "NOT_FOUND")
    assert drafts(second)["total"] == 1


def test_staff_cart_belongs_to_the_staff_account(login, stocked, settings):
    staff, product_id = login("staff"), stocked(10)
    order = add(staff, product_id, 2)
    assert order["owner_user_id"] == staff.user["user_id"] and order["is_customer_order"] == 0
    assert scalar(settings, "SELECT EmployeeNo FROM dbo.Employee WHERE EmployeeID=?;", order["employee_id"]) == "E003"
    assert add(staff, product_id, 1)["sale_id"] == order["sale_id"]
    result(staff.send("POST", f"/orders/{order['sale_id']}/cancel"))


def test_cart_rejects_quantity_beyond_the_limit_and_keeps_the_line(new_customer, stocked):
    customer, product_id = new_customer(), stocked(10)
    sale_id = add(customer, product_id, 1000000)["sale_id"]
    failure(customer.send("POST", "/cart/items", {"product_id": product_id, "quantity": 1}), 400, "INVALID_INPUT")
    order = result(customer.get(f"/orders/{sale_id}"))
    assert [(i["quantity"]) for i in order["items"]] == [1000000]


def test_cart_with_unavailable_product_does_not_leave_an_empty_draft(login, new_customer, stocked, product_data):
    admin, customer, product_id = login("admin"), new_customer(), stocked(10)
    sku = next(row["sku"] for row in result(admin.get("/products", query_string={
        "q": "A", "status": "all", "page_size": "100"}))["items"] if row["product_id"] == product_id)
    result(admin.send("PUT", f"/products/{product_id}", {**product_data, "sku": sku, "status": 0}))
    failure(customer.send("POST", "/cart/items", {"product_id": product_id, "quantity": 1}), 409, "BUSINESS_RULE")
    failure(customer.send("POST", "/cart/items", {"product_id": 999999999, "quantity": 1}), 409, "BUSINESS_RULE")
    assert drafts(customer)["total"] == 0


@pytest.mark.parametrize("data", [
    {"product_id": "1", "quantity": 1}, {"product_id": True, "quantity": 1}, {"product_id": 1.5, "quantity": 1},
    {"product_id": 0, "quantity": 1}, {"product_id": None, "quantity": 1},
    {"product_id": 1, "quantity": "1"}, {"product_id": 1, "quantity": True}, {"product_id": 1, "quantity": 1.0},
    {"product_id": 1, "quantity": 0}, {"product_id": 1, "quantity": -1}, {"product_id": 1, "quantity": 1000001},
    {"product_id": 1}, {"quantity": 1}, {},
    {"product_id": 1, "quantity": 1, "unit_price": "0.01"}, {"product_id": 1, "quantity": 1, "sale_id": 1},
])
def test_cart_rejects_bad_input_without_creating_a_draft(new_customer, data):
    customer = new_customer()
    failure(customer.send("POST", "/cart/items", data), 400, "INVALID_INPUT")
    assert drafts(customer)["total"] == 0


def test_concurrent_cart_adds_keep_a_single_draft_and_the_full_quantity(login, new_customer, stocked):
    first, product_id = new_customer(), stocked(10)
    sessions = [first] + [login(first.user["username"]) for _ in range(3)]
    with ThreadPoolExecutor(len(sessions)) as pool:
        responses = list(pool.map(lambda user: user.send(
            "POST", "/cart/items", {"product_id": product_id, "quantity": 1}), sessions))
    for response in responses:
        result(response)
    listing = drafts(first)
    assert listing["total"] == 1
    order = result(first.get(f"/orders/{listing['items'][0]['sale_id']}"))
    assert [(i["product_id"], i["quantity"]) for i in order["items"]] == [(product_id, 4)]


# ---------- PATCH /inventory/<id>/quantity ----------

def test_adjust_inventory_returns_new_quantity_and_writes_a_log(login, stocked, settings):
    admin, product_id = login("admin"), stocked(10)
    response = admin.send("PATCH", f"/inventory/{product_id}/quantity", {"new_quantity": 14, "reason": "  盘点盘盈  "})
    data = result(response)
    assert response.json["message"] == "库存数量已调整。"
    assert data == {"product_id": product_id, "quantity": 14}
    assert stock(settings, product_id) == 14
    row = next(r for r in result(admin.get("/inventory", query_string={"q": ""})) if r["product_id"] == product_id)
    assert row["quantity"] == 14
    latest = logs(admin, product_id)["items"][0]
    assert (latest["change_type"], latest["change_quantity"], latest["before_quantity"], latest["after_quantity"]) == (
        "STOCKTAKE_IN", 4, 10, 14)
    assert latest["remark"] == "盘点盘盈" and latest["employee_no"] == "E001" and latest["business_no"] is None
    result(admin.send("PATCH", f"/inventory/{product_id}/quantity", {"new_quantity": 0, "reason": "清零"}))
    assert stock(settings, product_id) == 0
    result(admin.send("PATCH", f"/inventory/{product_id}/quantity", {"new_quantity": 1000000, "reason": "上限"}))
    assert stock(settings, product_id) == 1000000


def test_adjust_inventory_rejects_unchanged_quantity_and_unknown_product(login, stocked):
    admin, product_id = login("admin"), stocked(10)
    assert "没有变化" in failure(admin.send("PATCH", f"/inventory/{product_id}/quantity",
                                           {"new_quantity": 10, "reason": "x"}), 409, "BUSINESS_RULE")
    failure(admin.send("PATCH", "/inventory/999999999/quantity", {"new_quantity": 1, "reason": "x"}), 404, "NOT_FOUND")


@pytest.mark.parametrize("data", [
    {"new_quantity": "5", "reason": "x"}, {"new_quantity": True, "reason": "x"}, {"new_quantity": 5.5, "reason": "x"},
    {"new_quantity": 5.0, "reason": "x"}, {"new_quantity": None, "reason": "x"},
    {"new_quantity": -1, "reason": "x"}, {"new_quantity": 1000001, "reason": "x"},
    {"new_quantity": 5}, {"reason": "x"}, {},
    {"new_quantity": 5, "reason": ""}, {"new_quantity": 5, "reason": "   "},
    {"new_quantity": 5, "reason": "\t\n \u3000"}, {"new_quantity": 5, "reason": None},
    {"new_quantity": 5, "reason": 123}, {"new_quantity": 5, "reason": ["x"]},
    {"new_quantity": 5, "reason": "x", "quantity": 5}, {"new_quantity": 5, "reason": "x", "min_quantity": 1},
    {"new_quantity": 5, "reason": "a\u0000b"},
], ids=lambda data: json.dumps(data, ensure_ascii=True)[:60])
def test_adjust_inventory_rejects_bad_input_without_changes(login, stocked, settings, data):
    admin, product_id = login("admin"), stocked(10)
    failure(admin.send("PATCH", f"/inventory/{product_id}/quantity", data), 400, "INVALID_INPUT")
    assert stock(settings, product_id) == 10 and logs(admin, product_id)["total"] == 1


def test_adjust_inventory_rejects_a_lone_surrogate_in_the_reason(login, stocked, settings):
    admin, product_id = login("admin"), stocked(10)
    response = admin.client.patch(f"/api/inventory/{product_id}/quantity", headers={"X-CSRF-Token": admin.token},
                                  data='{"new_quantity": 3, "reason": "\\ud83d"}', content_type="application/json")
    failure(response, 400, "INVALID_INPUT")
    assert stock(settings, product_id) == 10


@pytest.mark.parametrize("reason,label", [("汉" * 256, "256个汉字"), ("😀" * 128, "128个emoji"),
                                         ("😀" * 127 + "字" + "x", "256单位"), (" " * 3 + "汉" * 256, "空格后256个汉字")])
def test_overlong_reason_is_rejected_by_utf16_length(login, stocked, settings, reason, label):
    admin, product_id = login("admin"), stocked(10)
    failure(admin.send("PATCH", f"/inventory/{product_id}/quantity", {"new_quantity": 3, "reason": reason}),
            400, "INVALID_INPUT")
    assert stock(settings, product_id) == 10 and logs(admin, product_id)["total"] == 1


@pytest.mark.parametrize("reason", ["😀" * 127 + "字", "汉" * 255, "😀" * 127 + "字 "])
def test_reason_of_255_utf16_units_is_saved_completely(login, stocked, settings, reason):
    admin, product_id = login("admin"), stocked(10)
    result(admin.send("PATCH", f"/inventory/{product_id}/quantity", {"new_quantity": 3, "reason": reason}))
    saved = scalar(settings, "SELECT Remark FROM dbo.InventoryLog WHERE ProductID=? AND AfterQuantity=3;", product_id)
    assert saved == reason.strip() and len(saved.encode("utf-16-le")) // 2 == 255
    assert logs(admin, product_id)["items"][0]["remark"] == reason.strip()


# ---------- GET /inventory/<id>/logs ----------

def test_inventory_logs_are_paginated_newest_first_and_per_product(login, stocked):
    admin, product_id, other = login("admin"), stocked(10), stocked(10)
    for quantity in (12, 7, 9):
        result(admin.send("PATCH", f"/inventory/{product_id}/quantity", {"new_quantity": quantity, "reason": f"调整{quantity}"}))
    page = logs(admin, product_id)
    assert set(page) == {"items", "total", "page", "page_size"} and (page["total"], page["page"], page["page_size"]) == (4, 1, 20)
    assert all(set(row) == LOG_KEYS and row["product_id"] == product_id for row in page["items"])
    assert [row["after_quantity"] for row in page["items"]] == [9, 7, 12, 10]
    assert [row["remark"] for row in page["items"]][:3] == ["调整9", "调整7", "调整12"]
    second = logs(admin, product_id, page="2", page_size="3")
    assert (second["total"], second["page"], second["page_size"]) == (4, 2, 3)
    assert [row["after_quantity"] for row in second["items"]] == [10]
    assert logs(admin, product_id, page="3", page_size="3")["items"] == []
    assert logs(admin, other)["total"] == 1


def test_inventory_logs_reject_bad_parameters_and_unknown_products(login, stocked):
    admin, product_id = login("admin"), stocked(10)
    for query in ({"page": "0"}, {"page": "x"}, {"page": "'"}, {"page_size": "0"}, {"page_size": "101"}, {"page_size": "-1"}):
        failure(admin.get(f"/inventory/{product_id}/logs", query_string=query), 400, "INVALID_INPUT")
    failure(admin.get("/inventory/999999999/logs"), 404, "NOT_FOUND")


def test_existing_minimum_update_still_works_next_to_the_quantity_route(login, stocked, settings):
    admin, product_id = login("admin"), stocked(10)
    assert result(admin.send("PATCH", f"/inventory/{product_id}", {"min_quantity": 3})) == {
        "product_id": product_id, "min_quantity": 3}
    assert stock(settings, product_id) == 10
    failure(admin.send("PATCH", f"/inventory/{product_id}", {"new_quantity": 3, "reason": "x"}), 400, "INVALID_INPUT")


# ---------- GET /orders?pending=1 ----------

def test_pending_filter_returns_only_submitted_drafts(login, new_customer, stocked):
    staff, customer, other, product_id = login("staff"), new_customer(), new_customer(), stocked(20)
    waiting = submitted(customer, product_id)
    unsubmitted = add(customer, product_id)["sale_id"]
    done = submitted(customer, product_id)
    result(staff.send("POST", f"/orders/{done}/settle", {}))
    cancelled = submitted(customer, product_id)
    result(customer.send("POST", f"/orders/{cancelled}/cancel"))
    numbers = {sale: result(staff.get(f"/orders/{sale}"))["sale_no"] for sale in (waiting, unsubmitted, done, cancelled)}

    def pending(user, sale, **extra):
        return result(user.get("/orders", query_string={"pending": "1", "q": numbers[sale], **extra}))

    found = pending(staff, waiting)
    assert found["total"] == 1 and found["items"][0]["sale_id"] == waiting
    assert (found["items"][0]["status"], bool(found["items"][0]["submitted_at"])) == ("DRAFT", True)
    for sale in (unsubmitted, done, cancelled):
        assert pending(staff, sale)["total"] == 0
    assert pending(customer, waiting)["total"] == 1 and pending(other, waiting)["total"] == 0
    assert pending(staff, waiting, status="COMPLETED")["total"] == 0
    everything = result(staff.get("/orders", query_string={"pending": "1", "page_size": "100"}))
    assert everything["items"] and all(row["status"] == "DRAFT" and row["submitted_at"] for row in everything["items"])
    unfiltered = result(staff.get("/orders", query_string={"q": numbers[unsubmitted]}))
    assert unfiltered["total"] == 1


@pytest.mark.parametrize("value", ["2", "0", "", "true", "-1", "1 ", "01", "yes"])
def test_pending_filter_rejects_other_values(login, value):
    for username in ("staff", "customer"):
        failure(login(username).get("/orders", query_string={"pending": value}), 400, "INVALID_INPUT")


# ---------- PATCH /orders/<id> 顾客改备注的回归 ----------

def test_customer_can_edit_remark_and_payment_after_staff_sets_a_discount(login, new_customer, stocked):
    staff, customer = login("staff"), new_customer()
    sale_id = add(customer, stocked(10))["sale_id"]
    path = f"/orders/{sale_id}"
    result(staff.send("PATCH", path, {"discount_amount": "1.00"}))
    edited = result(customer.send("PATCH", path, {"remark": "放前台"}))
    assert (edited["remark"], edited["discount_amount"]) == ("放前台", "1.00")
    edited = result(customer.send("PATCH", path, {"payment_method": "ALIPAY"}))
    assert (edited["payment_method"], edited["remark"], edited["discount_amount"]) == ("ALIPAY", "放前台", "1.00")
    assert result(customer.send("PATCH", path, {"discount_amount": "1.00", "remark": "再改"}))["remark"] == "再改"
    for discount in ("2.00", "0.00", "0", 0):
        failure(customer.send("PATCH", path, {"discount_amount": discount, "remark": "越权"}), 403, "FORBIDDEN")
    after = result(customer.get(path))
    assert (after["remark"], after["discount_amount"]) == ("再改", "1.00")


def test_customer_without_discount_can_still_edit_and_cannot_set_one(login, new_customer, stocked):
    customer = new_customer()
    sale_id = add(customer, stocked(10))["sale_id"]
    path = f"/orders/{sale_id}"
    assert result(customer.send("PATCH", path, {"remark": "备注"}))["remark"] == "备注"
    assert result(customer.send("PATCH", path, {"discount_amount": "0.00"}))["discount_amount"] == "0.00"
    failure(customer.send("PATCH", path, {"discount_amount": "0.50"}), 403, "FORBIDDEN")
    long_remark = "😀" * 128
    failure(customer.send("PATCH", path, {"remark": long_remark}), 400, "INVALID_INPUT")
    assert result(customer.send("PATCH", path, {"remark": "😀" * 127 + "字"}))["remark"] == "😀" * 127 + "字"
