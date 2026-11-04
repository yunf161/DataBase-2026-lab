"""业务层：身份、输入、业务规则和一整次操作的事务边界。"""
import re
from decimal import Decimal, InvalidOperation

from werkzeug.security import check_password_hash, generate_password_hash

from .errors import AppError

PAYMENTS = {"CASH", "WECHAT", "ALIPAY", "BANK_CARD"}


def require_role(user, *roles):
    if not user:
        raise AppError("AUTH_REQUIRED", "请先登录后继续。", 401)
    if user["role"] not in roles:
        raise AppError("FORBIDDEN", "当前角色没有执行此操作的权限。", 403)


def fields(data, allowed, required=()):
    if not isinstance(data, dict) or set(data) - set(allowed):
        raise AppError("INVALID_INPUT", "提交内容包含不支持的字段。")
    if set(required) - set(data):
        raise AppError("INVALID_INPUT", "请填写全部必填项。")
    return data


def utf16_length(value):
    # SQL Server 的 nvarchar 按 UTF-16 代码单元计长，emoji 占两个单位；孤立代理项无法编码，按非法输入处理。
    try:
        return len(value.encode("utf-16-le")) // 2
    except UnicodeEncodeError:
        return None


def text(value, name, maximum, required=False):
    if value is None and not required:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise AppError("INVALID_INPUT", name + "格式或长度不正确。")
    value = value.strip()
    length = utf16_length(value)
    if length is None or length > maximum:
        raise AppError("INVALID_INPUT", name + "格式或长度不正确。")
    if required and not value:
        raise AppError("INVALID_INPUT", "请填写" + name + "。")
    return value or None


def integer(value, name, minimum=1, maximum=9223372036854775807):
    if type(value) is not int or not minimum <= value <= maximum:
        raise AppError("INVALID_INPUT", name + "必须是规定范围内的整数。")
    return value


def query_integer(value, name, maximum=1000000):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{1,18}", value):
        raise AppError("INVALID_INPUT", name + "格式不正确。")
    return integer(int(value), name, maximum=maximum)


def money(value, name, maximum="99999999.99"):
    if isinstance(value, bool) or not isinstance(value, (str, int, float, Decimal)):
        raise AppError("INVALID_INPUT", name + "必须是金额。")
    try:
        amount = Decimal(str(value))
        if not amount.is_finite() or amount < 0 or amount > Decimal(maximum) or amount != amount.quantize(Decimal(".01")):
            raise ValueError()
        return amount.quantize(Decimal(".01"))
    except (InvalidOperation, ValueError):
        raise AppError("INVALID_INPUT", name + "必须是不小于零、最多两位小数的有效金额。") from None


def search_pattern(value):
    value = text(value, "搜索内容", 100) or ""
    return "%" + value.replace("[", "[[]").replace("%", "[%]").replace("_", "[_]") + "%"


def active_user(user):
    if not user or not user["status"]:
        return False
    if user["role"] == "CUSTOMER":
        return True
    return bool(user["employee_status"] and user["employee_role"] == {"ADMIN": "ADMIN", "STAFF": "CASHIER"}.get(user["role"]))


def public_user(user):
    return {key: user[key] for key in ("user_id", "username", "display_name", "role")}


class AuthService:
    def __init__(self, repository):
        self.repository = repository
        self.dummy_hash = generate_password_hash("not-a-real-account")

    def authenticate(self, data):
        fields(data, {"username", "password"}, {"username", "password"})
        username = text(data["username"], "用户名", 40, True)
        password = data["password"]
        if not isinstance(password, str) or utf16_length(password) is None or not 1 <= len(password) <= 128:
            raise AppError("INVALID_INPUT", "密码长度不正确。")
        user = self.repository.by_username(username)
        valid = check_password_hash(user["password_hash"] if user else self.dummy_hash, password)
        if not valid or not active_user(user):
            raise AppError("AUTH_FAILED", "用户名或密码不正确。", 401)
        return user

    def session_user(self, user_id):
        user = self.repository.by_id(user_id)
        return user if active_user(user) else None


