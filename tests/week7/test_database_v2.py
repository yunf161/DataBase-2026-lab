"""app.SubmitSale/SettleSale/AdjustInventory 的数据库层测试：以受限身份调用，用管理连接核对结果。"""
import os
import random
import secrets
import subprocess
import sys
import threading
from collections import Counter, namedtuple
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal

import pyodbc
import pytest

from app.config import ROOT
from app.database import Database, one, records
from app.errors import NATIVE
from tools.prepare_week7 import administrative_connection, drop_owned_database, provision_database

Actor = namedtuple("Actor", "role uid")
ROUNDS = 5
BUSINESS_ERRORS = {51302, 51304, 51305, 51803, 51811, 51812, 51813}


def native(error):
    numbers = NATIVE.findall(str(error.args[1]))
    return int(numbers[0]) if numbers else None


class Env:
    def __init__(self, app, settings, login, product_data):
        self.db = app.extensions["database"]
        self.settings = settings
        self.admin_api = login("admin")
        self.product_data = product_data
        self.conn = administrative_connection(settings["DB_SERVER"], settings["DB_DATABASE"])
        self.actors = {name: Actor(role, uid) for name, uid, role in
                       self.conn.execute("SELECT Username,UserID,RoleName FROM app.AppUser;").fetchall()}
        self.employee = {no: eid for no, eid in self.conn.execute("SELECT EmployeeNo,EmployeeID FROM dbo.Employee;").fetchall()}
        self.deadlocks = []

    def actor(self, who):
        return self.actors[who] if isinstance(who, str) else who

    def call(self, who, sql, *params):
        actor = self.actor(who)
        with self.db.transaction(actor.role, actor.uid) as connection:
            return records(connection, sql, *params)

    def fail(self, who, sql, *params):
        with pytest.raises(pyodbc.Error) as caught:
            self.call(who, sql, *params)
        return native(caught.value)

    def scalar(self, sql, *params):
        return self.conn.execute(sql, *params).fetchone()[0]

    def product(self, stock=0, price="6.50"):
        data = {**self.product_data, "sku": "V" + secrets.token_hex(6), "sale_price": price, "status": 1}
        response = self.admin_api.send("POST", "/products", data)
        assert response.status_code == 201, response.json
        product_id = response.json["data"]["product_id"]
        if stock:
            self.call("admin", "EXEC app.AdjustInventory ?,?,?", product_id, stock, "测试备货")
        return product_id

    def order(self, who, items, payment="CASH", submit=False):
        sale = self.call(who, "EXEC app.CreateSaleDraft ?,?,?", self.employee["E003"], payment, None)[0]["sale_id"]
        for product_id, quantity in items:
            self.call(who, "EXEC app.WriteSaleItem ?,?,?", sale, product_id, quantity)
        if submit:
            self.call(who, "EXEC app.SubmitSale ?", sale)
        return sale

    def header(self, sale):
        return self.conn.execute(
            "SELECT Status,EmployeeID,SaleNo,TotalAmount,DiscountAmount,PayableAmount,PaymentMethod,Remark "
            "FROM dbo.SaleOrder WHERE SaleID=?;", sale).fetchone()

    def stock(self, product_id):
        return self.scalar("SELECT Quantity FROM dbo.Inventory WHERE ProductID=?;", product_id)

    def logs(self, product_id):
        return self.conn.execute(
            "SELECT LogID,ChangeType,ChangeQuantity,BeforeQuantity,AfterQuantity,SaleID,PurchaseID,EmployeeID,Remark "
            "FROM dbo.InventoryLog WHERE ProductID=? ORDER BY LogID;", product_id).fetchall()

    def snapshot(self):
        return ([tuple(r) for r in self.conn.execute("SELECT ProductID,Quantity FROM dbo.Inventory ORDER BY ProductID;").fetchall()],
                [r[0] for r in self.conn.execute("SELECT LogID FROM dbo.InventoryLog ORDER BY LogID;").fetchall()])

    def race(self, *jobs):
        """每个任务先开好连接和事务，再同时执行，尽量让语句真正并发。"""
        barrier = threading.Barrier(len(jobs))
        labels = [job[1].split()[1] for job in jobs]

        def run(job):
            who, sql, params = job
            actor = self.actor(who)
            try:
                with self.db.transaction(actor.role, actor.uid) as connection:
                    barrier.wait(30)
                    return ("ok", records(connection, sql, *params))
            except pyodbc.Error as error:
                number = native(error)
                if number == 1205:
                    self.deadlocks.append({"victim": sql.split()[1], "concurrent": labels})
                return ("error", number)

        with ThreadPoolExecutor(len(jobs)) as pool:
            return list(pool.map(run, jobs))


@pytest.fixture
def env(app, settings, login, product_data, request, capsys):
    value = Env(app, settings, login, product_data)
    yield value
    value.conn.close()
    if value.deadlocks:
        with capsys.disabled():
            print(f"\nDEADLOCK {request.node.name}: {len(value.deadlocks)} 次 {value.deadlocks}")


