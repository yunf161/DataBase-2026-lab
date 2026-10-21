"use strict";
const $ = (id) => document.getElementById(id);
const state = {user: null, csrf: "", view: "products", page: 1, pageSize: 10, total: 0, rows: [], categories: [], detail: null, catalog: []};
const roleNames = {ADMIN: "店铺管理员", STAFF: "值班店员", CUSTOMER: "校园顾客"};
const statusNames = {DRAFT: "草稿待处理", COMPLETED: "已完成", CANCELLED: "已取消", NORMAL: "库存正常", LOW_STOCK: "低于预警", OUT_OF_STOCK: "暂无库存"};
const escapeHTML = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[char]));
const price = (value) => Number(value || 0).toFixed(2);
const categoryOptions = (selected) => state.categories.map((item) => '<option value="' + item.category_id + '"' + (item.category_id === Number(selected) ? " selected" : "") + ">" + escapeHTML(item.category_name) + "</option>").join("");
const badge = (label, color) => '<span class="badge ' + color + '">' + escapeHTML(label) + "</span>";
let toastTimer;
function toast(message) { $("toast").textContent = message; $("toast").hidden = false; clearTimeout(toastTimer); toastTimer = setTimeout(() => {$("toast").hidden = true;}, 4200); }
function showError(id, error) {
  const element = $(id);
  element.textContent = error.message + (error.requestId ? "（参考编号：" + error.requestId.slice(0, 10) + "）" : "");
  element.hidden = false;
}
async function api(path, options = {}) {
  const headers = {"Accept": "application/json"};
  if (options.body !== undefined) headers["Content-Type"] = "application/json";
  if (options.method && !["GET", "HEAD"].includes(options.method)) headers["X-CSRF-Token"] = state.csrf;
  let response;
  try { response = await fetch("/api" + path, {...options, headers, body: options.body === undefined ? undefined : JSON.stringify(options.body)}); }
  catch { throw new Error("暂时无法连接，请检查网络后重试。"); }
  let payload;
  try { payload = await response.json(); } catch { throw new Error("服务暂时无法处理请求，请稍后重试。"); }
  if (!payload.ok) {
    if (response.status === 401 && state.user && payload.code === "AUTH_REQUIRED") {
      state.user = null; $("workspace").hidden = true; $("login-screen").hidden = false; $("editor").close();
    }
    const error = new Error(payload.message || "操作未完成，请稍后重试。");
    error.requestId = payload.request_id;
    error.code = payload.code;
    throw error;
  }
  if (payload.data?.csrf_token) state.csrf = payload.data.csrf_token;
  return payload.data;
}
async function busy(button, action, errorId = "page-error") {
  if (button.disabled) return;
  button.disabled = true;
  $(errorId).hidden = true;
  try { await action(); } catch (error) { showError(errorId, error); }
  finally {
    if (button.id === "previous-page") button.disabled = state.view === "inventory" || state.page <= 1;
    else if (button.id === "next-page") button.disabled = state.view === "inventory" || state.page * state.pageSize >= state.total;
    else button.disabled = false;
  }
}
function summary(cards) {
  $("summary").innerHTML = cards.map((card, index) => '<div class="summary-card"><div><span class="summary-label">' + escapeHTML(card[0]) + '</span><span class="summary-number">' + escapeHTML(card[1]) + '<span class="summary-unit">' + escapeHTML(card[2]) + '</span></span></div><span class="summary-icon">' + ["▦", "▤", "▧"][index] + "</span></div>").join("");
}
function productCell(row) {
  return '<div class="product-cell"><span class="product-avatar palette-' + (row.product_id % 6) + '">' + escapeHTML(row.product_name.slice(0, 1)) + '</span><div><span class="product-title">' + escapeHTML(row.product_name) + '</span><span class="product-subtitle">' + escapeHTML(row.specification || row.unit || row.sku) + "</span></div></div>";
}
function actionButton(action, id, label, danger = false) {
  return '<button class="link-button' + (danger ? " danger-text" : "") + '" data-action="' + action + '" data-id="' + id + '">' + label + "</button>";
}
async function enterWorkspace() {
  $("login-screen").hidden = true; $("workspace").hidden = false;
  $("display-name").textContent = state.user.display_name;
  $("role-name").textContent = roleNames[state.user.role];
  $("avatar").textContent = state.user.display_name.slice(0, 1);
  $("inventory-nav").hidden = state.user.role === "CUSTOMER";
  $("products-nav-label").textContent = state.user.role === "ADMIN" ? "商品管理" : "商品货架";
  $("orders-nav-label").textContent = state.user.role === "CUSTOMER" ? "我的订单" : "销售订单";
  state.categories = await api("/categories");
  await activate("products");
}
async function activate(view) {
  state.view = view; state.page = 1;
  $("page-error").hidden = true;
  document.querySelectorAll("[data-view]").forEach((button) => button.classList.toggle("active", button.dataset.view === view));
  const customer = state.user.role === "CUSTOMER";
  const config = {
    products: [state.user.role === "ADMIN" ? "商品管理" : "商品货架", "PRODUCTS & SHELVES", customer ? "挑选校园里的日常好物，随时查看自己的订单。" : "每一件日常好物，都值得被好好打理。", "搜索商品名称或编号"],
    inventory: ["库存查询", "STOCK & SUPPLIES", "及时关注货架余量，让每一份需要都有着落。", "搜索商品名称或编号"],
    orders: [customer ? "我的订单" : "销售订单", "ORDERS & DAILY BUSINESS", customer ? "属于你的每一笔订单，都有清晰的来处。" : "查看订单与明细，有序处理每一份草稿。", "搜索订单编号"]
  }[view];
  $("page-title").textContent = config[0]; $("breadcrumb-title").textContent = config[0];
  $("page-eyebrow").textContent = config[1]; $("page-description").textContent = config[2];
  $("search").placeholder = config[3]; $("search").value = "";
  $("heading-action").hidden = !(view === "products" && state.user.role === "ADMIN") && view !== "orders";
  $("heading-action").textContent = view === "orders" ? "＋ 新建草稿" : "＋ 新增商品";
  const filters = view === "products" ? (customer ? [["1", "在售商品"]] : [["all", "全部状态"], ["1", "在售"], ["0", "已停用"]]) :
    view === "orders" ? [["", "全部状态"], ["DRAFT", "草稿"], ["COMPLETED", "已完成"], ["CANCELLED", "已取消"]] :
    [["", "全部库存"], ["NORMAL", "库存正常"], ["LOW_STOCK", "低于预警"], ["OUT_OF_STOCK", "暂无库存"]];
  $("status-filter").innerHTML = filters.map(([value, label]) => '<option value="' + value + '">' + label + "</option>").join("");
  $("page-tip").textContent = view === "orders" ? "草稿尚未结算，不扣减库存；已完成订单保持历史记录。" : view === "inventory" ? "库存数量随采购和销售变化，预警下限可由管理员维护。" : "及时维护商品信息，让每一次选购都更安心。";
  await loadList();
}
async function loadList() {
  const params = new URLSearchParams({q: $("search").value, page: state.page, page_size: state.pageSize});
  params.set(state.view === "inventory" ? "stock_status" : "status", $("status-filter").value);
  const data = await api("/" + state.view + "?" + params);
  state.rows = Array.isArray(data) ? data : data.items;
  state.total = Array.isArray(data) ? data.length : data.total;
  const heads = state.view === "products" ? ["商品", "商品编号", "分类", "售价", "可售库存", "状态", "操作"] :
    state.view === "inventory" ? ["商品名称", "商品编号", "分类", "当前库存", "预警下限", "库存状态", "操作"] :
    ["订单编号", "创建时间", "状态", "明细合计", "优惠金额", "操作"];
  $("table-head").innerHTML = "<tr>" + heads.map((item) => "<th>" + item + "</th>").join("") + "</tr>";
  $("table-body").innerHTML = state.rows.length ? state.rows.map((row) => {
    if (state.view === "products") {
      const actions = state.user.role === "ADMIN" ? actionButton("edit-product", row.product_id, "编辑") + actionButton("delete-product", row.product_id, "删除", true) :
        row.status ? actionButton("shop", row.product_id, "加入草稿") : "—";
      return "<tr><td>" + productCell(row) + "</td><td>" + escapeHTML(row.sku) + '</td><td><span class="category-pill">' + escapeHTML(row.category_name) + '</span></td><td class="price"><span>¥</span>' + price(row.sale_price) + '</td><td class="' + (row.quantity === 0 ? "stock-zero" : "") + '">' + row.quantity + " " + escapeHTML(row.unit) + "</td><td>" + badge(row.status ? "在售" : "已停用", row.status ? "green" : "gray") + "</td><td>" + actions + "</td></tr>";
    }
    if (state.view === "inventory") {
      return "<tr><td>" + escapeHTML(row.product_name) + "</td><td>" + escapeHTML(row.sku) + "</td><td>" + escapeHTML(row.category_name) + '</td><td class="price">' + row.quantity + "</td><td>" + row.min_quantity + "</td><td>" + badge(statusNames[row.stock_status], row.stock_status === "NORMAL" ? "green" : "amber") + "</td><td>" + (state.user.role === "ADMIN" ? actionButton("minimum", row.product_id, "设置预警") : "—") + "</td></tr>";
    }
    return "<tr><td>" + escapeHTML(row.sale_no) + "</td><td>" + escapeHTML(row.created_at.replace("T", " ").slice(0, 16)) + "</td><td>" + badge(statusNames[row.status], row.status === "DRAFT" ? "amber" : row.status === "COMPLETED" ? "green" : "gray") + '</td><td class="price"><span>¥</span>' + price(row.draft_amount) + "</td><td>¥ " + price(row.discount_amount) + "</td><td>" + actionButton("detail", row.sale_id, "查看明细") + "</td></tr>";
  }).join("") : '<tr><td class="empty" colspan="' + heads.length + '"><strong>这里还没有记录</strong>试试调整筛选条件，或新建一份草稿。</td></tr>';
  if (state.view === "products") summary([["筛选商品", state.total, "件"], ["本页在售", state.rows.filter((p) => p.status).length, "件"], ["商品分类", state.categories.length, "类"]]);
  else if (state.view === "inventory") summary([["筛选商品", state.total, "件"], ["当前库存合计", state.rows.reduce((n, p) => n + p.quantity, 0), "件"], ["需关注库存", state.rows.filter((p) => p.stock_status !== "NORMAL").length, "件"]]);
  else summary([["筛选订单", state.total, "笔"], ["本页待处理", state.rows.filter((p) => p.status === "DRAFT").length, "笔"], ["本页已完成", state.rows.filter((p) => p.status === "COMPLETED").length, "笔"]]);
  $("table-count").textContent = "共 " + state.total + " 条记录" + (state.view === "inventory" ? "" : " · 每页 " + state.pageSize + " 条");
  $("page-number").textContent = state.page;
  $("previous-page").disabled = state.view === "inventory" || state.page <= 1;
  $("next-page").disabled = state.view === "inventory" || state.page * state.pageSize >= state.total;
}
function openEditor(title, content, wide = false) {
  $("editor-title").textContent = title; $("editor-content").innerHTML = content;
  $("editor-error").hidden = true; $("editor").classList.toggle("wide", wide);
  if (!$("editor").open) $("editor").showModal();
}
function confirmation(title, description) {
  $("confirm-title").textContent = title; $("confirm-description").textContent = description;
  $("confirmation").showModal();
  return new Promise((resolve) => {
    $("confirm-cancel").onclick = () => {$("confirmation").close(); resolve(false);};
    $("confirm-accept").onclick = () => {$("confirmation").close(); resolve(true);};
    $("confirmation").oncancel = () => resolve(false);
  });
}
function productEditor(product = null) {
  openEditor(product ? "编辑商品" : "新增商品",
    '<form id="product-form"><div class="form-grid"><div><label for="p-sku">商品编号 *</label><input id="p-sku" maxlength="30" pattern="[A-Za-z0-9_-]+" required value="' + escapeHTML(product?.sku || "") + '"></div><div><label for="p-barcode">商品条码</label><input id="p-barcode" maxlength="32" pattern="[A-Za-z0-9_-]*" value="' + escapeHTML(product?.barcode || "") + '"></div><div class="span-two"><label for="p-name">商品名称 *</label><input id="p-name" maxlength="100" required value="' + escapeHTML(product?.product_name || "") + '"></div><div><label for="p-category">商品分类 *</label><select id="p-category">' + categoryOptions(product?.category_id) + '</select></div><div><label for="p-price">售价（元）*</label><input id="p-price" type="number" step=".01" min="0" max="99999999.99" required value="' + escapeHTML(product?.sale_price || "") + '"></div><div><label for="p-spec">商品规格</label><input id="p-spec" maxlength="100" value="' + escapeHTML(product?.specification || "") + '"></div><div><label for="p-unit">计量单位 *</label><input id="p-unit" maxlength="20" required value="' + escapeHTML(product?.unit || "件") + '"></div><div class="span-two"><label for="p-status">商品状态</label><select id="p-status"><option value="1">在售</option><option value="0">已停用</option></select></div></div><p class="helper">新商品初始库存为零。有库存或历史业务记录的商品，请选择停用以保留记录。</p><div class="dialog-actions"><button type="submit" class="primary">保存商品</button></div></form>');
  $("p-status").value = Number(product?.status ?? 1);
  $("product-form").onsubmit = (event) => {
    event.preventDefault();
    busy(event.submitter, async () => {
      const data = {sku: $("p-sku").value, barcode: $("p-barcode").value || null, product_name: $("p-name").value, category_id: Number($("p-category").value), sale_price: $("p-price").value, specification: $("p-spec").value || null, unit: $("p-unit").value, status: Number($("p-status").value)};
      await api("/products" + (product ? "/" + product.product_id : ""), {method: product ? "PUT" : "POST", body: data});
      $("editor").close(); toast("商品信息已保存。"); await loadList();
    }, "editor-error");
  };
}
function minimumEditor(row) {
  openEditor("设置库存预警", '<form id="minimum-form"><p class="muted">' + escapeHTML(row.product_name) + ' · 当前库存 ' + row.quantity + '</p><label for="minimum-value">预警下限</label><input id="minimum-value" type="number" min="0" max="1000000" required value="' + row.min_quantity + '"><p class="helper">只调整提醒阈值，不改变实际库存。</p><div class="dialog-actions"><button type="submit" class="primary">保存设置</button></div></form>');
  $("minimum-form").onsubmit = (event) => {event.preventDefault(); busy(event.submitter, async () => {
    await api("/inventory/" + row.product_id, {method: "PATCH", body: {min_quantity: Number($("minimum-value").value)}});
    $("editor").close(); toast("库存预警已更新。"); await loadList();
  }, "editor-error");};
}
function paymentOptions(selected) {
  return [["CASH", "现金"], ["WECHAT", "微信"], ["ALIPAY", "支付宝"], ["BANK_CARD", "银行卡"]].map(([value, label]) => '<option value="' + value + '"' + (value === selected ? " selected" : "") + ">" + label + "</option>").join("");
}
async function orderDetail(saleId) {
  const [order, catalog] = await Promise.all([api("/orders/" + saleId), api("/products?status=1&page_size=100")]);
  state.detail = order; state.catalog = catalog.items;
  const editable = order.status === "DRAFT";
  const customer = state.user.role === "CUSTOMER";
  const lines = order.items.length ? order.items.map((item) => '<tr><td>' + escapeHTML(item.product_name) + '<span class="product-subtitle">' + escapeHTML(item.sku) + '</span></td><td>¥ ' + price(item.unit_price) + "</td><td>" + (editable ? '<input aria-label="' + escapeHTML(item.product_name) + '数量" type="number" min="1" max="1000000" value="' + item.quantity + '" data-quantity="' + item.item_id + '">' : item.quantity) + "</td><td>¥ " + price(item.line_amount) + "</td><td>" + (editable ? actionButton("save-line", item.item_id, "更新") + actionButton("remove-line", item.item_id, "移除", true) : "—") + "</td></tr>").join("") :
    '<tr><td colspan="5" class="empty">草稿暂时没有明细，请添加商品。</td></tr>';
  const selectedProducts = new Set(order.items.map((item) => item.product_id));
  const available = catalog.items.filter((product) => !selectedProducts.has(product.product_id));
  openEditor("订单明细", '<div class="order-meta"><span>' + escapeHTML(order.sale_no) + "</span>" + badge(statusNames[order.status], editable ? "amber" : "gray") + '</div><div class="order-message">' + (editable ? "这是一份尚未结算的草稿，暂不扣减库存。确认选购内容后，交由店员受理。" : "此订单已完成或取消，保留原有记录，不再修改明细。") + '</div><div class="order-items"><table><thead><tr><th>商品</th><th>成交单价</th><th>数量</th><th>小计</th><th>操作</th></tr></thead><tbody>' + lines + '</tbody></table></div><p class="order-total">明细合计<strong>¥ ' + price(order.draft_amount) + "</strong></p>" +
    (editable ? '<form id="add-line-form" class="add-item-form"><div><label for="line-product">添加商品</label><select id="line-product" required><option value="">请选择商品</option>' + available.map((product) => '<option value="' + product.product_id + '">' + escapeHTML(product.product_name) + " · ¥" + price(product.sale_price) + "</option>").join("") + '</select></div><div><label for="line-quantity">数量</label><input id="line-quantity" type="number" min="1" max="1000000" value="1" required></div><button type="submit" class="secondary">加入草稿</button></form><form id="order-info-form"><div class="form-grid"><div><label for="order-payment">支付方式</label><select id="order-payment">' + paymentOptions(order.payment_method) + '</select></div><div><label for="order-discount">优惠金额（元）</label><input id="order-discount" type="number" min="0" step=".01" value="' + price(order.discount_amount) + '"' + (customer ? " disabled" : "") + '></div><div class="span-two"><label for="order-remark">备注</label><textarea id="order-remark" maxlength="255" rows="2">' + escapeHTML(order.remark || "") + '</textarea></div></div><div class="dialog-actions"><button id="cancel-draft" type="button" class="secondary">取消这份草稿</button><button type="submit" class="primary">保存草稿信息</button></div></form>' :
      '<p class="helper">备注：' + escapeHTML(order.remark || "暂无") + "</p>"), true);
  if (!editable) return;
  $("add-line-form").onsubmit = (event) => {event.preventDefault(); busy(event.submitter, async () => {
    await api("/orders/" + saleId + "/items", {method: "POST", body: {product_id: Number($("line-product").value), quantity: Number($("line-quantity").value)}});
    await orderDetail(saleId); await loadList(); toast("商品已加入草稿。");
  }, "editor-error");};
  $("order-info-form").onsubmit = (event) => {event.preventDefault(); busy(event.submitter, async () => {
    const data = {payment_method: $("order-payment").value, remark: $("order-remark").value};
    if (!customer) data.discount_amount = $("order-discount").value;
    await api("/orders/" + saleId, {method: "PATCH", body: data});
    await orderDetail(saleId); await loadList(); toast("草稿信息已保存。");
  }, "editor-error");};
  $("cancel-draft").onclick = (event) => busy(event.target, async () => {
    if (!await confirmation("取消草稿订单？", "取消后保留订单记录，不能再修改或加入商品。")) return;
    await api("/orders/" + saleId + "/cancel", {method: "POST", body: {}});
    await orderDetail(saleId); await loadList(); toast("草稿订单已取消。");
  }, "editor-error");
}
async function newDraft(items = []) {
  const order = await api("/orders", {method: "POST", body: {payment_method: "CASH", items}});
  await activate("orders"); await orderDetail(order.sale_id); toast("草稿已创建，尚未扣减库存。");
}
$("login-form").onsubmit = (event) => {
  event.preventDefault();
  busy($("login-submit"), async () => {
    const data = await api("/auth/login", {method: "POST", body: {username: $("username").value, password: $("password").value}});
    state.user = data.user; $("password").value = ""; await enterWorkspace();
  }, "login-error");
};
$("toggle-password").onclick = () => {
  const reveal = $("password").type === "password"; $("password").type = reveal ? "text" : "password";
  $("toggle-password").textContent = reveal ? "隐藏" : "显示"; $("toggle-password").setAttribute("aria-label", reveal ? "隐藏密码" : "显示密码");
};
$("logout").onclick = (event) => busy(event.currentTarget, async () => {
  await api("/auth/logout", {method: "POST", body: {}});
  state.user = null; $("workspace").hidden = true; $("login-screen").hidden = false; $("password").value = ""; $("login-error").hidden = true; toast("已安全退出。");
});
document.querySelectorAll("[data-view]").forEach((button) => button.onclick = () => busy(button, () => activate(button.dataset.view)));
$("filter-form").onsubmit = (event) => {event.preventDefault(); state.page = 1; busy(event.submitter, loadList);};
$("refresh").onclick = (event) => busy(event.currentTarget, loadList);
$("heading-action").onclick = (event) => {
  if (state.view === "products") productEditor();
  else busy(event.currentTarget, () => newDraft());
};
$("previous-page").onclick = (event) => {state.page -= 1; busy(event.currentTarget, loadList);};
$("next-page").onclick = (event) => {state.page += 1; busy(event.currentTarget, loadList);};
$("close-editor").onclick = () => $("editor").close();
$("table-body").onclick = (event) => {
  const button = event.target.closest("[data-action]"); if (!button) return;
  busy(button, async () => {
    const id = Number(button.dataset.id); const row = state.rows.find((item) => (item.product_id || item.sale_id) === id);
    if (button.dataset.action === "edit-product") productEditor(row);
    if (button.dataset.action === "minimum") minimumEditor(row);
    if (button.dataset.action === "detail") await orderDetail(id);
    if (button.dataset.action === "shop") await newDraft([{product_id: id, quantity: 1}]);
    if (button.dataset.action === "delete-product" && await confirmation("删除这个商品？", "仅无业务引用且库存为零的商品可以删除。已有历史记录的商品请改为停用。")) {
      await api("/products/" + id, {method: "DELETE"}); toast("未使用商品已删除。"); await loadList();
    }
  });
};
$("editor-content").onclick = (event) => {
  const button = event.target.closest("[data-action]"); if (!button) return;
  busy(button, async () => {
    const itemId = Number(button.dataset.id); const saleId = state.detail.sale_id;
    if (button.dataset.action === "save-line") {
      const quantity = Number(document.querySelector('[data-quantity="' + itemId + '"]').value);
      await api("/orders/" + saleId + "/items/" + itemId, {method: "PATCH", body: {quantity}});
    } else if (button.dataset.action === "remove-line") {
      await api("/orders/" + saleId + "/items/" + itemId, {method: "DELETE"});
    }
    await orderDetail(saleId); await loadList(); toast("草稿明细已更新。");
  }, "editor-error");
};
(async () => {
  $("login-submit").disabled = true;
  try {
    const data = await api("/auth/session"); state.user = data.user;
    if (state.user) await enterWorkspace();
  } catch (error) { showError("login-error", error); }
  finally { $("login-submit").disabled = false; }
})();
