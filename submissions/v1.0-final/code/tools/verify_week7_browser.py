"""实际浏览器验收。先准备独立开发库并启动 python -m app。"""
import argparse
import json
import os
import secrets
import sys
from contextlib import contextmanager
from pathlib import Path

from playwright.sync_api import Error as PlaywrightError, expect, sync_playwright

from app.config import ROOT
from tools.prepare_week7 import DEMO_PASSWORD, administrative_connection


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:5070")
    parser.add_argument("--output", default=str(ROOT / "results/app-test"))
    parser.add_argument("--browser-executable", default=os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE"))
    parser.add_argument("--server", help="SQL Server 实例；与 --database 一起提供时才运行需要管理连接的检查")
    parser.add_argument("--database", help="被测应用数据库名")
    parser.add_argument("--driver", help="管理连接使用的 ODBC 驱动")
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    findings = []
    errors = []
    failures = []

    @contextmanager
    def scenario(title):
        try:
            yield
        except (AssertionError, PlaywrightError) as error:
            failures.append(title)
            findings.append({"test": title, "result": "failed", "actual": str(error).strip().splitlines()[0][:300]})
            print("失败：" + title + "\n" + str(error)[:1500], flush=True)

    def shot(target, name, toast=None):
        # 截图只能包含与当前操作对应的提示：指定 toast 时核对其文字，否则等提示自行消失。
        if toast:
            expect(target.locator("#toast")).to_contain_text(toast)
        else:
            expect(target.locator("#toast")).to_be_hidden(timeout=10000)
        target.screenshot(path=str(output / name), full_page=True)

    def clear_carts(owner):
        # 上一个场景失败时可能留下未提交的购物车，先取消，避免连带影响后面的场景。
        token = owner.request.get(args.url + "/api/auth/session").json()["data"]["csrf_token"]
        rows = owner.request.get(args.url + "/api/orders?status=DRAFT&page_size=100").json()["data"]["items"]
        for row in rows:
            if not row["submitted_at"]:
                owner.request.post(args.url + "/api/orders/" + str(row["sale_id"]) + "/cancel", data={}, headers={"X-CSRF-Token": token})
    with sync_playwright() as playwright:
        options = {"headless": True}
        if args.browser_executable:
            options["executable_path"] = args.browser_executable
        browser = playwright.chromium.launch(**options)
        context = browser.new_context(viewport={"width": 1440, "height": 1000}, locale="zh-CN")
        page = context.new_page()
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.goto(args.url, wait_until="networkidle")
        expect(page.locator("#login-submit")).to_be_enabled()
        shot(page, "01-login.png")
        page.locator("#username").fill("admin")
        page.locator("#password").fill("wrong-password")
        page.locator("#login-submit").click()
        expect(page.locator("#login-error")).to_contain_text("用户名或密码不正确")
        findings.append({"test": "登录失败友好提示", "result": "passed", "expected": "401，页面显示统一提示", "actual": "用户名或密码不正确。"})
        page.locator("#password").fill(DEMO_PASSWORD)
        page.locator("#login-submit").click()
        expect(page.locator("#workspace")).to_be_visible()
        expect(page.locator("#table-body tr")).to_have_count(6)
        shot(page, "02-admin-products.png")
        sku = "UI" + secrets.token_hex(5)
        page.locator("#heading-action").click()
        page.locator("#p-sku").fill(sku)
        page.locator("#p-name").fill("浏览器验证文具")
        page.locator("#p-category").select_option("5")
        page.locator("#p-price").fill("6.80")
        page.get_by_role("button", name="保存商品", exact=True).click()
        expect(page.locator("#editor")).not_to_be_visible()
        row = page.locator("#table-body tr").filter(has_text=sku)
        expect(row).to_contain_text("6.80")
        row.get_by_role("button", name="编辑", exact=True).click()
        expect(page.locator("#p-status")).to_have_value("1")
        page.locator("#p-name").fill("浏览器验证文具（已更新）")
        page.locator("#p-price").fill("7.20")
        page.get_by_role("button", name="保存商品", exact=True).click()
        expect(page.locator("#editor")).not_to_be_visible()
        expect(row).to_contain_text("7.20")
        row.get_by_role("button", name="删除", exact=True).click()
        page.locator("#confirm-accept").click()
        expect(row).to_have_count(0)
        findings.append({"test": "管理员通过界面完成商品增改删", "result": "passed", "actual": "6.80 → 7.20，商品保持在售，零库存商品删除成功"})
        page.locator("#table-body tr").filter(has_text="P0001").get_by_role("button", name="删除", exact=True).click()
        page.locator("#confirm-accept").click()
        expect(page.locator("#page-error")).to_be_visible()
        expect(page.locator("#page-error")).to_contain_text("不允许此操作")
        assert "SQL Server" not in page.locator("#page-error").inner_text()
        shot(page, "03-friendly-business-error.png")
        findings.append({"test": "删除有历史记录商品被拒绝", "result": "passed", "actual": "409，前端显示友好业务提示与参考编号"})
        page.locator('[data-view="inventory"]').click()
        expect(page.locator("#page-title")).to_have_text("库存查询")
        expect(page.locator("#table-head")).to_contain_text("预警下限")
        expect(page.locator("#table-body tr")).to_have_count(6)
        shot(page, "04-admin-inventory.png")
        findings.append({"test": "管理员库存查询", "result": "passed", "actual": "6件商品的库存与预警状态"})
        page.locator("#logout").click()
        expect(page.locator("#login-screen")).to_be_visible()

        def login(target, username):
            target.goto(args.url, wait_until="networkidle")
            expect(target.locator("#login-submit")).to_be_enabled()
            target.locator("#username").fill(username)
            target.locator("#password").fill(DEMO_PASSWORD)
            target.locator("#login-submit").click()
            expect(target.locator("#workspace")).to_be_visible()
            expect(target.locator("#table-body tr")).to_have_count(6)

        contexts = []
        forbidden = ("SQL", "ODBC", "pyodbc", "Traceback", "dbo.")

        def new_page(username, width=1440, height=1000):
            target_context = browser.new_context(viewport={"width": width, "height": height}, locale="zh-CN")
            contexts.append(target_context)
            target = target_context.new_page()
            target.on("pageerror", lambda error: errors.append(str(error)))
            login(target, username)
            return target

        def go(target, view, title, fragment):
            target.evaluate("document.querySelectorAll('dialog[open]').forEach((dialog) => dialog.close())")
            with target.expect_response(lambda r: fragment in r.url and r.request.method == "GET"):
                target.locator('[data-view="' + view + '"]').click()
            expect(target.locator("#page-title")).to_have_text(title)

        def sku_row(target, sku):
            return target.locator("#table-body tr").filter(has_text=sku)

        def add_to_cart(target, sku):
            go(target, "products", "商品货架", "/api/products?")
            with target.expect_response(lambda r: r.url.endswith("/api/cart/items") and r.request.method == "POST") as info:
                sku_row(target, sku).get_by_role("button", name="加入购物车", exact=True).click()
            assert info.value.status == 200, info.value.text()

        def open_cart(target):
            go(target, "orders", "我的订单", "/api/orders?")
            cart = target.locator("#table-body tr").filter(has_text="购物车")
            expect(cart).to_have_count(1)
            cart.get_by_role("button", name="查看明细", exact=True).click()
            expect(target.locator("#submit-order")).to_be_visible()

        def open_pending(target):
            go(target, "orders", "销售订单", "/api/orders?")
            target.locator("#status-filter").select_option("pending")
            with target.expect_request(lambda r: "/api/orders?" in r.url and "pending=1" in r.url) as info:
                target.locator("#filter-form button[type=submit]").click()
            return info.value.url

        def open_inventory(target):
            go(target, "inventory", "库存查询", "/api/inventory?")

        def stocks(owner):
            response = owner.request.get(args.url + "/api/inventory")
            assert response.ok, response.text()
            return {row["sku"]: row for row in response.json()["data"]}

        def adjust_stock(target, sku, quantity, reason):
            open_inventory(target)
            sku_row(target, sku).get_by_role("button", name="调整库存", exact=True).click()
            expect(target.locator("#editor-title")).to_have_text("调整库存")
            target.locator("#adjust-quantity").fill(str(quantity))
            target.locator("#adjust-reason").fill(reason)
            target.get_by_role("button", name="确认调整", exact=True).click()
            expect(target.locator("#editor")).not_to_be_visible()
            expect(sku_row(target, sku).locator("td").nth(3)).to_have_text(str(quantity))

        def assert_clean(target):
            text = target.locator("body").inner_text()
            assert not [word for word in forbidden if word in text], text

        login(page, "staff")
        expect(page.locator("#heading-action")).not_to_be_visible()
        expect(page.locator("#inventory-nav")).to_be_visible()
        page.locator('[data-view="orders"]').click()
        expect(page.locator("#table-body tr")).to_have_count(3)
        shot(page, "05-staff-orders.png")
        findings.append({"test": "店员界面与权限", "result": "passed", "actual": "可查库存和订单，无商品维护入口"})
        page.locator("#logout").click()
        expect(page.locator("#login-screen")).to_be_visible()
        login(page, "customer")
        expect(page.locator("#inventory-nav")).not_to_be_visible()
        expect(page.locator("#heading-action")).not_to_be_visible()
        shot(page, "06-customer-catalog.png")
        denied = context.request.get(args.url + "/api/inventory")
        assert denied.status == 403 and denied.json()["code"] == "FORBIDDEN"
        findings.append({"test": "顾客直接请求库存接口被拒绝", "result": "passed", "actual": denied.json()["code"], "status": denied.status})
        order_id = 1
        with scenario("顾客购物车完整界面流程"):
            shop_row = page.locator("#table-body tr").filter(has_text="P0001")
            expect(shop_row.get_by_role("button", name="加入草稿", exact=True)).to_have_count(0)
            shop_row.get_by_role("button", name="加入购物车", exact=True).click()
            expect(page.locator("#toast")).to_contain_text("已加入购物车，可在“我的订单”中提交")
            expect(page.locator("#editor")).not_to_be_visible()
            page.locator('[data-view="orders"]').click()
            expect(page.locator("#page-title")).to_have_text("我的订单")
            expect(page.locator("#heading-action")).not_to_be_visible()
            expect(page.locator("#table-head")).to_contain_text("应付金额")
            cart_row = page.locator("#table-body tr").filter(has_text="购物车")
            expect(cart_row).to_have_count(1)
            cart_row.get_by_role("button", name="查看明细", exact=True).click()
            expect(page.locator("#editor")).to_be_visible()
            expect(page.locator("#order-discount")).to_be_disabled()
            quantity = page.locator("[data-quantity]").first
            quantity.fill("2")
            page.get_by_role("button", name="更新", exact=True).click()
            expect(page.locator(".order-total")).to_contain_text("7.00")
            page.locator("#line-product").select_option("3")
            page.locator("#line-quantity").fill("1")
            page.locator("#add-line-form").get_by_role("button", name="加入购物车", exact=True).click()
            expect(page.locator(".order-total")).to_contain_text("9.00")
            page.locator("#order-remark").fill("下课后领取")
            page.locator("#order-payment").select_option("WECHAT")
            page.get_by_role("button", name="保存信息", exact=True).click()
            expect(page.locator("#order-remark")).to_have_value("下课后领取")
            expect(page.locator("#order-payment")).to_have_value("WECHAT")
            expect(page.locator("#cancel-draft")).to_have_text("取消订单")
            expect(page.locator("#editor")).not_to_contain_text("草稿")
            shot(page, "07-customer-draft.png")
            order_id = page.evaluate("state.detail.sale_id")
            page.locator(".order-items tr").filter(has_text="矿泉水").get_by_role("button", name="移除", exact=True).click()
            expect(page.locator(".order-total")).to_contain_text("7.00")
            page.locator("#cancel-draft").click()
            expect(page.locator("#confirmation")).not_to_contain_text("草稿")
            page.locator("#confirm-accept").click()
            expect(page.locator(".order-meta")).to_contain_text("已取消")
            expect(page.locator("#add-line-form")).to_have_count(0)
            page.locator("#close-editor").click()
            findings.append({"test": "顾客购物车完整界面流程", "result": "passed", "actual": "加入购物车后留在商品页，订单页取得购物车、2件可乐7.00、加水9.00、保存备注/支付、移除明细、取消；顾客界面用“加入购物车/保存信息/取消订单”，不出现“草稿”"})
        clear_carts(context)
        other_context = browser.new_context(viewport={"width": 390, "height": 844}, locale="zh-CN")
        other = other_context.new_page()
        other.on("pageerror", lambda error: errors.append(str(error)))
        login(other, "customer2")
        response = other_context.request.get(args.url + "/api/orders/" + str(order_id))
        assert response.status == 404
        assert response.json()["code"] == "NOT_FOUND"
        assert other.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        expect(other.locator("#logout")).to_be_visible()
        shot(other, "08-mobile-customer.png")
        other.locator("#logout").click()
        expect(other.locator("#login-screen")).to_be_visible()
        findings.append({"test": "另一顾客无法访问订单", "result": "passed", "status": response.status, "actual": response.json()["code"]})
        findings.append({"test": "390px手机布局", "result": "passed", "actual": "页面无整体横向溢出，表格卡片内横向滚动，手机可退出登录"})
        other_context.close()

        customer = new_page("customer")
        staff = new_page("staff")
        admin = new_page("admin")
        before = stocks(staff.context)

        add_to_cart(customer, "P0001")
        add_to_cart(customer, "P0001")
        add_to_cart(customer, "P0004")
        go(customer, "orders", "我的订单", "/api/orders?")
        customer.locator("#status-filter").select_option("DRAFT")
        customer.locator("#filter-form button[type=submit]").click()
        expect(customer.locator("#table-body tr")).to_have_count(1)
        customer.locator("#table-body tr").get_by_role("button", name="查看明细", exact=True).click()
        expect(customer.locator(".order-items tbody tr")).to_have_count(2)
        expect(customer.locator("[data-quantity]").first).to_have_value("2")
        expect(customer.locator("[data-quantity]").nth(1)).to_have_value("1")
        expect(customer.locator(".order-total")).to_contain_text("11.00")
        customer.get_by_role("button", name="提交订单", exact=True).click()
        expect(customer.locator("#editor")).to_contain_text("待店员受理")
        expect(customer.locator(".order-meta")).to_contain_text("待受理")
        for selector in ("[data-quantity]", "#add-line-form", "#order-info-form", "#submit-order"):
            expect(customer.locator(selector)).to_have_count(0)
        expect(customer.locator("#cancel-draft")).to_be_visible()
        sale_no = customer.evaluate("state.detail.sale_no")
        shot(customer, "09-customer-cart-submitted.png")
        findings.append({"test": "顾客加购合并并提交", "result": "passed", "actual": "可乐加两次合并为2件、薯片1件，只有一张草稿订单；提交后显示待店员受理，明细、备注和支付方式编辑入口消失，只剩取消"})
        customer.locator("#close-editor").click()

        url = open_pending(staff)
        assert "status=" not in url, url
        staff.locator("#table-body tr").filter(has_text=sale_no).get_by_role("button", name="查看明细", exact=True).click()
        expect(staff.locator("#settle-order")).to_be_visible()
        staff.locator("#order-discount").fill("1.00")
        staff.locator("#order-payment").select_option("ALIPAY")
        staff.locator("#settle-order").click()
        expect(staff.locator("#confirmation")).to_be_visible()
        staff.locator("#confirm-accept").click()
        expect(staff.locator(".order-meta")).to_contain_text("已完成")
        expect(staff.locator(".order-payable")).to_contain_text("10.00")
        expect(staff.locator(".order-discount")).to_contain_text("1.00")
        expect(staff.locator("#settle-order")).to_have_count(0)
        shot(staff, "10-staff-settle.png")
        staff.locator("#close-editor").click()
        go(staff, "orders", "销售订单", "/api/orders?")
        settled = staff.locator("#table-body tr").filter(has_text=sale_no)
        expect(settled).to_contain_text("已完成")
        expect(settled.locator("td").nth(4)).to_contain_text("10.00")
        findings.append({"test": "店员在待受理筛选中结算", "result": "passed", "actual": "请求带pending=1且不带status；优惠1.00、支付宝；状态已完成，应付10.00", "request": url})

        go(customer, "orders", "我的订单", "/api/orders?")
        mine = customer.locator("#table-body tr").filter(has_text=sale_no)
        expect(mine).to_contain_text("已完成")
        expect(mine.locator("td").nth(4)).to_contain_text("10.00")
        shot(customer, "11-customer-completed.png")
        findings.append({"test": "顾客看到已完成订单和应付金额", "result": "passed", "actual": "已完成，应付10.00"})

        open_inventory(staff)
        expect(sku_row(staff, "P0001").locator("td").nth(3)).to_have_text(str(before["P0001"]["quantity"] - 2))
        expect(sku_row(staff, "P0004").locator("td").nth(3)).to_have_text(str(before["P0004"]["quantity"] - 1))
        expect(staff.get_by_role("button", name="调整库存")).to_have_count(0)
        expect(staff.get_by_role("button", name="查看流水")).to_have_count(0)
        shot(staff, "12-staff-inventory-after-sale.png")
        findings.append({"test": "结算后店员库存页库存减少", "result": "passed", "actual": "可乐-2、薯片-1，店员没有调整库存和查看流水按钮"})

        add_to_cart(customer, "P0001")
        open_cart(customer)
        customer.get_by_role("button", name="提交订单", exact=True).click()
        expect(customer.locator("#editor")).to_contain_text("待店员受理")
        short_no = customer.evaluate("state.detail.sale_no")
        customer.locator("#close-editor").click()
        adjust_stock(admin, "P0001", 0, "盘点：货架缺货，库存清零")
        open_pending(staff)
        staff.locator("#table-body tr").filter(has_text=short_no).get_by_role("button", name="查看明细", exact=True).click()
        staff.locator("#settle-order").click()
        staff.locator("#confirm-accept").click()
        expect(staff.locator("#editor-error")).to_be_visible()
        expect(staff.locator("#editor-error")).to_contain_text("库存不足")
        expect(staff.locator(".order-meta")).to_contain_text("待受理")
        assert_clean(staff)
        shot(staff, "13-insufficient-stock.png")
        staff.locator("#close-editor").click()
        open_pending(staff)
        expect(staff.locator("#table-body tr").filter(has_text=short_no)).to_contain_text("待受理")
        findings.append({"test": "库存不足时结算被拒绝", "result": "passed", "actual": "弹窗提示含库存不足，订单仍待受理，页面不含SQL或内部信息"})

        open_inventory(admin)
        sku_row(admin, "P0001").get_by_role("button", name="调整库存", exact=True).click()
        expect(admin.locator("#adjust-form")).to_contain_text("当前数量 0")
        admin.locator("#adjust-quantity").fill("18")
        expect(admin.locator("#adjust-delta")).to_contain_text("+18")
        admin.locator("#adjust-reason").fill("盘点校正：补录货架库存")
        admin.get_by_role("button", name="确认调整", exact=True).click()
        expect(admin.locator("#editor")).not_to_be_visible()
        expect(sku_row(admin, "P0001").locator("td").nth(3)).to_have_text("18")
        sku_row(admin, "P0001").get_by_role("button", name="查看流水", exact=True).click()
        expect(admin.locator("#editor-title")).to_have_text("库存流水")
        for label in ("时间", "类型", "变化量", "前后数量", "单号", "员工", "备注"):
            expect(admin.locator(".log-table thead")).to_contain_text(label)
        for label in ("销售出库", "盘亏", "盘盈", "盘点校正：补录货架库存", "0 → 18"):
            expect(admin.locator(".log-table tbody")).to_contain_text(label)
        shot(admin, "14-admin-adjust-and-logs.png")
        admin.locator("#close-editor").click()
        pen_id = stocks(admin.context)["P0006"]["product_id"]
        token = admin.context.request.get(args.url + "/api/auth/session").json()["data"]["csrf_token"]
        for index in range(11):
            changed = admin.context.request.patch(args.url + "/api/inventory/" + str(pen_id) + "/quantity",
                                                  data={"new_quantity": 100 + index, "reason": "批量盘点" + str(index)},
                                                  headers={"X-CSRF-Token": token})
            assert changed.ok, changed.text()
        open_inventory(admin)
        sku_row(admin, "P0006").get_by_role("button", name="查看流水", exact=True).click()
        expect(admin.locator(".log-pager")).to_contain_text("第 1 页")
        expect(admin.locator("#log-previous")).to_be_disabled()
        admin.locator("#log-next").click()
        expect(admin.locator(".log-pager")).to_contain_text("第 2 页")
        admin.locator("#log-previous").click()
        expect(admin.locator(".log-pager")).to_contain_text("第 1 页")
        admin.locator("#close-editor").click()
        findings.append({"test": "管理员调整库存并查看流水", "result": "passed", "actual": "原因含中文，变化量实时显示+18；可乐流水含销售出库、盘亏、盘盈；11次盘点后流水可翻页，翻页无脚本异常"})

        add_to_cart(customer, "P0004")
        open_cart(customer)
        expect(customer.locator(".order-total")).to_contain_text("4.00")
        go(staff, "orders", "销售订单", "/api/orders?")
        waiting = staff.locator("#table-body tr").filter(has_text="顾客选购中")
        expect(waiting).to_have_count(1)
        waiting.get_by_role("button", name="查看明细", exact=True).click()
        expect(staff.locator("#editor")).to_contain_text("顾客尚未提交")
        expect(staff.locator("#settle-order")).to_have_count(0)
        staff.locator("#close-editor").click()
        go(admin, "products", "商品管理", "/api/products?")
        sku_row(admin, "P0004").get_by_role("button", name="编辑", exact=True).click()
        admin.locator("#p-price").fill("4.50")
        admin.get_by_role("button", name="保存商品", exact=True).click()
        expect(admin.locator("#editor")).not_to_be_visible()
        expect(sku_row(admin, "P0004")).to_contain_text("4.50")
        customer.get_by_role("button", name="提交订单", exact=True).click()
        expect(customer.locator(".order-notice")).to_contain_text("价格已更新")
        expect(customer.locator(".order-total")).to_contain_text("4.50")
        expect(customer.locator(".order-items")).to_contain_text("4.50")
        expect(customer.locator(".order-meta")).to_contain_text("购物车")
        expect(customer.locator("#submit-order")).to_be_visible()
        shot(customer, "15-price-changed.png")
        customer.get_by_role("button", name="提交订单", exact=True).click()
        expect(customer.locator("#editor")).to_contain_text("待店员受理")
        expect(customer.locator(".order-total")).to_contain_text("4.50")
        customer.locator("#close-editor").click()
        findings.append({"test": "提交时价格变化需顾客确认", "result": "passed", "actual": "店员看到顾客选购中且无结算按钮；管理员改价后首次提交提示价格已更新并显示4.50，再次提交成功"})

        phone = new_page("customer", 390, 844)
        add_to_cart(phone, "P0005")
        open_cart(phone)
        phone.locator("#order-remark").fill("手机下单，课间取货")
        assert phone.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        box = phone.locator("#editor").bounding_box()
        assert box["x"] >= 0 and box["x"] + box["width"] <= 390, box
        for selector in ("#submit-order", "#cancel-draft", ".order-payable"):
            expect(phone.locator(selector)).to_be_visible()
        phone.locator("#submit-order").click()
        expect(phone.locator("#editor")).to_contain_text("待店员受理")
        expect(phone.locator("#editor")).to_contain_text("手机下单，课间取货")
        assert phone.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        shot(phone, "16-mobile-order-detail.png")
        admin_phone = new_page("admin", 390, 844)
        go(admin_phone, "inventory", "库存查询", "/api/inventory?")
        sku_row(admin_phone, "P0006").get_by_role("button", name="查看流水", exact=True).click()
        expect(admin_phone.locator("#editor-title")).to_have_text("库存流水")
        assert admin_phone.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        box = admin_phone.locator("#editor").bounding_box()
        assert box["x"] >= 0 and box["x"] + box["width"] <= 390, box
        admin_phone.locator("#log-next").click()
        expect(admin_phone.locator(".log-pager")).to_contain_text("第 2 页")
        assert admin_phone.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        shot(admin_phone, "17-mobile-inventory-logs.png")
        findings.append({"test": "390px下订单详情和库存流水", "result": "passed", "actual": "页面无整体横向溢出，弹窗在视口内；手机上可提交订单、翻页流水"})

        toast_hit = ("() => { const b = document.getElementById('toast').getBoundingClientRect();"
                     " const e = document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2); return e ? e.id : null; }")
        error_in_view = ("() => { const e = document.getElementById('editor-error').getBoundingClientRect();"
                         " const d = document.getElementById('editor').getBoundingClientRect();"
                         " return e.top >= d.top && e.bottom <= d.bottom && e.top >= 0 && e.bottom <= window.innerHeight; }")

        def submit_cart(sku):
            add_to_cart(customer, sku)
            open_cart(customer)
            customer.get_by_role("button", name="提交订单", exact=True).click()
            expect(customer.locator("#editor")).to_contain_text("待店员受理")
            number = customer.evaluate("state.detail.sale_no")
            customer.locator("#close-editor").click()
            return number

        def open_order(target, number):
            target.locator("#table-body tr").filter(has_text=number).get_by_role("button", name="查看明细", exact=True).click()
            expect(target.locator("#editor")).to_be_visible()

        with scenario("员工看到顾客已提交订单的说明"):
            note_no = submit_cart("P0005")
            open_pending(staff)
            open_order(staff, note_no)
            expect(staff.locator("#editor")).to_contain_text("顾客已提交，确认收款后完成结算，库存在结算时扣减。")
            findings.append({"test": "员工查看顾客已提交订单的提示", "result": "passed", "actual": "显示“顾客已提交，确认收款后完成结算，库存在结算时扣减。”"})

        with scenario("提示条在弹窗上方清晰可见"):
            open_pending(staff)
            open_order(staff, note_no)
            staff.locator("#order-remark").fill("先保存的备注")
            staff.get_by_role("button", name="保存草稿信息", exact=True).click()
            expect(staff.locator("#toast")).to_contain_text("草稿信息已保存")
            assert staff.evaluate("document.getElementById('editor').open")
            hit = staff.evaluate(toast_hit)
            assert hit == "toast", "弹窗打开时提示条中心点命中的是：" + str(hit)
            shot(staff, "18-toast-over-dialog.png", toast="草稿信息已保存")
            findings.append({"test": "提示条在弹窗上方", "result": "passed", "actual": "弹窗打开时提示条中心点命中 #toast"})

        with scenario("店员改备注后直接结算，详情显示新备注"):
            open_pending(staff)
            open_order(staff, note_no)
            staff.locator("#order-remark").fill("结算时修改的备注")
            staff.locator("#settle-order").click()
            staff.locator("#confirm-accept").click()
            expect(staff.locator(".order-meta")).to_contain_text("已完成")
            expect(staff.locator("#editor")).to_contain_text("备注：结算时修改的备注")
            assert staff.evaluate("state.detail.remark") == "结算时修改的备注"
            staff.locator("#close-editor").click()
            findings.append({"test": "改备注后直接结算", "result": "passed", "actual": "结算后详情显示新备注"})

        with scenario("库存不足的错误提示滚动到弹窗可视范围（1366×768）"):
            short_no = submit_cart("P0002")
            product_id = stocks(admin.context)["P0002"]["product_id"]
            token = admin.context.request.get(args.url + "/api/auth/session").json()["data"]["csrf_token"]
            lowered = admin.context.request.patch(args.url + "/api/inventory/" + str(product_id) + "/quantity",
                                                  data={"new_quantity": 0, "reason": "盘点：纸巾清零"}, headers={"X-CSRF-Token": token})
            assert lowered.ok, lowered.text()
            desk = new_page("staff", 1366, 768)
            open_pending(desk)
            open_order(desk, short_no)
            assert desk.evaluate("document.getElementById('editor').scrollHeight > document.getElementById('editor').clientHeight")
            desk.evaluate("() => { const e = document.getElementById('editor'); e.scrollTop = e.scrollHeight; }")
            desk.locator("#settle-order").click()
            desk.locator("#confirm-accept").click()
            expect(desk.locator("#editor-error")).to_contain_text("库存不足")
            desk.wait_for_function(error_in_view, timeout=3000)
            expect(desk.locator(".order-meta")).to_contain_text("待受理")
            shot(desk, "19-error-in-view-1366.png")
            findings.append({"test": "错误提示滚动到弹窗可视范围", "result": "passed", "actual": "1366×768，弹窗滚到底部点结算，库存不足提示位于弹窗可视范围内"})

        with scenario("已取消订单的应付金额显示为—"):
            add_to_cart(customer, "P0003")
            open_cart(customer)
            cancelled_no = customer.evaluate("state.detail.sale_no")
            customer.locator("#cancel-draft").click()
            customer.locator("#confirm-accept").click()
            expect(customer.locator(".order-meta")).to_contain_text("已取消")
            expect(customer.locator(".order-payable")).to_have_text("应付—")
            expect(customer.locator("#editor")).not_to_contain_text("应付 ¥")
            customer.locator("#close-editor").click()
            cancelled = customer.locator("#table-body tr").filter(has_text=cancelled_no)
            expect(cancelled).to_contain_text("已取消")
            expect(cancelled.locator("td").nth(4)).to_have_text("—")
            shot(customer, "20-cancelled-no-payable.png")
            findings.append({"test": "已取消订单不显示应付金额", "result": "passed", "actual": "列表应付金额列和详情的应付行都显示—"})

        with scenario("停用分类下的商品编辑保持原分类"):
            if not (args.server and args.database):
                findings.append({"test": "停用分类下的商品编辑保持原分类", "result": "skipped", "actual": "未提供 --server/--database，无法使用管理连接"})
            else:
                manager = administrative_connection(args.server, args.database, args.driver)
                category_id = None
                try:
                    category_id, category_name = manager.execute(
                        "SELECT c.CategoryID, c.CategoryName FROM dbo.Product p JOIN dbo.Category c ON c.CategoryID=p.CategoryID WHERE p.SKU='P0006';").fetchone()
                    manager.execute("UPDATE dbo.Category SET Status=0 WHERE CategoryID=?;", category_id)
                    editor = new_page("admin")
                    sku_row(editor, "P0006").get_by_role("button", name="编辑", exact=True).click()
                    expect(editor.locator("#p-category")).to_have_value(str(category_id))
                    expect(editor.locator("#p-category option:checked")).to_have_text(category_name + "（已停用）")
                    shot(editor, "21-disabled-category-edit.png")
                    editor.get_by_role("button", name="保存商品", exact=True).click()
                    expect(editor.locator("#editor")).not_to_be_visible()
                    saved = manager.execute("SELECT CategoryID FROM dbo.Product WHERE SKU='P0006';").fetchone()[0]
                    assert saved == category_id, "保存后分类变成了 " + str(saved)
                    findings.append({"test": "停用分类下的商品编辑保持原分类", "result": "passed", "actual": "下拉框显示“" + category_name + "（已停用）”且被选中，保存后分类编号不变"})
                finally:
                    if category_id is not None:
                        manager.execute("UPDATE dbo.Category SET Status=1 WHERE CategoryID=?;", category_id)
                    manager.close()

        with scenario("按分类查询商品，选父分类时包含子分类"):
            shopper = new_page("customer")
            category_filter = shopper.locator("#category-filter")
            expect(category_filter).to_be_visible()
            expect(category_filter).to_have_value("")
            category_filter.select_option(label="饮料")
            shopper.get_by_role("button", name="查询", exact=True).click()
            expect(shopper.locator("#table-body tr")).to_have_count(2)
            expect(sku_row(shopper, "P0001")).to_have_count(1)
            expect(sku_row(shopper, "P0003")).to_have_count(1)
            category_filter.select_option(label="食品")
            shopper.get_by_role("button", name="查询", exact=True).click()
            expect(shopper.locator("#table-body tr")).to_have_count(4)
            expect(sku_row(shopper, "P0004")).to_have_count(1)
            expect(sku_row(shopper, "P0002")).to_have_count(0)
            shot(shopper, "22-category-filter.png")
            shopper.locator('[data-view="orders"]').click()
            expect(category_filter).to_be_hidden()
            shopper.locator('[data-view="products"]').click()
            expect(category_filter).to_have_value("")
            expect(sku_row(shopper, "P0002")).to_have_count(1)
            findings.append({"test": "按分类查询商品", "result": "passed", "actual": "饮料2件；食品含子分类共4件；切换页面后筛选复位"})

        with scenario("管理员采购入库，库存和流水同步"):
            buyer = new_page("admin")
            def cola_stock():
                return buyer.context.request.get(args.url + "/api/inventory?q=P0001").json()["data"][0]["quantity"]
            before = cola_stock()
            buyer.locator('[data-view="purchases"]').click()
            expect(buyer.locator("#page-title")).to_have_text("采购入库")
            expect(buyer.locator("#category-filter")).to_be_hidden()
            buyer.locator("#heading-action").click()
            buyer.locator("#supplier-id").select_option(index=1)
            buyer.locator("#new-purchase-form button[type=submit]").click()
            expect(buyer.locator("#add-purchase-line")).to_be_visible()
            buyer.locator("#purchase-search").fill("P0001")
            buyer.locator("#search-purchase-product").click()
            expect(buyer.locator("#purchase-search-count")).to_contain_text("找到 1 件")
            buyer.locator("#purchase-product").select_option(index=1)
            buyer.locator("#purchase-quantity").fill("5")
            buyer.locator("#purchase-cost").fill("2.00")
            buyer.locator("#add-purchase-line button[type=submit]").click()
            expect(buyer.locator(".order-total")).to_contain_text("10.00")
            assert cola_stock() == before, "草稿不应增加库存"
            buyer.locator("#confirm-purchase").click()
            buyer.locator("#confirm-accept").click()
            expect(buyer.locator(".order-meta")).to_contain_text("已入库")
            assert cola_stock() == before + 5, "确认后库存应增加 5"
            shot(buyer, "23-purchase-received.png", toast="采购已入库")
            buyer.locator("#close-editor").click()
            buyer.locator('[data-view="inventory"]').click()
            sku_row(buyer, "P0001").get_by_role("button", name="查看流水", exact=True).click()
            expect(buyer.locator("#editor")).to_contain_text("采购入库")
            expect(buyer.locator("#editor")).to_contain_text("W8P")
            for username in ("staff", "customer"):
                other_role = new_page(username)
                expect(other_role.locator("#purchases-nav")).to_be_hidden()
                assert other_role.context.request.get(args.url + "/api/purchases").status == 403
            findings.append({"test": "管理员采购入库", "result": "passed", "actual": "草稿不加库存；确认后可乐+5，流水显示采购入库；店员和顾客无入口，接口403"})

        with scenario("商品超过100件时订单详情仍可选择全部商品"):
            clerk = new_page("staff")
            token = admin.context.request.get(args.url + "/api/auth/session").json()["data"]["csrf_token"]
            for index in range(101):
                created = admin.context.request.post(args.url + "/api/products", headers={"X-CSRF-Token": token}, data={
                    "sku": "BULK" + str(index).zfill(3), "product_name": "批量商品" + str(index).zfill(3),
                    "category_id": 5, "sale_price": "1.00", "unit": "件", "status": 1})
                assert created.ok, created.text()
            go(clerk, "orders", "销售订单", "/api/orders?")
            clerk.locator("#heading-action").click()
            expect(clerk.locator("#line-product")).to_be_visible()
            expect(clerk.locator("#line-product option").filter(has_text="批量商品100")).to_have_count(1)
            findings.append({"test": "商品超过100件时可选商品完整", "result": "passed", "actual": "共107件在售商品，订单详情下拉框包含最后一件“批量商品100”"})
        for opened in contexts:
            opened.close()
        if errors:
            failures.append("无未捕获JavaScript异常")
            findings.append({"test": "浏览器脚本运行", "result": "failed", "actual": errors[0][:300]})
        else:
            findings.append({"test": "浏览器脚本运行", "result": "passed", "actual": "无未捕获JavaScript异常"})
        context.close()
        browser.close()
    (output / "browser-results.json").write_text(json.dumps({"results": findings, "javascript_errors": errors}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if failures:
        print(json.dumps({"browser_checks": len(findings), "failed": failures}, ensure_ascii=False))
        sys.exit(1)
    print(json.dumps({"browser_checks": len(findings), "result": "passed"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