class StoreService:
    def __init__(self, repository, settings):
        self.repository = repository
        self.settings = settings

    def categories(self, user):
        require_role(user, "ADMIN", "STAFF", "CUSTOMER")
        with self.repository.transaction(user) as connection:
            return self.repository.categories(connection)

    def products(self, user, query):
        require_role(user, "ADMIN", "STAFF", "CUSTOMER")
        status = query.get("status", "1" if user["role"] == "CUSTOMER" else "all")
        if status not in {"all", "0", "1"} or (user["role"] == "CUSTOMER" and status != "1"):
            raise AppError("INVALID_INPUT", "商品状态筛选不正确。")
        category = query.get("category_id", "")
        category_id = query_integer(category, "分类") if category else 0
        page = query_integer(query.get("page", "1"), "页码")
        limit = query_integer(query.get("page_size", "20"), "每页数量", 100)
        pattern = search_pattern(query.get("q", ""))
        with self.repository.transaction(user) as connection:
            result = self.repository.products(connection, pattern, -1 if status == "all" else int(status), limit, (page - 1) * limit, category_id)
        return {**result, "page": page, "page_size": limit}

    def product_data(self, data):
        allowed = {"sku", "barcode", "product_name", "category_id", "specification", "unit", "sale_price", "status"}
        fields(data, allowed, {"sku", "product_name", "category_id", "sale_price"})
        sku = text(data["sku"], "商品编号", 30, True)
        barcode = text(data.get("barcode"), "条码", 32)
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,30}", sku) or (barcode and not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", barcode)):
            raise AppError("INVALID_INPUT", "商品编号和条码仅支持字母、数字、下划线及短横线。")
        return {
            "sku": sku, "barcode": barcode,
            "product_name": text(data["product_name"], "商品名称", 100, True),
            "category_id": integer(data["category_id"], "分类"),
            "specification": text(data.get("specification"), "规格", 100),
            "unit": text(data.get("unit", "件"), "单位", 20, True),
            "sale_price": money(data["sale_price"], "售价"),
            "status": integer(data.get("status", 1), "商品状态", 0, 1),
        }

    def create_product(self, user, data):
        require_role(user, "ADMIN")
        data = self.product_data(data)
        with self.repository.transaction(user) as connection:
            product_id = self.repository.create_product(connection, data)
            return self.repository.product(connection, product_id)

    def update_product(self, user, product_id, data):
        require_role(user, "ADMIN")
        data = self.product_data(data)
        with self.repository.transaction(user) as connection:
            if not self.repository.product(connection, product_id):
                raise AppError("NOT_FOUND", "商品不存在。", 404)
            self.repository.update_product(connection, product_id, data)
            return self.repository.product(connection, product_id)

    def delete_product(self, user, product_id):
        require_role(user, "ADMIN")
        with self.repository.transaction(user) as connection:
            self.repository.delete_product(connection, product_id)

    def inventory(self, user, query):
        require_role(user, "ADMIN", "STAFF")
        status = query.get("stock_status", "")
        if status not in {"", "NORMAL", "LOW_STOCK", "OUT_OF_STOCK"}:
            raise AppError("INVALID_INPUT", "库存状态不正确。")
        with self.repository.transaction(user) as connection:
            return self.repository.inventory(connection, search_pattern(query.get("q", "")), status)

    def update_minimum(self, user, product_id, data):
        require_role(user, "ADMIN")
        fields(data, {"min_quantity"}, {"min_quantity"})
        minimum = integer(data["min_quantity"], "库存预警下限", 0, 1000000)
        with self.repository.transaction(user) as connection:
            if not self.repository.product(connection, product_id):
                raise AppError("NOT_FOUND", "商品不存在。", 404)
            self.repository.update_minimum(connection, product_id, minimum)
        return {"product_id": product_id, "min_quantity": minimum}

    def adjust_inventory(self, user, product_id, data):
        require_role(user, "ADMIN")
        fields(data, {"new_quantity", "reason"}, {"new_quantity", "reason"})
        quantity = integer(data["new_quantity"], "库存数量", 0, 1000000)
        reason = text(data["reason"], "调整原因", 255, True)
        with self.repository.transaction(user) as connection:
            if not self.repository.product(connection, product_id):
                raise AppError("NOT_FOUND", "商品不存在。", 404)
            return self.repository.adjust_inventory(connection, product_id, quantity, reason)

    def inventory_logs(self, user, product_id, query):
        require_role(user, "ADMIN")
        page = query_integer(query.get("page", "1"), "页码")
        limit = query_integer(query.get("page_size", "20"), "每页数量", 100)
        with self.repository.transaction(user) as connection:
            if not self.repository.product(connection, product_id):
                raise AppError("NOT_FOUND", "商品不存在。", 404)
            result = self.repository.inventory_logs(connection, product_id, limit, (page - 1) * limit)
        return {**result, "page": page, "page_size": limit}

    def orders(self, user, query):
        require_role(user, "ADMIN", "STAFF", "CUSTOMER")
        status = query.get("status", "")
        if status not in {"", "DRAFT", "COMPLETED", "CANCELLED"}:
            raise AppError("INVALID_INPUT", "订单状态不正确。")
        pending = query.get("pending")
        if pending not in {None, "1"}:
            raise AppError("INVALID_INPUT", "待受理筛选不正确。")
        page = query_integer(query.get("page", "1"), "页码")
        limit = query_integer(query.get("page_size", "20"), "每页数量", 100)
        with self.repository.transaction(user) as connection:
            result = self.repository.orders(connection, search_pattern(query.get("q", "")), status,
                                            limit, (page - 1) * limit, pending == "1")
        return {**result, "page": page, "page_size": limit}

    def order(self, user, sale_id):
        require_role(user, "ADMIN", "STAFF", "CUSTOMER")
        with self.repository.transaction(user) as connection:
            order = self.repository.order(connection, sale_id)
            if not order:
                raise AppError("NOT_FOUND", "订单不存在或当前账号无法访问。", 404)
            return order

    def draft(self, connection, sale_id):
        order = self.repository.order(connection, sale_id)
        if not order:
            raise AppError("NOT_FOUND", "订单不存在或当前账号无法访问。", 404)
        if order["status"] != "DRAFT":
            raise AppError("BUSINESS_RULE", "只有草稿订单允许此操作。", 409)
        return order

    def item_data(self, user, data, creating):
        allowed = {"quantity", "unit_price"} | ({"product_id"} if creating else set())
        fields(data, allowed, {"quantity"} | ({"product_id"} if creating else set()))
        quantity = integer(data["quantity"], "数量", 1, 1000000)
        price = None
        if "unit_price" in data:
            require_role(user, "ADMIN", "STAFF")
            price = money(data["unit_price"], "成交单价")
        return integer(data["product_id"], "商品") if creating else None, quantity, price

    def responsible_employee(self, connection, user):
        if user["role"] != "CUSTOMER":
            return user["employee_id"]
        cashier = self.repository.cashier(connection, self.settings["DEFAULT_CASHIER_NO"])
        if not cashier:
            raise AppError("BUSINESS_RULE", "暂无可受理订单的店员，请稍后重试。", 409)
        return cashier["employee_id"]

    def create_order(self, user, data):
        require_role(user, "ADMIN", "STAFF", "CUSTOMER")
        fields(data, {"payment_method", "remark", "items"})
        payment = data.get("payment_method", "CASH")
        if not isinstance(payment, str) or payment not in PAYMENTS:
            raise AppError("INVALID_INPUT", "请选择有效支付方式。")
        remark = text(data.get("remark"), "备注", 255)
        items = data.get("items", [])
        if not isinstance(items, list) or len(items) > 100:
            raise AppError("INVALID_INPUT", "订单明细必须是最多100项的列表。")
        clean_items = [self.item_data(user, item, True) for item in items]
        with self.repository.transaction(user) as connection:
            employee_id = self.responsible_employee(connection, user)
            sale_id = self.repository.create_order(connection, employee_id, payment, remark)
            for product_id, quantity, price in clean_items:
                self.repository.write_item(connection, sale_id, product_id, quantity, price)
            return self.repository.order(connection, sale_id)

    def draft_values(self, user, order, data):
        if "payment_method" in data:
            payment = data["payment_method"]
            if not isinstance(payment, str) or payment not in PAYMENTS:
                raise AppError("INVALID_INPUT", "请选择有效支付方式。")
        else:
            payment = order["payment_method"]
        discount = order["discount_amount"]
        if "discount_amount" in data:
            discount = money(data["discount_amount"], "优惠金额", "9999999999.99")
            if user["role"] == "CUSTOMER" and discount != order["discount_amount"]:
                raise AppError("FORBIDDEN", "顾客不能设置订单优惠。", 403)
        return payment, discount

    def update_order(self, user, sale_id, data):
        require_role(user, "ADMIN", "STAFF", "CUSTOMER")
        with self.repository.transaction(user) as connection:
            order = self.draft(connection, sale_id)
            payment, discount = self.draft_values(user, order, data)
            remark = text(data.get("remark", order["remark"]), "备注", 255)
            self.repository.update_order(connection, sale_id, payment, discount, remark)
            return self.repository.order(connection, sale_id)

    def submit_order(self, user, sale_id):
        require_role(user, "CUSTOMER")
        with self.repository.transaction(user) as connection:
            outcome = self.repository.submit_sale(connection, sale_id)
            return {"submitted": bool(outcome["submitted"]), "price_changed": bool(outcome["price_changed"]),
                    "order": self.repository.order(connection, sale_id)}

    def settle_order(self, user, sale_id, data):
        require_role(user, "ADMIN", "STAFF")
        fields(data, {"payment_method", "discount_amount"})
        with self.repository.transaction(user) as connection:
            order = self.draft(connection, sale_id)
            if data:
                payment, discount = self.draft_values(user, order, data)
                self.repository.update_order(connection, sale_id, payment, discount, order["remark"])
            self.repository.settle_sale(connection, sale_id)
            return self.repository.order(connection, sale_id)

    def add_to_cart(self, user, data):
        require_role(user, "ADMIN", "STAFF", "CUSTOMER")
        fields(data, {"product_id", "quantity"}, {"product_id", "quantity"})
        product_id = integer(data["product_id"], "商品")
        quantity = integer(data["quantity"], "数量", 1, 1000000)
        with self.repository.transaction(user) as connection:
            # 同一用户的并发加购串行执行，避免同时新建多张草稿。
            if not self.repository.lock_cart(connection, user["user_id"]):
                raise AppError("TRANSACTION_FAILED", "操作因并发冲突未生效，请稍后重试。", 409)
            current = self.repository.current_draft(connection, user["user_id"])
            if current:
                sale_id = current["sale_id"]
                existing = next((item for item in self.repository.order(connection, sale_id)["items"]
                                 if item["product_id"] == product_id), None)
            else:
                sale_id = self.repository.create_order(
                    connection, self.responsible_employee(connection, user), "CASH", None)
                existing = None
            if existing:
                total = integer(existing["quantity"] + quantity, "数量", 1, 1000000)
                self.repository.write_item(connection, sale_id, product_id, total, None, existing["item_id"])
            else:
                self.repository.write_item(connection, sale_id, product_id, quantity)
            return self.repository.order(connection, sale_id)

    def write_item(self, user, sale_id, data, item_id=None):
        require_role(user, "ADMIN", "STAFF", "CUSTOMER")
        product_id, quantity, price = self.item_data(user, data, item_id is None)
        with self.repository.transaction(user) as connection:
            self.draft(connection, sale_id)
            self.repository.write_item(connection, sale_id, product_id, quantity, price, item_id)
            return self.repository.order(connection, sale_id)

    def delete_item(self, user, sale_id, item_id):
        require_role(user, "ADMIN", "STAFF", "CUSTOMER")
        with self.repository.transaction(user) as connection:
            self.draft(connection, sale_id)
            self.repository.delete_item(connection, sale_id, item_id)

    def cancel_order(self, user, sale_id):
        require_role(user, "ADMIN", "STAFF", "CUSTOMER")
        with self.repository.transaction(user) as connection:
            self.draft(connection, sale_id)
            self.repository.cancel_order(connection, sale_id)

    def suppliers(self, user):
        require_role(user, "ADMIN")
        with self.repository.transaction(user) as connection:
            return self.repository.suppliers(connection)

    def purchases(self, user):
        require_role(user, "ADMIN")
        with self.repository.transaction(user) as connection:
            return self.repository.purchases(connection)

    def purchase(self, user, purchase_id):
        require_role(user, "ADMIN")
        with self.repository.transaction(user) as connection:
            order = self.repository.purchase(connection, purchase_id)
            if not order:
                raise AppError("NOT_FOUND", "采购单不存在。", 404)
            return order

    def purchase_item_data(self, data, creating=True):
        fields(data, {"quantity", "unit_cost"} | ({"product_id"} if creating else set()),
               {"quantity", "unit_cost"} | ({"product_id"} if creating else set()))
        return (integer(data["product_id"], "商品") if creating else None,
                integer(data["quantity"], "采购数量", 1, 1000000),
                money(data["unit_cost"], "采购进价"))

    def create_purchase(self, user, data):
        require_role(user, "ADMIN")
        fields(data, {"supplier_id", "items"}, {"supplier_id"})
        supplier_id = integer(data["supplier_id"], "供应商")
        items = data.get("items", [])
        if not isinstance(items, list) or len(items) > 100:
            raise AppError("INVALID_INPUT", "采购明细最多100项。")
        clean_items = [self.purchase_item_data(item) for item in items]
        with self.repository.transaction(user) as connection:
            purchase_id = self.repository.create_purchase(connection, supplier_id)
            for product_id, quantity, unit_cost in clean_items:
                self.repository.write_purchase_item(connection, purchase_id, product_id, quantity, unit_cost)
            return self.repository.purchase(connection, purchase_id)

    def confirm_purchase(self, user, purchase_id):
        require_role(user, "ADMIN")
        with self.repository.transaction(user) as connection:
            order = self.repository.purchase(connection, purchase_id)
            if not order:
                raise AppError("NOT_FOUND", "采购单不存在。", 404)
            if order["status"] != "DRAFT":
                raise AppError("BUSINESS_RULE", "只有草稿采购单可以确认入库。", 409)
            self.repository.confirm_purchase(connection, purchase_id)
            return self.repository.purchase(connection, purchase_id)

    def purchase_draft(self, connection, purchase_id):
        order = self.repository.purchase(connection, purchase_id)
        if not order:
            raise AppError("NOT_FOUND", "采购单不存在。", 404)
        if order["status"] != "DRAFT":
            raise AppError("BUSINESS_RULE", "只有草稿采购单可以修改。", 409)
        return order

    def write_purchase_item(self, user, purchase_id, data, item_id=None):
        require_role(user, "ADMIN")
        product_id, quantity, unit_cost = self.purchase_item_data(data, item_id is None)
        with self.repository.transaction(user) as connection:
            self.purchase_draft(connection, purchase_id)
            self.repository.write_purchase_item(connection, purchase_id, product_id, quantity, unit_cost, item_id)
            return self.repository.purchase(connection, purchase_id)

    def delete_purchase_item(self, user, purchase_id, item_id):
        require_role(user, "ADMIN")
        with self.repository.transaction(user) as connection:
            self.purchase_draft(connection, purchase_id)
            self.repository.delete_purchase_item(connection, purchase_id, item_id)

    def cancel_purchase(self, user, purchase_id):
        require_role(user, "ADMIN")
        with self.repository.transaction(user) as connection:
            self.purchase_draft(connection, purchase_id)
            self.repository.cancel_purchase(connection, purchase_id)
            return self.repository.purchase(connection, purchase_id)
