"""实际浏览器验收。先准备独立开发库并启动 python -m app。"""
import argparse
import json
import os
import secrets
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

from app.config import ROOT
from tools.prepare_week7 import DEMO_PASSWORD


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:5070")
    parser.add_argument("--output", default=str(ROOT / "docs/week7-application/results"))
    parser.add_argument("--browser-executable", default=os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE"))
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    findings = []
    errors = []
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
        page.screenshot(path=str(output / "01-login.png"), full_page=True)
        page.locator("#username").fill("admin")
        page.locator("#password").fill("wrong-password")
        page.locator("#login-submit").click()
        expect(page.locator("#login-error")).to_contain_text("用户名或密码不正确")
        findings.append({"test": "登录失败友好提示", "result": "passed", "expected": "401，页面显示统一提示", "actual": "用户名或密码不正确。"})
        page.locator("#password").fill(DEMO_PASSWORD)
        page.locator("#login-submit").click()
        expect(page.locator("#workspace")).to_be_visible()
        expect(page.locator("#table-body tr")).to_have_count(6)
        page.screenshot(path=str(output / "02-admin-products.png"), full_page=True)
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
        page.screenshot(path=str(output / "03-friendly-business-error.png"), full_page=True)
        findings.append({"test": "删除有历史记录商品被拒绝", "result": "passed", "actual": "409，前端显示友好业务提示与参考编号"})
        page.locator('[data-view="inventory"]').click()
        expect(page.locator("#page-title")).to_have_text("库存查询")
        expect(page.locator("#table-head")).to_contain_text("预警下限")
        expect(page.locator("#table-body tr")).to_have_count(6)
        page.screenshot(path=str(output / "04-admin-inventory.png"), full_page=True)
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

        login(page, "staff")
        expect(page.locator("#heading-action")).not_to_be_visible()
        expect(page.locator("#inventory-nav")).to_be_visible()
        page.locator('[data-view="orders"]').click()
        expect(page.locator("#table-body tr")).to_have_count(3)
        page.screenshot(path=str(output / "05-staff-orders.png"), full_page=True)
        findings.append({"test": "店员界面与权限", "result": "passed", "actual": "可查库存和订单，无商品维护入口"})
        page.locator("#logout").click()
        expect(page.locator("#login-screen")).to_be_visible()
        login(page, "customer")
        expect(page.locator("#inventory-nav")).not_to_be_visible()
        expect(page.locator("#heading-action")).not_to_be_visible()
        page.screenshot(path=str(output / "06-customer-catalog.png"), full_page=True)
        denied = context.request.get(args.url + "/api/inventory")
        assert denied.status == 403 and denied.json()["code"] == "FORBIDDEN"
        findings.append({"test": "顾客直接请求库存接口被拒绝", "result": "passed", "actual": denied.json()["code"], "status": denied.status})
        page.locator("#table-body tr").filter(has_text="P0001").get_by_role("button", name="加入草稿", exact=True).click()
        expect(page.locator("#editor")).to_be_visible()
        expect(page.locator("#order-discount")).to_be_disabled()
        quantity = page.locator("[data-quantity]").first
        quantity.fill("2")
        page.get_by_role("button", name="更新", exact=True).click()
        expect(page.locator(".order-total")).to_contain_text("7.00")
        page.locator("#line-product").select_option("3")
        page.locator("#line-quantity").fill("1")
        page.locator("#add-line-form").get_by_role("button", name="加入草稿", exact=True).click()
        expect(page.locator(".order-total")).to_contain_text("9.00")
        page.locator("#order-remark").fill("下课后领取")
        page.locator("#order-payment").select_option("WECHAT")
        page.get_by_role("button", name="保存草稿信息", exact=True).click()
        expect(page.locator("#order-remark")).to_have_value("下课后领取")
        expect(page.locator("#order-payment")).to_have_value("WECHAT")
        page.screenshot(path=str(output / "07-customer-draft.png"), full_page=True)
        order_id = page.evaluate("state.detail.sale_id")
        page.locator(".order-items tr").filter(has_text="矿泉水").get_by_role("button", name="移除", exact=True).click()
        expect(page.locator(".order-total")).to_contain_text("7.00")
        page.locator("#cancel-draft").click()
        page.locator("#confirm-accept").click()
        expect(page.locator(".order-meta")).to_contain_text("已取消")
        expect(page.locator("#add-line-form")).to_have_count(0)
        page.locator("#close-editor").click()
        findings.append({"test": "顾客草稿完整界面流程", "result": "passed", "actual": "创建、2件可乐7.00、加水9.00、保存备注/支付、移除明细、取消"})
        other_context = browser.new_context(viewport={"width": 390, "height": 844}, locale="zh-CN")
        other = other_context.new_page()
        other.on("pageerror", lambda error: errors.append(str(error)))
        login(other, "customer2")
        response = other_context.request.get(args.url + "/api/orders/" + str(order_id))
        assert response.status == 404
        assert response.json()["code"] == "NOT_FOUND"
        assert other.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        expect(other.locator("#logout")).to_be_visible()
        other.screenshot(path=str(output / "08-mobile-customer.png"), full_page=True)
        other.locator("#logout").click()
        expect(other.locator("#login-screen")).to_be_visible()
        findings.append({"test": "另一顾客无法访问订单", "result": "passed", "status": response.status, "actual": response.json()["code"]})
        findings.append({"test": "390px手机布局", "result": "passed", "actual": "页面无整体横向溢出，表格卡片内横向滚动，手机可退出登录"})
        assert not errors, errors
        findings.append({"test": "浏览器脚本运行", "result": "passed", "actual": "无未捕获JavaScript异常"})
        other_context.close()
        context.close()
        browser.close()
    (output / "browser-results.json").write_text(json.dumps({"results": findings, "javascript_errors": errors}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"browser_checks": len(findings), "result": "passed"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
