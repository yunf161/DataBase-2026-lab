import hmac
import secrets
from functools import wraps

from flask import Blueprint, current_app, g, jsonify, render_template, request, session

from .errors import AppError
from .services import integer, public_user, require_role

pages = Blueprint("pages", __name__)
api = Blueprint("api", __name__, url_prefix="/api")


def reply(data=None, message="操作成功。", status=200):
    g.response_code = "OK"
    return jsonify(ok=True, code="OK", message=message, data=data, request_id=g.request_id), status


def body():
    if not request.is_json:
        raise AppError("INVALID_INPUT", "请以正确格式提交表单。")
    data = request.get_json()
    if not isinstance(data, dict):
        raise AppError("INVALID_INPUT", "提交内容必须是对象。")
    return data


def signed_in(function):
    @wraps(function)
    def wrapped(*args, **kwargs):
        require_role(g.user, "ADMIN", "STAFF", "CUSTOMER")
        for identifier in kwargs.values():
            integer(identifier, "记录编号")
        return function(*args, **kwargs)
    return wrapped


def store():
    return current_app.extensions["store_service"]


@pages.get("/")
def index():
    return render_template("index.html")


@api.get("/auth/session")
def auth_session():
    session.setdefault("csrf_token", secrets.token_urlsafe(32))
    return reply({"user": public_user(g.user) if g.user else None, "csrf_token": session["csrf_token"]})


@api.post("/auth/login")
def login():
    user = current_app.extensions["auth_service"].authenticate(body())
    session.clear()
    session["user_id"] = user["user_id"]
    session["csrf_token"] = secrets.token_urlsafe(32)
    session.permanent = True
    g.user = user
    return reply({"user": public_user(user), "csrf_token": session["csrf_token"]}, "登录成功。")


@api.post("/auth/logout")
def logout():
    session.clear()
    session["csrf_token"] = secrets.token_urlsafe(32)
    return reply({"csrf_token": session["csrf_token"]}, "已退出登录。")


@api.get("/categories")
@signed_in
def categories():
    return reply(store().categories(g.user))


@api.get("/products")
@signed_in
def products():
    return reply(store().products(g.user, request.args))


@api.post("/products")
@signed_in
def create_product():
    return reply(store().create_product(g.user, body()), "商品已新增，初始库存为零。", 201)


@api.put("/products/<int:product_id>")
@signed_in
def update_product(product_id):
    return reply(store().update_product(g.user, product_id, body()), "商品已更新。")


@api.delete("/products/<int:product_id>")
@signed_in
def delete_product(product_id):
    store().delete_product(g.user, product_id)
    return reply(message="未使用商品已删除。")


@api.get("/inventory")
@signed_in
def inventory():
    return reply(store().inventory(g.user, request.args))


@api.patch("/inventory/<int:product_id>")
@signed_in
def update_minimum(product_id):
    return reply(store().update_minimum(g.user, product_id, body()), "库存预警下限已更新。")


@api.get("/orders")
@signed_in
def orders():
    return reply(store().orders(g.user, request.args))


@api.post("/orders")
@signed_in
def create_order():
    return reply(store().create_order(g.user, body()), "草稿订单已创建，尚未扣减库存。", 201)


@api.get("/orders/<int:sale_id>")
@signed_in
def order(sale_id):
    return reply(store().order(g.user, sale_id))


@api.patch("/orders/<int:sale_id>")
@signed_in
def update_order(sale_id):
    return reply(store().update_order(g.user, sale_id, body()), "草稿信息已保存。")


@api.post("/orders/<int:sale_id>/items")
@signed_in
def add_item(sale_id):
    return reply(store().write_item(g.user, sale_id, body()), "商品已加入草稿。", 201)


@api.patch("/orders/<int:sale_id>/items/<int:item_id>")
@signed_in
def update_item(sale_id, item_id):
    return reply(store().write_item(g.user, sale_id, body(), item_id), "草稿明细已更新。")


@api.delete("/orders/<int:sale_id>/items/<int:item_id>")
@signed_in
def delete_item(sale_id, item_id):
    store().delete_item(g.user, sale_id, item_id)
    return reply(message="草稿明细已移除。")


@api.post("/orders/<int:sale_id>/cancel")
@signed_in
def cancel_order(sale_id):
    store().cancel_order(g.user, sale_id)
    return reply(message="草稿订单已取消。")


def check_csrf():
    if request.method not in {"GET", "HEAD", "OPTIONS"}:
        expected = session.get("csrf_token", "")
        actual = request.headers.get("X-CSRF-Token", "")
        if not expected or not hmac.compare_digest(expected, actual):
            raise AppError("CSRF_INVALID", "页面已过期，请刷新后重试。", 403)