def assert_chain(env, product_id):
    rows = env.logs(product_id)
    for previous, current in zip(rows, rows[1:]):
        assert current.BeforeQuantity == previous.AfterQuantity
    if rows:
        assert rows[0].BeforeQuantity == 0 and rows[-1].AfterQuantity == env.stock(product_id)


def kinds(outcomes):
    return sorted(kind for kind, _ in outcomes), sorted(value for kind, value in outcomes if kind == "error")


def assert_settle_rejected(env, who, sale, number, employee="E003"):
    before = env.snapshot()
    assert env.fail(who, "EXEC app.SettleSale ?", sale) == number
    assert env.snapshot() == before
    head = env.header(sale)
    assert (head.Status, head.EmployeeID) == ("DRAFT", env.employee[employee]) and head.TotalAmount == 0


# ---------- A. 正常流程 ----------

def test_customer_submit_then_admin_settles_multiple_lines(env):
    prices, quantities = ["6.50", "4.00", "2.25"], (2, 3, 1)
    products = [env.product(10, price) for price in prices]
    sale = env.order("customer", list(zip(products, quantities)), submit=True)
    assert env.header(sale).EmployeeID == env.employee["E003"]
    assert env.call("admin", "EXEC app.SettleSale ?", sale) == [{"sale_id": sale}]
    head = env.header(sale)
    assert head.Status == "COMPLETED" and head.EmployeeID == env.employee["E001"]
    assert head.TotalAmount == Decimal("27.25")
    for product_id, quantity in zip(products, quantities):
        assert env.stock(product_id) == 10 - quantity
        sold = [row for row in env.logs(product_id) if row.ChangeType == "SALE_OUT"]
        assert len(sold) == 1
        log = sold[0]
        assert (log.SaleID, log.PurchaseID, log.EmployeeID) == (sale, None, env.employee["E001"])
        assert (log.ChangeQuantity, log.BeforeQuantity, log.AfterQuantity) == (-quantity, 10, 10 - quantity)
        shown = env.call("admin", "SELECT business_no FROM app.v_InventoryLog WHERE product_id=? AND change_type='SALE_OUT';", product_id)
        assert shown == [{"business_no": head.SaleNo}]


def test_discount_is_applied_to_settled_total(env):
    first, second = env.product(10, "6.50"), env.product(10, "4.00")
    sale = env.order("staff", [(first, 2), (second, 3)])
    env.call("staff", "EXEC app.UpdateSaleDraft ?,?,?,?", sale, "WECHAT", Decimal("3.50"), None)
    env.call("admin", "EXEC app.SettleSale ?", sale)
    head = env.header(sale)
    assert (head.Status, head.PaymentMethod) == ("COMPLETED", "WECHAT")
    assert head.TotalAmount == Decimal("25.00") and head.DiscountAmount == Decimal("3.50")
    assert head.PayableAmount == Decimal("21.50")


def test_stock_boundary_exact_quantity_settles_and_one_more_fails(env):
    product_id = env.product(5)
    exact = env.order("customer", [(product_id, 5)], submit=True)
    over = env.order("staff", [(product_id, 6)])
    assert env.fail("admin", "EXEC app.SettleSale ?", over) == 51305
    assert env.stock(product_id) == 5
    assert env.fail("customer", "EXEC app.SubmitSale ?", env.order("customer", [(product_id, 6)])) == 51305
    env.call("admin", "EXEC app.SettleSale ?", exact)
    assert env.stock(product_id) == 0 and env.logs(product_id)[-1].AfterQuantity == 0
    assert env.header(over).Status == "DRAFT"


def test_staff_and_admin_orders_settle_without_submit(env):
    product_id = env.product(10)
    by_staff = env.order("staff", [(product_id, 1)])
    by_admin = env.order("admin", [(product_id, 1)])
    assert env.call("staff", "SELECT is_customer_order,submitted_at FROM app.v_OrderAccess WHERE sale_id=?;", by_staff) == [
        {"is_customer_order": 0, "submitted_at": None}]
    env.call("admin", "EXEC app.SettleSale ?", by_staff)
    env.call("staff", "EXEC app.SettleSale ?", by_admin)
    assert env.header(by_staff).EmployeeID == env.employee["E001"]
    assert env.header(by_admin).EmployeeID == env.employee["E003"]
    assert env.stock(product_id) == 8


