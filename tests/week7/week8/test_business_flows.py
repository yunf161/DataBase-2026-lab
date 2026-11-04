"""第八周真实数据库流程：先写行为断言，再接入受限业务过程。"""

import pyodbc
import pytest

from app.config import ROOT
from tools.prepare_week7 import administrative_connection, run_script


def result(response, status=200, code="OK"):
    assert response.status_code == status, response.json
    assert response.json["code"] == code
    return response.json["data"]


def scalar(settings, sql, *parameters):
    connection = administrative_connection(settings["DB_SERVER"], settings["DB_DATABASE"])
    try:
        return connection.execute(sql, *parameters).fetchone()[0]
    finally:
        connection.close()


def test_admin_confirms_two_product_purchase(login, settings):
    admin = login("admin")
    before_cola = scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;")
    before_paper = scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=2;")
    order = result(admin.send("POST", "/purchases", {
        "supplier_id": 1,
        "items": [
            {"product_id": 1, "quantity": 3, "unit_cost": "2.00"},
            {"product_id": 2, "quantity": 4, "unit_cost": "1.50"},
        ],
    }), 201)
    purchase_id = order["purchase_id"]
    assert order["status"] == "DRAFT" and len(order["items"]) == 2
    assert scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;") == before_cola

    received = result(admin.send("POST", f"/purchases/{purchase_id}/confirm"))
    assert received["status"] == "RECEIVED" and received["total_amount"] == "12.00"
    assert scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;") == before_cola + 3
    assert scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=2;") == before_paper + 4
    assert scalar(settings, "SELECT COUNT(*) FROM dbo.InventoryLog WHERE PurchaseID=?;", purchase_id) == 2
    result(admin.send("POST", f"/purchases/{purchase_id}/confirm"), 409, "BUSINESS_RULE")


def test_purchase_creation_rolls_back_and_rejects_other_roles(login, settings):
    admin = login("admin")
    before = scalar(settings, "SELECT COUNT(*) FROM dbo.PurchaseOrder;")
    response = admin.send("POST", "/purchases", {"supplier_id": 1, "items": [
        {"product_id": 1, "quantity": 1, "unit_cost": "2.00"},
        {"product_id": 99999999, "quantity": 1, "unit_cost": "1.00"},
    ]})
    result(response, 409, "BUSINESS_RULE")
    assert scalar(settings, "SELECT COUNT(*) FROM dbo.PurchaseOrder;") == before
    for username in ("staff", "customer"):
        user = login(username)
        result(user.get("/purchases"), 403, "FORBIDDEN")
        result(user.send("POST", "/purchases", {"supplier_id": 1}), 403, "FORBIDDEN")


def test_purchase_draft_items_can_change_only_before_confirmation(login):
    admin = login("admin")
    order = result(admin.send("POST", "/purchases", {"supplier_id": 1}), 201)
    path = f"/purchases/{order['purchase_id']}"
    result(admin.send("POST", path + "/confirm"), 409, "BUSINESS_RULE")
    added = result(admin.send("POST", path + "/items", {
        "product_id": 1, "quantity": 2, "unit_cost": "2.20"
    }), 201)
    item_id = added["items"][0]["item_id"]
    updated = result(admin.send("PATCH", path + f"/items/{item_id}", {
        "quantity": 3, "unit_cost": "2.00"
    }))
    assert updated["draft_amount"] == "6.00"
    result(admin.send("DELETE", path + f"/items/{item_id}"))
    assert result(admin.get(path))["items"] == []
    result(admin.send("POST", path + "/cancel"))
    assert result(admin.get(path))["status"] == "CANCELLED"
    result(admin.send("POST", path + "/items", {
        "product_id": 1, "quantity": 1, "unit_cost": "2.00"
    }), 409, "BUSINESS_RULE")


def test_week8_incremental_script_can_be_reapplied_without_losing_data(settings):
    before = scalar(settings, "SELECT COUNT(*) FROM dbo.PurchaseOrder;")
    connection = administrative_connection(settings["DB_SERVER"], settings["DB_DATABASE"])
    try:
        run_script(connection, ROOT / "sql/week8/application.sql")
        run_script(connection, ROOT / "sql/week8/application.sql")
    finally:
        connection.close()
    assert scalar(settings, "SELECT COUNT(*) FROM dbo.PurchaseOrder;") == before


def test_direct_purchase_item_failure_rolls_back_insert(login, settings):
    admin = login("admin")
    order = result(admin.send("POST", "/purchases", {"supplier_id": 1, "items": [
        {"product_id": 1, "quantity": 100, "unit_cost": "60000000.00"}
    ]}), 201)
    purchase_id = order["purchase_id"]
    before = scalar(settings, "SELECT COUNT(*) FROM dbo.PurchaseItem WHERE PurchaseID=?;", purchase_id)
    connection = administrative_connection(settings["DB_SERVER"], settings["DB_DATABASE"])
    try:
        connection.execute("EXECUTE AS USER='WebAdmin';")
        with pytest.raises(pyodbc.Error):
            connection.execute("EXEC app.WritePurchaseItem @PurchaseID=?,@ProductID=2,@Quantity=100,@UnitCost=60000000.00;", purchase_id)
        connection.execute("REVERT;")
    finally:
        connection.close()
    assert scalar(settings, "SELECT COUNT(*) FROM dbo.PurchaseItem WHERE PurchaseID=?;", purchase_id) == before


def test_purchase_rejects_bad_input_and_unknown_records(login):
    admin = login("admin")
    for data in ({}, {"supplier_id": "1"}, {"supplier_id": 0}, {"supplier_id": 1, "items": "x"}, {"supplier_id": 1, "extra": 1},
                 {"supplier_id": 1, "items": [{"product_id": 1, "quantity": 0, "unit_cost": "1.00"}]},
                 {"supplier_id": 1, "items": [{"product_id": 1, "quantity": 1, "unit_cost": "-1"}]}):
        result(admin.send("POST", "/purchases", data), 400, "INVALID_INPUT")
    message = admin.send("POST", "/purchases", {"supplier_id": 99999999})
    result(message, 409, "BUSINESS_RULE")
    assert "供应商" in message.json["message"]
    result(admin.get("/purchases/99999999"), 404, "NOT_FOUND")
    result(admin.send("POST", "/purchases/99999999/confirm"), 404, "NOT_FOUND")


def test_empty_purchase_cannot_be_confirmed_and_message_is_specific(login):
    admin = login("admin")
    order = result(admin.send("POST", "/purchases", {"supplier_id": 1}), 201)
    response = admin.send("POST", f"/purchases/{order['purchase_id']}/confirm")
    result(response, 409, "BUSINESS_RULE")
    assert "没有明细" in response.json["message"]


def test_purchase_endpoints_are_admin_only_and_need_csrf(login):
    admin = login("admin")
    order = result(admin.send("POST", "/purchases", {"supplier_id": 1}), 201)
    path = f"/purchases/{order['purchase_id']}"
    for username in ("staff", "customer"):
        user = login(username)
        result(user.get("/suppliers"), 403, "FORBIDDEN")
        result(user.get(path), 403, "FORBIDDEN")
        result(user.send("POST", path + "/confirm"), 403, "FORBIDDEN")
        result(user.send("POST", path + "/cancel"), 403, "FORBIDDEN")
    assert admin.client.post("/api" + path + "/cancel", json={}).status_code == 403
    assert result(admin.get(path))["status"] == "DRAFT"
