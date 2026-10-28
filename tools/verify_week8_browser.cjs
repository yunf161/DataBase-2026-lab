"use strict";

// 第八周端到端验收：在隔离数据库上操作真实页面和浏览器。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {chromium} = require("playwright");

async function main() {
  const url = process.argv[2];
  const output = process.argv[3];
  assert(url && output, "用法：node tools/verify_week8_browser.cjs URL 输出目录");
  fs.mkdirSync(output, {recursive: true});
  const browser = await chromium.launch({
    headless: true,
    ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? {executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE} : {})
  });
  const context = await browser.newContext({viewport: {width: 1440, height: 1000}, locale: "zh-CN"});
  const page = await context.newPage();
  const errors = [];
  const checks = [];
  page.on("pageerror", error => errors.push(error.message));
  async function login(username) {
    await page.locator("#username").fill(username);
    await page.locator("#password").fill(process.env.CAMPUS_DEMO_PASSWORD || "Campus2026!");
    await page.locator("#login-submit").click();
    await page.locator("#workspace").waitFor({state: "visible"});
    await page.locator("#table-body tr").first().waitFor();
  }
  async function logout() {
    await page.locator("#logout").click();
    await page.locator("#login-screen").waitFor({state: "visible"});
  }
  try {
    await page.goto(url, {waitUntil: "networkidle"});
    await login("admin");
    assert.equal(await page.locator("#purchases-nav").isVisible(), true);
    await page.locator("#purchases-nav").click();
    await page.waitForFunction(() => document.querySelector("#page-title")?.textContent === "采购入库" && document.querySelector("#heading-action")?.textContent.includes("采购"));
    await page.locator("#heading-action").click();
    await page.locator("#supplier-id").selectOption("1");
    await page.getByRole("button", {name: "建立采购单"}).click();
    await page.locator("#add-purchase-line").waitFor();
    await page.locator("#purchase-search").fill("W8UI101");
    await page.getByRole("button", {name: "搜索商品"}).click();
    await page.waitForFunction(() => Array.from(document.querySelectorAll("#purchase-product option")).some(option => option.textContent.includes("W8UI101")));
    const foundProductId = await page.locator("#purchase-product option").filter({hasText: "W8UI101"}).getAttribute("value");
    await page.locator("#purchase-product").selectOption(foundProductId);
    checks.push("超过首批100件的商品可按编号搜索选择");
    await page.locator("#purchase-search").fill("");
    await page.getByRole("button", {name: "搜索商品"}).click();
    await page.waitForFunction(() => document.querySelector("#purchase-product option[value='1']"));
    for (const [index, product, quantity, cost] of [[1, "1", "3", "2.00"], [2, "2", "4", "1.50"]]) {
      await page.waitForFunction(() => !document.querySelector("#add-purchase-line button[type=submit]").disabled);
      await page.locator("#purchase-product").selectOption(product);
      await page.locator("#purchase-quantity").fill(quantity);
      await page.locator("#purchase-cost").fill(cost);
      assert.equal(await page.locator("#add-purchase-line").evaluate(form => form.checkValidity()), true);
      await Promise.all([
        page.waitForResponse(response => response.url().endsWith("/items") && response.request().method() === "POST"),
        page.getByRole("button", {name: "加入采购单"}).click()
      ]);
      await page.waitForFunction(expected => document.querySelectorAll("#editor-content .order-items tbody tr").length === expected, index);
    }
    assert.equal(await page.locator("#editor-content .order-items tbody tr").count(), 2);
    await page.screenshot({path: path.join(output, "00-purchase-draft.png"), fullPage: true});
    await page.setViewportSize({width: 390, height: 844});
    await page.screenshot({path: path.join(output, "00-purchase-draft-mobile.png"), fullPage: true});
    await page.locator("#confirm-purchase").scrollIntoViewIfNeeded();
    await page.screenshot({path: path.join(output, "00-purchase-draft-mobile-bottom.png")});
    assert.equal(await page.locator("#confirm-purchase").isVisible(), true);
    await page.setViewportSize({width: 1440, height: 1000});
    await page.locator("#confirm-purchase").click();
    await page.locator("#confirm-accept").click();
    await page.locator("#confirm-purchase").waitFor({state: "hidden"});
    await page.locator("#editor .badge").filter({hasText: "已入库"}).waitFor();
    checks.push("管理员建立双商品采购并确认入库");
    await page.screenshot({path: path.join(output, "01-purchase-received.png"), fullPage: true});

    await page.locator("#close-editor").click();
    await page.locator("#editor").waitFor({state: "hidden"});
    await page.locator("#inventory-nav").click();
    await page.waitForFunction(() => document.querySelector("#page-title")?.textContent === "库存查询" && document.querySelector("#table-body tr"));
    const inventoryRow = page.locator("#table-body tr").filter({hasText: "P0001"});
    await inventoryRow.getByRole("button", {name: "盘点调整"}).click();
    await page.locator("#stocktake-delta").fill("-2");
    await page.locator("#stocktake-reason").fill("第八周浏览器盘点测试");
    await page.getByRole("button", {name: "确认调整"}).click();
    await page.locator("#confirm-accept").click();
    await page.locator("#editor").waitFor({state: "hidden"});
    checks.push("管理员盘点并填写原因");
    await page.screenshot({path: path.join(output, "02-stocktake.png")});
    await page.locator("#table-body tr").filter({hasText: "P0001"}).getByRole("button", {name: "盘点调整"}).click();
    await page.locator("#stocktake-delta").fill("-999999");
    await page.locator("#stocktake-reason").fill("验证库存不足错误提示");
    await page.getByRole("button", {name: "确认调整"}).click();
    await page.locator("#confirm-accept").click();
    await page.locator("#editor-error").waitFor({state: "visible"});
    assert.equal((await page.locator("#editor-error").textContent()).includes("SQL Server"), false);
    checks.push("库存不足时页面展示统一错误，不泄露SQL原文");
    await page.screenshot({path: path.join(output, "02-stocktake-error.png")});
    await page.locator("#close-editor").click();
    await logout();

    await login("staff");
    assert.equal(await page.locator("#purchases-nav").isVisible(), false);
    await page.locator('[data-view="orders"]').click();
    await page.waitForFunction(() => document.querySelector("#page-title")?.textContent === "销售订单");
    await page.locator("#heading-action").click();
    await page.locator("#line-product").selectOption("1");
    await page.locator("#line-quantity").fill("2");
    await Promise.all([
      page.waitForResponse(response => /\/orders\/\d+\/items$/.test(response.url()) && response.request().method() === "POST"),
      page.getByRole("button", {name: "加入草稿"}).click()
    ]);
    await page.waitForFunction(() => document.querySelectorAll("#editor-content .order-items tbody tr").length === 1);
    await page.waitForFunction(() => !document.querySelector("#complete-sale").disabled);
    await page.waitForFunction(() => document.querySelector("#toast")?.textContent.includes("商品已加入草稿"));
    await page.locator("#order-payment").selectOption("WECHAT");
    await page.locator("#order-discount").fill("1.00");
    await page.locator("#order-remark").fill("浏览器结算测试");
    await page.locator("#complete-sale").click();
    const [completionResponse] = await Promise.all([
      page.waitForResponse(response => /\/orders\/\d+\/complete$/.test(response.url()) && response.request().method() === "POST"),
      page.locator("#confirm-accept").click()
    ]);
    const completed = (await completionResponse.json()).data;
    assert.equal(completed.payment_method, "WECHAT");
    assert.equal(completed.discount_amount, "1.00");
    assert.equal(completed.remark, "浏览器结算测试");
    await page.locator("#complete-sale").waitFor({state: "hidden"});
    await page.locator("#editor .badge").filter({hasText: "已完成"}).waitFor();
    checks.push("店员销售结算，订单状态改为已完成");
    await page.screenshot({path: path.join(output, "03-sale-completed.png"), fullPage: true});
    await page.locator("#close-editor").click();
    await page.locator("#editor").waitFor({state: "hidden"});
    await logout();

    await login("customer");
    assert.equal(await page.locator("#purchases-nav").isVisible(), false);
    assert.equal(await page.locator("#inventory-nav").isVisible(), false);
    await page.locator('[data-view="orders"]').click();
    await page.waitForFunction(() => document.querySelector("#page-title")?.textContent === "我的订单");
    await page.locator("#heading-action").click();
    assert.equal(await page.locator("#complete-sale").count(), 0);
    const forbidden = await page.evaluate(async () => {
      const response = await fetch("/api/purchases", {credentials: "same-origin"});
      return {status: response.status, code: (await response.json()).code};
    });
    assert.deepEqual(forbidden, {status: 403, code: "FORBIDDEN"});
    checks.push("顾客无采购和结算入口，直接读取采购接口返回403");
    await page.locator("#close-editor").click();
    await page.setViewportSize({width: 390, height: 844});
    await page.screenshot({path: path.join(output, "04-customer-mobile.png"), fullPage: true});
    const failingPage = await context.newPage();
    await failingPage.route("**/api/categories", route => route.abort());
    await failingPage.goto(url, {waitUntil: "networkidle"});
    await failingPage.locator("#login-screen").waitFor({state: "visible", timeout: 5000});
    await failingPage.locator("#login-error").waitFor({state: "visible", timeout: 5000});
    checks.push("初始化数据读取失败后返回可重试登录页，不出现空白页");
    await failingPage.close();
    assert.equal(errors.length, 0, "页面存在 JavaScript 错误：" + errors.join("；"));
    fs.writeFileSync(path.join(output, "browser-results.json"), JSON.stringify({checks, javascript_errors: errors}, null, 2) + "\n");
    console.log(JSON.stringify({checks, javascript_errors: errors}));
  } finally {
    await browser.close();
  }
}

main().catch(error => {console.error(error); process.exitCode = 1;});