def test_legacy_draft_without_owner_settles_and_stays_hidden_from_customers(env):
    product_id = env.product(10)
    number = "LEG" + secrets.token_hex(6)
    env.conn.execute("INSERT dbo.SaleOrder(SaleNo,EmployeeID,PaymentMethod) VALUES(?,?,'CASH');", number, env.employee["E003"])
    sale = env.scalar("SELECT SaleID FROM dbo.SaleOrder WHERE SaleNo=?;", number)
    env.conn.execute("INSERT dbo.SaleItem(SaleID,ProductID,Quantity,UnitPrice) VALUES(?,?,2,6.50);", sale, product_id)
    assert env.call("staff", "SELECT is_customer_order,submitted_at FROM app.v_OrderAccess WHERE sale_id=?;", sale) == [
        {"is_customer_order": 0, "submitted_at": None}]
    assert env.call("customer", "SELECT sale_id FROM app.v_OrderAccess WHERE sale_id=?;", sale) == []
    assert env.fail("customer", "EXEC app.SubmitSale ?", sale) == 51804
    env.call("staff", "EXEC app.SettleSale ?", sale)
    assert env.header(sale).Status == "COMPLETED" and env.stock(product_id) == 8


@pytest.mark.parametrize("new_price", ["8.00", "5.00"])
def test_price_change_refreshes_lines_and_needs_second_submit(env, new_price):
    changed, unchanged = env.product(10, "6.50"), env.product(10, "3.00")
    sale = env.order("customer", [(changed, 2), (unchanged, 1)])
    env.conn.execute("UPDATE dbo.Product SET SalePrice=? WHERE ProductID=?;", Decimal(new_price), changed)
    assert env.call("customer", "EXEC app.SubmitSale ?", sale) == [{"submitted": 0, "price_changed": 1}]
    prices = {row.ProductID: row.UnitPrice for row in env.conn.execute(
        "SELECT ProductID,UnitPrice FROM dbo.SaleItem WHERE SaleID=?;", sale).fetchall()}
    assert prices == {changed: Decimal(new_price), unchanged: Decimal("3.00")}
    assert env.scalar("SELECT SubmittedAt FROM app.SaleOwner WHERE SaleID=?;", sale) is None
    assert env.call("customer", "EXEC app.SubmitSale ?", sale) == [{"submitted": 1, "price_changed": 0}]
    assert env.scalar("SELECT SubmittedAt FROM app.SaleOwner WHERE SaleID=?;", sale) is not None


def submitted_at(env, sale):
    return env.scalar("SELECT SubmittedAt FROM app.SaleOwner WHERE SaleID=?;", sale)


def assert_submit_rejected(env, sale, number):
    before = submitted_at(env, sale)
    assert env.fail("customer", "EXEC app.SubmitSale ?", sale) == number
    assert submitted_at(env, sale) == before


def test_submit_rejects_empty_order(env):
    sale = env.order("customer", [])
    assert_submit_rejected(env, sale, 51302)
    assert submitted_at(env, sale) is None


def test_submit_rejects_disabled_product(env):
    product_id = env.product(5)
    sale = env.order("customer", [(product_id, 1)])
    env.conn.execute("UPDATE dbo.Product SET Status=0 WHERE ProductID=?;", product_id)
    assert_submit_rejected(env, sale, 51304)
    assert submitted_at(env, sale) is None


def test_submit_rejects_disabled_category(env):
    product_id = env.product(5)
    sale = env.order("customer", [(product_id, 1)])
    category = env.product_data["category_id"]
    original = env.scalar("SELECT Status FROM dbo.Category WHERE CategoryID=?;", category)
    env.conn.execute("UPDATE dbo.Category SET Status=0 WHERE CategoryID=?;", category)
    try:
        assert_submit_rejected(env, sale, 51304)
        assert submitted_at(env, sale) is None
    finally:
        env.conn.execute("UPDATE dbo.Category SET Status=? WHERE CategoryID=?;", int(original), category)


def test_submit_rejects_an_already_submitted_order(env):
    sale = env.order("customer", [(env.product(5), 1)], submit=True)
    assert submitted_at(env, sale) is not None
    assert_submit_rejected(env, sale, 51811)


def test_settle_uses_the_price_accepted_at_submit_even_after_a_price_rise(env):
    first, second = env.product(10, "6.50"), env.product(10, "4.00")
    sale = env.order("customer", [(first, 2), (second, 3)], submit=True)
    sku = env.scalar("SELECT SKU FROM dbo.Product WHERE ProductID=?;", first)
    raised = env.admin_api.send("PUT", f"/products/{first}", {**env.product_data, "sku": sku, "sale_price": "9.99"})
    assert raised.status_code == 200, raised.json
    assert env.scalar("SELECT SalePrice FROM dbo.Product WHERE ProductID=?;", first) == Decimal("9.99")
    env.call("staff", "EXEC app.SettleSale ?", sale)
    assert env.header(sale).TotalAmount == Decimal("25.00")
    prices = {row.ProductID: row.UnitPrice for row in env.conn.execute(
        "SELECT ProductID,UnitPrice FROM dbo.SaleItem WHERE SaleID=?;", sale).fetchall()}
    assert prices == {first: Decimal("6.50"), second: Decimal("4.00")}


