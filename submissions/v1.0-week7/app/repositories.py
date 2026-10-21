"""数据访问层：SQL 只出现在此层和数据库脚本；用户数据均通过 ? 绑定。"""
from .database import one, records

PRODUCT_FIELDS = """
product_id,sku,barcode,product_name,category_id,category_name,specification,
unit,sale_price,status,quantity,updated_at
"""
USER_QUERY = """
SELECT u.UserID AS user_id,u.Username AS username,u.PasswordHash AS password_hash,
 u.DisplayName AS display_name,u.RoleName AS role,u.EmployeeID AS employee_id,
 u.Status AS status,e.Status AS employee_status,e.RoleName AS employee_role
FROM app.AppUser u LEFT JOIN dbo.Employee e ON e.EmployeeID=u.EmployeeID
"""


class AuthRepository:
    def __init__(self, database):
        self.database = database

    def by_username(self, username):
        with self.database.transaction("AUTH") as connection:
            return one(connection, USER_QUERY + " WHERE u.Username=?;", username)

    def by_id(self, user_id):
        with self.database.transaction("AUTH") as connection:
            return one(connection, USER_QUERY + " WHERE u.UserID=?;", user_id)


class StoreRepository:
    def __init__(self, database):
        self.database = database

    def transaction(self, user):
        return self.database.transaction(user["role"], user["user_id"])

    def products(self, connection, pattern, status, limit, offset):
        where = """ FROM app.v_Catalog
            WHERE (product_name LIKE ? OR sku LIKE ?) AND (?=-1 OR status=?) """
        total = one(connection, "SELECT COUNT(*) AS total" + where, pattern, pattern, status, status)["total"]
        result = records(
            connection, "SELECT " + PRODUCT_FIELDS + where +
            " ORDER BY product_id OFFSET ? ROWS FETCH NEXT ? ROWS ONLY;",
            pattern, pattern, status, status, offset, limit,
        )
        return {"items": result, "total": total}

    def product(self, connection, product_id):
        return one(connection, "SELECT " + PRODUCT_FIELDS + " FROM app.v_Catalog WHERE product_id=?;", product_id)

    def categories(self, connection):
        return records(connection, "SELECT category_id,category_name FROM app.v_Categories ORDER BY category_id;")

    def create_product(self, connection, data):
        return one(connection, """
          INSERT dbo.Product(SKU,Barcode,ProductName,CategoryID,Specification,Unit,SalePrice,Status)
          VALUES(?,?,?,?,?,?,?,?);
          SELECT CONVERT(bigint,SCOPE_IDENTITY()) AS product_id;
        """, data["sku"], data["barcode"], data["product_name"], data["category_id"],
           data["specification"], data["unit"], data["sale_price"], data["status"])["product_id"]

    def update_product(self, connection, product_id, data):
        connection.execute("""
          UPDATE dbo.Product SET SKU=?,Barcode=?,ProductName=?,CategoryID=?,Specification=?,
            Unit=?,SalePrice=?,Status=? WHERE ProductID=?;
        """, data["sku"], data["barcode"], data["product_name"], data["category_id"],
           data["specification"], data["unit"], data["sale_price"], data["status"], product_id)

    def delete_product(self, connection, product_id):
        connection.execute("EXEC app.DeleteUnusedProduct @ProductID=?;", product_id)

    def inventory(self, connection, pattern, stock_status):
        return records(connection, """
          SELECT product_id,sku,product_name,category_name,quantity,min_quantity,stock_status
          FROM app.v_Inventory WHERE (product_name LIKE ? OR sku LIKE ?)
           AND (?='' OR stock_status=?) ORDER BY product_id;
        """, pattern, pattern, stock_status, stock_status)

    def update_minimum(self, connection, product_id, minimum):
        connection.execute("UPDATE dbo.Inventory SET MinQuantity=? WHERE ProductID=?;", minimum, product_id)

    def orders(self, connection, pattern, status, limit, offset):
        where = " FROM app.v_OrderAccess WHERE sale_no LIKE ? AND (?='' OR status=?) "
        total = one(connection, "SELECT COUNT(*) AS total" + where, pattern, status, status)["total"]
        data = records(connection, "SELECT *" + where +
                       "ORDER BY sale_id DESC OFFSET ? ROWS FETCH NEXT ? ROWS ONLY;",
                       pattern, status, status, offset, limit)
        return {"items": data, "total": total}

    def order(self, connection, sale_id):
        order = one(connection, "SELECT * FROM app.v_OrderAccess WHERE sale_id=?;", sale_id)
        if order:
            order["items"] = records(connection,
                "SELECT * FROM app.v_OrderItems WHERE sale_id=? ORDER BY item_id;", sale_id)
        return order

    def cashier(self, connection, employee_no):
        return one(connection, "SELECT employee_id FROM app.v_Cashiers WHERE employee_no=?;", employee_no)

    def create_order(self, connection, employee_id, payment_method, remark):
        return one(connection,
            "EXEC app.CreateSaleDraft @EmployeeID=?,@PaymentMethod=?,@Remark=?;",
            employee_id, payment_method, remark)["sale_id"]

    def write_item(self, connection, sale_id, product_id, quantity, unit_price=None, item_id=None):
        return one(connection, """
            EXEC app.WriteSaleItem @SaleID=?,@ProductID=?,@Quantity=?,@UnitPrice=?,@SaleItemID=?;
        """, sale_id, product_id, quantity, unit_price, item_id)["item_id"]

    def delete_item(self, connection, sale_id, item_id):
        connection.execute("EXEC app.DeleteSaleItem @SaleID=?,@SaleItemID=?;", sale_id, item_id)

    def update_order(self, connection, sale_id, payment, discount, remark):
        connection.execute(
            "EXEC app.UpdateSaleDraft @SaleID=?,@PaymentMethod=?,@DiscountAmount=?,@Remark=?;",
            sale_id, payment, discount, remark)

    def cancel_order(self, connection, sale_id):
        connection.execute("EXEC app.CancelSaleDraft @SaleID=?;", sale_id)
