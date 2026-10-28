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


def test_staff_completes_sale_atomically(login, settings):
    staff = login("staff")
    before = scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;")
    order = result(staff.send("POST", "/orders", {
        "payment_method": "CASH", "items": [{"product_id": 1, "quantity": 2}]
    }), 201)
    sale_id = order["sale_id"]

    completed = result(staff.send("POST", f"/orders/{sale_id}/complete"))
    assert completed["status"] == "COMPLETED"
    assert completed["payable_amount"] == "7.00"
    assert scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;") == before - 2
    assert scalar(settings, "SELECT COUNT(*) FROM dbo.InventoryLog WHERE SaleID=? AND ChangeQuantity=-2;", sale_id) == 1

    result(staff.send("POST", f"/orders/{sale_id}/complete"), 409, "BUSINESS_RULE")
    assert scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;") == before - 2


def test_customer_cannot_complete_sale(login, settings):
    customer = login("customer")
    order = result(customer.send("POST", "/orders", {
        "items": [{"product_id": 1, "quantity": 1}]
    }), 201)
    before = scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;")
    result(customer.send("POST", f"/orders/{order['sale_id']}/complete"), 403, "FORBIDDEN")
    assert scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;") == before


def test_insufficient_stock_keeps_sale_draft_and_inventory(login, settings):
    staff = login("staff")
    before = scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;")
    order = result(staff.send("POST", "/orders", {
        "items": [{"product_id": 1, "quantity": before + 1}]
    }), 201)
    sale_id = order["sale_id"]
    result(staff.send("POST", f"/orders/{sale_id}/complete"), 409, "BUSINESS_RULE")
    assert result(staff.get(f"/orders/{sale_id}"))["status"] == "DRAFT"
    assert scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;") == before
    assert scalar(settings, "SELECT COUNT(*) FROM dbo.InventoryLog WHERE SaleID=?;", sale_id) == 0


def test_complete_sale_saves_current_payment_discount_and_remark(login):
    staff = login("staff")
    order = result(staff.send("POST", "/orders", {
        "items": [{"product_id": 1, "quantity": 2}]
    }), 201)
    completed = result(staff.send("POST", f"/orders/{order['sale_id']}/complete", {
        "payment_method": "WECHAT", "discount_amount": "1.00", "remark": "课堂现结"
    }))
    assert completed["status"] == "COMPLETED"
    assert completed["payment_method"] == "WECHAT"
    assert completed["discount_amount"] == "1.00"
    assert completed["payable_amount"] == "6.00"
    assert completed["remark"] == "课堂现结"


def test_failed_completion_rolls_back_new_payment_information(login, settings):
    staff = login("staff")
    stock = scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;")
    order = result(staff.send("POST", "/orders", {
        "items": [{"product_id": 1, "quantity": stock + 1}]
    }), 201)
    sale_id = order["sale_id"]
    result(staff.send("POST", f"/orders/{sale_id}/complete", {
        "payment_method": "WECHAT", "discount_amount": "1.00", "remark": "失败后须回滚"
    }), 409, "BUSINESS_RULE")
    unchanged = result(staff.get(f"/orders/{sale_id}"))
    assert unchanged["status"] == "DRAFT"
    assert unchanged["payment_method"] == "CASH"
    assert unchanged["discount_amount"] == "0.00"
    assert unchanged["remark"] is None
    assert scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;") == stock


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


def test_admin_stocktake_records_both_directions(login, settings):
    admin = login("admin")
    before = scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;")
    raised = result(admin.send("POST", "/inventory/1/adjust", {
        "delta": 5, "reason": "课堂盘点发现多五瓶"
    }))
    assert raised["quantity"] == before + 5
    lowered = result(admin.send("POST", "/inventory/1/adjust", {
        "delta": -2, "reason": "复核后少两瓶"
    }))
    assert lowered["quantity"] == before + 3
    assert scalar(settings, """SELECT COUNT(*) FROM dbo.InventoryLog
        WHERE ProductID=1 AND ChangeType IN ('STOCKTAKE_IN','STOCKTAKE_OUT')
          AND PurchaseID IS NULL AND SaleID IS NULL
          AND Remark IN (N'课堂盘点发现多五瓶',N'复核后少两瓶');""") >= 2
    connection = administrative_connection(settings["DB_SERVER"], settings["DB_DATABASE"])
    try:
        rows = [tuple(row) for row in connection.execute("""
            SELECT ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,EmployeeID
            FROM dbo.InventoryLog WHERE ProductID=1
              AND Remark IN (N'课堂盘点发现多五瓶',N'复核后少两瓶') ORDER BY LogID;
        """).fetchall()]
        employee_id = connection.execute("SELECT EmployeeID FROM app.AppUser WHERE Username='admin';").fetchone()[0]
    finally:
        connection.close()
    assert rows == [
        ("STOCKTAKE_IN", 5, before, before + 5, employee_id),
        ("STOCKTAKE_OUT", -2, before + 5, before + 3, employee_id),
    ]


def test_stocktake_invalid_or_unauthorized_keeps_inventory(login, settings):
    admin = login("admin")
    before = scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;")
    result(admin.send("POST", "/inventory/1/adjust", {"delta": 0, "reason": "零变化"}), 400, "INVALID_INPUT")
    result(admin.send("POST", "/inventory/1/adjust", {"delta": -before - 1, "reason": "超出库存"}), 409, "BUSINESS_RULE")
    result(admin.send("POST", "/inventory/1/adjust", {"delta": 1, "reason": ""}), 400, "INVALID_INPUT")
    for username in ("staff", "customer"):
        result(login(username).send("POST", "/inventory/1/adjust", {"delta": 1, "reason": "越权"}), 403, "FORBIDDEN")
    assert scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;") == before


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


def test_direct_stocktake_log_failure_rolls_back_quantity(settings):
    before = scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;")
    connection = administrative_connection(settings["DB_SERVER"], settings["DB_DATABASE"])
    try:
        # 人为让流水插入失败，验证 UPDATE 库存与 INSERT 流水属于同一事务。
        connection.execute("""CREATE TRIGGER dbo.tr_Week8RejectStocktake ON dbo.InventoryLog
            AFTER INSERT AS BEGIN
              IF EXISTS(SELECT 1 FROM inserted WHERE ChangeType='STOCKTAKE_IN')
                THROW 51990,N'测试拒绝流水',1;
            END;""")
        admin_id = connection.execute("SELECT UserID FROM app.AppUser WHERE Username='admin';").fetchone()[0]
        connection.execute("EXEC sys.sp_set_session_context @key=N'WebUserID',@value=?;", admin_id)
        connection.execute("EXECUTE AS USER='WebAdmin';")
        with pytest.raises(pyodbc.Error):
            connection.execute("EXEC app.Stocktake @ProductID=1,@Delta=1,@Reason=N'测试回滚';")
        connection.execute("REVERT;")
    finally:
        connection.close()
        cleanup = administrative_connection(settings["DB_SERVER"], settings["DB_DATABASE"])
        try:
            cleanup.execute("DROP TRIGGER IF EXISTS dbo.tr_Week8RejectStocktake;")
        finally:
            cleanup.close()
    assert scalar(settings, "SELECT Quantity FROM dbo.Inventory WHERE ProductID=1;") == before