def test_adjust_inventory_direction_log_employee_and_reason(env):
    product_id = env.product(10)
    assert env.call("admin", "EXEC app.AdjustInventory ?,?,?", product_id, 14, "  盘点盘盈  ") == [
        {"product_id": product_id, "quantity": 14}]
    env.call("admin", "EXEC app.AdjustInventory ?,?,?", product_id, 6, "盘点盘亏")
    env.call("admin", "EXEC app.AdjustInventory ?,?,?", product_id, 1000000, "上限")
    env.call("admin", "EXEC app.AdjustInventory ?,?,?", product_id, 0, "清零")
    rows = env.logs(product_id)
    assert [(r.ChangeType, r.ChangeQuantity, r.BeforeQuantity, r.AfterQuantity) for r in rows] == [
        ("STOCKTAKE_IN", 10, 0, 10), ("STOCKTAKE_IN", 4, 10, 14), ("STOCKTAKE_OUT", -8, 14, 6),
        ("STOCKTAKE_IN", 999994, 6, 1000000), ("STOCKTAKE_OUT", -1000000, 1000000, 0)]
    assert [r.Remark for r in rows] == ["测试备货", "盘点盘盈", "盘点盘亏", "上限", "清零"]
    assert all(r.EmployeeID == env.employee["E001"] and r.SaleID is None and r.PurchaseID is None for r in rows)
    assert env.stock(product_id) == 0
    shown = env.call("admin", "SELECT TOP 1 employee_no,remark,business_no FROM app.v_InventoryLog WHERE product_id=? ORDER BY log_id DESC;", product_id)
    assert shown == [{"employee_no": "E001", "remark": "清零", "business_no": None}]


@pytest.mark.parametrize("quantity,reason,number", [
    (-1, "x", 51805), (1000001, "x", 51805), (6, "", 51805), (6, "   ", 51805), (None, "x", 51805), (5, "x", 51813)])
def test_adjust_inventory_rejects_bad_input_without_changes(env, quantity, reason, number):
    product_id = env.product(5)
    before = env.snapshot()
    assert env.fail("admin", "EXEC app.AdjustInventory ?,?,?", product_id, quantity, reason) == number
    assert env.snapshot() == before
    assert env.fail("admin", "EXEC app.AdjustInventory ?,?,?", 999999999, 1, "x") == 51804


# ---------- B. 结算失败必须完全回滚 ----------

def test_settle_failure_rolls_back_every_line_and_can_be_retried(env):
    products = [env.product(5) for _ in range(3)]
    sale = env.order("customer", [(products[0], 1), (products[1], 1), (products[2], 2)], submit=True)
    env.call("admin", "EXEC app.AdjustInventory ?,?,?", max(products), 1, "提交后库存不足")
    assert_settle_rejected(env, "admin", sale, 51305)
    assert [env.stock(p) for p in products] == [5, 5, 1]
    env.call("admin", "EXEC app.AdjustInventory ?,?,?", max(products), 5, "补货")
    env.call("admin", "EXEC app.SettleSale ?", sale)
    assert [env.stock(p) for p in products] == [4, 4, 3]
    assert env.header(sale).Status == "COMPLETED"


def test_settle_rejects_empty_draft(env):
    assert_settle_rejected(env, "admin", env.order("staff", []), 51302)


def test_settle_rejects_discount_above_total(env):
    sale = env.order("staff", [(env.product(5), 1)])
    env.call("staff", "EXEC app.UpdateSaleDraft ?,?,?,?", sale, "CASH", Decimal("100.00"), None)
    assert_settle_rejected(env, "admin", sale, 51303)


def test_settle_rejects_disabled_product(env):
    product_id = env.product(5)
    sale = env.order("customer", [(product_id, 1)], submit=True)
    env.conn.execute("UPDATE dbo.Product SET Status=0 WHERE ProductID=?;", product_id)
    assert_settle_rejected(env, "admin", sale, 51304)


def test_settle_rejects_disabled_category_after_submit(env):
    product_id = env.product(5)
    sale = env.order("customer", [(product_id, 1)], submit=True)
    original = env.scalar("SELECT Status FROM dbo.Category WHERE CategoryID=?;", env.product_data["category_id"])
    env.conn.execute("UPDATE dbo.Category SET Status=0 WHERE CategoryID=?;", env.product_data["category_id"])
    try:
        assert_settle_rejected(env, "admin", sale, 51304)
    finally:
        env.conn.execute("UPDATE dbo.Category SET Status=? WHERE CategoryID=?;", int(original), env.product_data["category_id"])


def test_settle_rejects_missing_payment_method(env):
    assert_settle_rejected(env, "admin", env.order("staff", [(env.product(5), 1)], payment=None), 51301)


def test_settle_rejects_disabled_operator_employee(env):
    sale = env.order("customer", [(env.product(5), 1)], submit=True)
    env.conn.execute("UPDATE dbo.Employee SET Status=0 WHERE EmployeeNo='E003';")
    try:
        assert_settle_rejected(env, "staff", sale, 51306)
    finally:
        env.conn.execute("UPDATE dbo.Employee SET Status=1 WHERE EmployeeNo='E003';")


def test_log_insert_failure_rolls_back_settle_and_adjust(env):
    product_id = env.product(5)
    sale = env.order("customer", [(product_id, 2)], submit=True)
    before = env.snapshot()
    trigger = "tr_Fault_" + secrets.token_hex(4)
    env.conn.execute(f"CREATE TRIGGER dbo.{trigger} ON dbo.InventoryLog AFTER INSERT AS "
                     "BEGIN SET NOCOUNT ON; THROW 59999, N'injected', 1; END;")
    flag = None

    class Rollback(Exception):
        pass

    try:
        assert env.fail("admin", "EXEC app.SettleSale ?", sale) == 59999
        assert env.snapshot() == before and env.header(sale).Status == "DRAFT"
        assert env.fail("admin", "EXEC app.AdjustInventory ?,?,?", product_id, 9, "注入失败") == 59999
        assert env.snapshot() == before
        admin = env.actors["admin"]
        with pytest.raises(Rollback):
            with env.db.transaction(admin.role, admin.uid) as connection:
                with pytest.raises(pyodbc.Error):
                    connection.execute("EXEC app.AdjustInventory ?,?,?", product_id, 9, "注入失败")
                flag = one(connection, "SELECT ISNULL(TRY_CONVERT(int,SESSION_CONTEXT(N'CampusStoreInventoryWrite')),0) AS v;")["v"]
                raise Rollback
    finally:
        env.conn.execute(f"DROP TRIGGER dbo.{trigger};")
    assert flag == 0
    env.call("admin", "EXEC app.SettleSale ?", sale)
    env.call("admin", "EXEC app.AdjustInventory ?,?,?", product_id, 9, "恢复后调整")
    assert env.header(sale).Status == "COMPLETED" and env.stock(product_id) == 9


# ---------- C. 状态与锁定 ----------

def test_submitted_order_is_locked_for_customer_but_not_for_staff_or_cancel(env):
    first, second = env.product(10), env.product(10)
    sale = env.order("customer", [(first, 1)], submit=True)
    item = env.scalar("SELECT SaleItemID FROM dbo.SaleItem WHERE SaleID=?;", sale)
    assert env.fail("customer", "EXEC app.WriteSaleItem ?,?,?", sale, second, 1) == 51811
    assert env.fail("customer", "EXEC app.WriteSaleItem ?,?,?,?,?", sale, first, 3, None, item) == 51811
    assert env.fail("customer", "EXEC app.DeleteSaleItem ?,?", sale, item) == 51811
    assert env.fail("customer", "EXEC app.UpdateSaleDraft ?,?,?,?", sale, "CASH", Decimal("0.00"), "改备注") == 51811
    assert env.scalar("SELECT Quantity FROM dbo.SaleItem WHERE SaleItemID=?;", item) == 1
    assert env.scalar("SELECT COUNT(*) FROM dbo.SaleItem WHERE SaleID=?;", sale) == 1
    env.call("staff", "EXEC app.WriteSaleItem ?,?,?", sale, second, 2)
    env.call("staff", "EXEC app.UpdateSaleDraft ?,?,?,?", sale, "CASH", Decimal("1.00"), "店员备注")
    assert env.scalar("SELECT COUNT(*) FROM dbo.SaleItem WHERE SaleID=?;", sale) == 2
    assert env.header(sale).Remark == "店员备注"
    other = env.order("customer", [(first, 1)], submit=True)
    env.call("customer", "EXEC app.CancelSaleDraft ?", other)
    assert env.header(other).Status == "CANCELLED"


def test_completed_and_cancelled_orders_reject_submit_and_settle(env):
    product_id = env.product(20)
    done = env.order("customer", [(product_id, 1)], submit=True)
    env.call("admin", "EXEC app.SettleSale ?", done)
    cancelled = env.order("customer", [(product_id, 1)], submit=True)
    env.call("customer", "EXEC app.CancelSaleDraft ?", cancelled)
    cancelled_draft = env.order("customer", [(product_id, 1)])
    env.call("customer", "EXEC app.CancelSaleDraft ?", cancelled_draft)
    for sale in (done, cancelled, cancelled_draft):
        assert env.fail("customer", "EXEC app.SubmitSale ?", sale) == 51803
        assert env.fail("staff", "EXEC app.SettleSale ?", sale) == 51803
        assert env.fail("admin", "EXEC app.SettleSale ?", sale) == 51803
    assert [env.header(s).Status for s in (done, cancelled, cancelled_draft)] == ["COMPLETED", "CANCELLED", "CANCELLED"]
    assert env.stock(product_id) == 19


def test_customer_may_resend_the_existing_discount_but_not_change_it(env):
    sale = env.order("customer", [(env.product(5), 1)])
    env.call("staff", "EXEC app.UpdateSaleDraft ?,?,?,?", sale, "CASH", Decimal("1.00"), None)
    env.call("customer", "EXEC app.UpdateSaleDraft ?,?,?,?", sale, "CASH", Decimal("1.00"), "顾客备注")
    head = env.header(sale)
    assert head.Remark == "顾客备注" and head.DiscountAmount == Decimal("1.00")
    for discount in ("2.00", "0.00"):
        assert env.fail("customer", "EXEC app.UpdateSaleDraft ?,?,?,?", sale, "CASH", Decimal(discount), "x") == 51810
    assert env.header(sale).DiscountAmount == Decimal("1.00")


def test_unsubmitted_customer_draft_cannot_be_settled(env):
    sale = env.order("customer", [(env.product(5), 1)])
    for who in ("staff", "admin"):
        assert_settle_rejected(env, who, sale, 51812)


# ---------- D. 权限矩阵 ----------

PERMISSIONS = [
    ("staff", "EXEC app.SubmitSale ?", "sale"), ("admin", "EXEC app.SubmitSale ?", "sale"),
    ("customer", "EXEC app.SettleSale ?", "sale"),
    ("staff", "EXEC app.AdjustInventory ?,?,?", "adjust"), ("customer", "EXEC app.AdjustInventory ?,?,?", "adjust"),
    ("staff", "SELECT * FROM app.v_InventoryLog;", "none"), ("customer", "SELECT * FROM app.v_InventoryLog;", "none"),
    ("admin", "EXEC dbo.CompleteSale ?", "sale"), ("staff", "EXEC dbo.CompleteSale ?", "sale"),
    ("customer", "EXEC dbo.CompleteSale ?", "sale"),
]


@pytest.mark.parametrize("who,sql,kind", PERMISSIONS, ids=[f"{w}-{s.split()[1]}" for w, s, _ in PERMISSIONS])
def test_permission_matrix_is_denied(env, who, sql, kind):
    product_id = env.product(5)
    sale = env.order("customer", [(product_id, 1)], submit=True)
    params = {"sale": (sale,), "adjust": (product_id, 9, "权限测试"), "none": ()}[kind]
    before = env.snapshot()
    assert env.fail(who, sql, *params) == 229
    assert env.snapshot() == before and env.header(sale).Status == "DRAFT"


def test_other_customer_cannot_submit_someone_elses_order(env):
    sale = env.order("customer", [(env.product(5), 1)])
    assert env.fail("customer2", "EXEC app.SubmitSale ?", sale) == 51804
    assert env.scalar("SELECT SubmittedAt FROM app.SaleOwner WHERE SaleID=?;", sale) is None


@pytest.mark.parametrize("set_key", [False, True], ids=["plain", "session-key-set"])
@pytest.mark.parametrize("who", ["admin", "staff", "customer"])
def test_direct_quantity_update_is_denied(env, who, set_key):
    product_id = env.product(5)
    before = env.snapshot()
    actor = env.actors[who]
    with pytest.raises(pyodbc.Error) as caught:
        with env.db.transaction(actor.role, actor.uid) as connection:
            if set_key:
                connection.execute("EXEC sys.sp_set_session_context @key=N'CampusStoreInventoryWrite',@value=1;")
                assert one(connection, "SELECT TRY_CONVERT(int,SESSION_CONTEXT(N'CampusStoreInventoryWrite')) AS v;")["v"] == 1
            connection.execute("UPDATE dbo.Inventory SET Quantity=? WHERE ProductID=?;", 99, product_id)
    assert native(caught.value) in (229, 230)
    assert env.snapshot() == before


# ---------- E. 并发 ----------

def test_last_unit_is_sold_only_once(env):
    for _ in range(ROUNDS):
        product_id = env.product(1)
        first = env.order("customer", [(product_id, 1)], submit=True)
        second = env.order("customer2", [(product_id, 1)], submit=True)
        outcomes = env.race(("admin", "EXEC app.SettleSale ?", (first,)), ("staff", "EXEC app.SettleSale ?", (second,)))
        assert kinds(outcomes) == (["error", "ok"], [51305])
        assert env.stock(product_id) == 0
        assert [r.ChangeType for r in env.logs(product_id)] == ["STOCKTAKE_IN", "SALE_OUT"]
        assert sorted(env.header(s).Status for s in (first, second)) == ["COMPLETED", "DRAFT"]


def test_same_order_settled_twice_deducts_once(env):
    for _ in range(ROUNDS):
        product_id = env.product(5)
        sale = env.order("customer", [(product_id, 2)], submit=True)
        outcomes = env.race(("admin", "EXEC app.SettleSale ?", (sale,)), ("staff", "EXEC app.SettleSale ?", (sale,)))
        assert kinds(outcomes) == (["error", "ok"], [51803])
        assert env.stock(product_id) == 3 and env.header(sale).Status == "COMPLETED"
        assert len([r for r in env.logs(product_id) if r.ChangeType == "SALE_OUT"]) == 1


def test_settle_and_cancel_race_has_a_single_winner(env):
    for _ in range(ROUNDS):
        product_id = env.product(5)
        sale = env.order("customer", [(product_id, 2)], submit=True)
        outcomes = env.race(("staff", "EXEC app.SettleSale ?", (sale,)), ("customer", "EXEC app.CancelSaleDraft ?", (sale,)))
        assert kinds(outcomes) == (["error", "ok"], [51803])
        sold = [r for r in env.logs(product_id) if r.ChangeType == "SALE_OUT"]
        if env.header(sale).Status == "COMPLETED":
            assert outcomes[0][0] == "ok" and env.stock(product_id) == 3 and len(sold) == 1
        else:
            assert env.header(sale).Status == "CANCELLED" and outcomes[1][0] == "ok"
            assert env.stock(product_id) == 5 and not sold


def test_adding_a_line_while_submitting_is_atomic(env):
    for _ in range(ROUNDS):
        first, second = env.product(5), env.product(5)
        sale = env.order("customer", [(first, 1)])
        outcomes = env.race(("customer", "EXEC app.WriteSaleItem ?,?,?", (sale, second, 1)),
                            ("customer", "EXEC app.SubmitSale ?", (sale,)))
        assert outcomes[1] == ("ok", [{"submitted": 1, "price_changed": 0}])
        in_order = env.scalar("SELECT COUNT(*) FROM dbo.SaleItem WHERE SaleID=? AND ProductID=?;", sale, second)
        if outcomes[0][0] == "ok":
            assert in_order == 1
        else:
            assert outcomes[0] == ("error", 51811) and in_order == 0
        assert env.scalar("SELECT SubmittedAt FROM app.SaleOwner WHERE SaleID=?;", sale) is not None


def test_adjust_and_settle_race_keeps_log_chain(env):
    for _ in range(ROUNDS):
        product_id = env.product(5)
        sale = env.order("customer", [(product_id, 2)], submit=True)
        outcomes = env.race(("admin", "EXEC app.SettleSale ?", (sale,)),
                            ("admin", "EXEC app.AdjustInventory ?,?,?", (product_id, 9, "并发盘点")))
        assert kinds(outcomes) == (["ok", "ok"], [])
        assert_chain(env, product_id)
        assert env.stock(product_id) in (3 + 6, 9 - 2) and env.header(sale).Status == "COMPLETED"


def test_mixed_stress_keeps_every_invariant(env, request, capsys):
    seed = secrets.randbits(32)
    chooser = random.Random(seed)
    products = [env.product(30, price) for price in ("6.50", "4.00", "2.25")]
    pool = []
    for index in range(24):
        owner = "customer" if index % 2 else "customer2"
        items = [(p, chooser.randint(1, 3)) for p in chooser.sample(products, chooser.randint(1, 3))]
        pool.append((env.order(owner, items, submit=index % 3 != 0), owner, len(items)))
    barrier, guard, inflight, outcomes = threading.Barrier(8), threading.Lock(), {}, []

    def worker(number):
        rng = random.Random(seed * 100 + number)
        barrier.wait(30)
        for _ in range(10):
            sale, owner, _ = rng.choice(pool)
            action = rng.choice(["submit", "settle", "settle", "cancel", "adjust"])
            if action == "submit":
                who, sql, params = owner, "EXEC app.SubmitSale ?", (sale,)
            elif action == "settle":
                who, sql, params = rng.choice(["admin", "staff"]), "EXEC app.SettleSale ?", (sale,)
            elif action == "cancel":
                who, sql, params = rng.choice([owner, "staff"]), "EXEC app.CancelSaleDraft ?", (sale,)
            else:
                who, sql, params = "admin", "EXEC app.AdjustInventory ?,?,?", (rng.choice(products), rng.randint(0, 12), "压力调整")
            label = f"{sql.split()[1]}#{params[0]}"
            with guard:
                inflight[number] = label
            try:
                env.call(who, sql, *params)
                outcome = "ok"
            except pyodbc.Error as error:
                outcome = native(error)
                if outcome == 1205:
                    with guard:
                        env.deadlocks.append({"victim": label, "concurrent": sorted(v for k, v in inflight.items() if k != number)})
            finally:
                with guard:
                    inflight.pop(number, None)
            outcomes.append((label, outcome))

    with ThreadPoolExecutor(8) as executor:
        for future in [executor.submit(worker, n) for n in range(8)]:
            future.result()
    summary = Counter(str(o) for _, o in outcomes)
    with capsys.disabled():
        print(f"\nSTRESS seed={seed} 操作 {len(outcomes)} 次，结果 {dict(summary)}，1205 共 {len(env.deadlocks)} 次")
    allowed = BUSINESS_ERRORS | {"ok", 1205, 1222}
    assert len(outcomes) == 80
    assert not [item for item in outcomes if item[1] not in allowed]
    for product_id in products:
        assert_chain(env, product_id)
    for sale, _, count in pool:
        status = env.header(sale).Status
        assert env.scalar("SELECT COUNT(*) FROM dbo.InventoryLog WHERE SaleID=?;", sale) == (count if status == "COMPLETED" else 0)
        if status == "COMPLETED":
            assert env.header(sale).TotalAmount == env.scalar("SELECT SUM(LineAmount) FROM dbo.SaleItem WHERE SaleID=?;", sale)


# ---------- F. 旧库升级 ----------

def run_upgrade(server, database):
    return subprocess.run(
        [sys.executable, "-m", "tools.upgrade_week9", "--server", server, "--database", database],
        cwd=ROOT, env={**os.environ, "PYTHONIOENCODING": "utf-8"}, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=120)


def upgrade_state(connection):
    return [[tuple(r) for r in connection.execute(sql).fetchall()] for sql in (
        "SELECT SaleID,Status,EmployeeID,TotalAmount,PaymentMethod FROM dbo.SaleOrder ORDER BY SaleID;",
        "SELECT SaleItemID,SaleID,ProductID,Quantity,UnitPrice FROM dbo.SaleItem ORDER BY SaleItemID;",
        "SELECT SaleID,UserID,SubmittedAt FROM app.SaleOwner ORDER BY SaleID;",
        "SELECT ProductID,Quantity FROM dbo.Inventory ORDER BY ProductID;",
        "SELECT LogID FROM dbo.InventoryLog ORDER BY LogID;")]


def test_upgrade_tool_upgrades_an_old_week7_database_in_place(app, settings):
    server, name = settings["DB_SERVER"], "CampusStoreDB_W7_Test_" + secrets.token_hex(6)
    try:
        provision_database(server, name, apply_week9=False)
        connection = administrative_connection(server, name)
        db = Database({**app.config, "DB_DATABASE": name})
        users = {u: Actor(r, i) for u, i, r in connection.execute("SELECT Username,UserID,RoleName FROM app.AppUser;").fetchall()}

        def call(who, sql, *params):
            with db.transaction(users[who].role, users[who].uid) as c:
                return records(c, sql, *params)

        assert connection.execute("SELECT COL_LENGTH(N'app.SaleOwner',N'SubmittedAt');").fetchone()[0] is None
        product_id = connection.execute("SELECT TOP 1 i.ProductID FROM dbo.Inventory i JOIN dbo.Product p ON p.ProductID=i.ProductID "
                                        "WHERE p.Status=1 AND i.Quantity>=5 ORDER BY i.ProductID;").fetchone()[0]
        employee = connection.execute("SELECT EmployeeID FROM dbo.Employee WHERE EmployeeNo='E003';").fetchone()[0]
        sale = call("customer", "EXEC app.CreateSaleDraft ?,?,?", employee, "CASH", None)[0]["sale_id"]
        call("customer", "EXEC app.WriteSaleItem ?,?,?", sale, product_id, 2)
        stock = connection.execute("SELECT Quantity FROM dbo.Inventory WHERE ProductID=?;", product_id).fetchone()[0]

        first = run_upgrade(server, name)
        assert first.returncode == 0, first.stdout + first.stderr
        assert connection.execute("SELECT COL_LENGTH(N'app.SaleOwner',N'SubmittedAt');").fetchone()[0] is not None
        assert connection.execute("SELECT COUNT(*) FROM dbo.SaleItem WHERE SaleID=? AND ProductID=? AND Quantity=2;", sale, product_id).fetchone()[0] == 1
        assert call("customer", "SELECT submitted_at,is_customer_order FROM app.v_OrderAccess WHERE sale_id=?;", sale) == [
            {"submitted_at": None, "is_customer_order": 1}]
        assert call("customer", "EXEC app.SubmitSale ?", sale) == [{"submitted": 1, "price_changed": 0}]
        assert call("staff", "EXEC app.SettleSale ?", sale) == [{"sale_id": sale}]
        assert connection.execute("SELECT Quantity FROM dbo.Inventory WHERE ProductID=?;", product_id).fetchone()[0] == stock - 2

        assert call("customer", "SELECT COUNT(*) AS total FROM app.v_CategoryScope;")[0]["total"] > 0
        assert call("admin", "SELECT COUNT(*) AS total FROM app.v_Suppliers;")[0]["total"] > 0

        before = upgrade_state(connection)
        second = run_upgrade(server, name)
        assert second.returncode == 0, second.stdout + second.stderr
        assert upgrade_state(connection) == before
        connection.close()
    finally:
        drop_owned_database(server, name)


def test_upgrade_tool_refuses_a_database_outside_the_w7_naming_rule(settings):
    result = run_upgrade(settings["DB_SERVER"], "master")
    assert result.returncode != 0
    assert "Traceback" not in result.stdout + result.stderr
