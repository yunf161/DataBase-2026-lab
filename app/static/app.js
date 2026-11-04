"use strict";
const $ = (id) => document.getElementById(id);
const state = {user: null, csrf: "", view: "products", page: 1, pageSize: 10, total: 0, rows: [], categories: [], detail: null, catalog: []};
const roleNames = {ADMIN: "店铺管理员", STAFF: "值班店员", CUSTOMER: "校园顾客"};
const statusNames = {DRAFT: "草稿待处理", COMPLETED: "已完成", RECEIVED: "已入库", CANCELLED: "已取消", NORMAL: "库存正常", LOW_STOCK: "低于预警", OUT_OF_STOCK: "暂无库存"};
const escapeHTML = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[char]));
const price = (value) => Number(value || 0).toFixed(2);
const categoryOptions = (selected, name) => (selected && name && !state.categories.some((item) => item.category_id === Number(selected)) ? '<option value="' + Number(selected) + '" selected>' + escapeHTML(name) + "（已停用）</option>" : "") + state.categories.map((item) => '<option value="' + item.category_id + '"' + (item.category_id === Number(selected) ? " selected" : "") + ">" + escapeHTML(item.category_name) + "</option>").join("");
const changeTypes = {PURCHASE_IN: "采购入库", SALE_OUT: "销售出库", STOCKTAKE_IN: "盘盈", STOCKTAKE_OUT: "盘亏"};
const orderStatus = (row) => row.status !== "DRAFT" ? statusNames[row.status] : Number(row.is_customer_order) === 1 && !row.submitted_at ? (state.user.role === "CUSTOMER" ? "购物车" : "顾客选购中") : row.submitted_at ? "待受理" : statusNames.DRAFT;
const payable = (row) => row.status === "CANCELLED" ? null : row.status === "COMPLETED" ? row.payable_amount : Number(row.draft_amount) - Number(row.discount_amount);
const signed = (value) => (value > 0 ? "+" : "") + value;
const badge = (label, color) => '<span class="badge ' + color + '">' + escapeHTML(label) + "</span>";
let toastTimer, toastOpen = false;
// 提示条是顶层 popover；有弹窗打开时挂到最上层弹窗内，才不会被模态遮罩挡住或失去焦点外的点击命中。
function placeToast() {
  const box = $("toast"), host = ["confirmation", "editor"].map($).find((dialog) => dialog.open) || document.body;
  if (box.parentElement !== host) host.append(box);
  if (box.matches(":popover-open")) box.hidePopover();
  if (toastOpen) box.showPopover();
}
function toast(message) {
  $("toast").textContent = message; toastOpen = true; placeToast();
  clearTimeout(toastTimer); toastTimer = setTimeout(() => {toastOpen = false; placeToast();}, 4200);
}
function showError(id, error) {
  const element = $(id);
  element.textContent = error.message + (error.requestId ? "（参考编号：" + error.requestId.slice(0, 10) + "）" : "");
  element.hidden = false;
  element.scrollIntoView({block: "center", behavior: "instant"});
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
    if (button.id === "previous-page") button.disabled = ["inventory", "purchases"].includes(state.view) || state.page <= 1;
    else if (button.id === "next-page") button.disabled = ["inventory", "purchases"].includes(state.view) || state.page * state.pageSize >= state.total;
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
  $("login-screen").hidden = true; $("workspace").hidden = true;
  $("display-name").textContent = state.user.display_name;
  $("role-name").textContent = roleNames[state.user.role];
  $("avatar").textContent = state.user.display_name.slice(0, 1);
  $("inventory-nav").hidden = state.user.role === "CUSTOMER";
  $("purchases-nav").hidden = state.user.role !== "ADMIN";
  $("products-nav-label").textContent = state.user.role === "ADMIN" ? "商品管理" : "商品货架";
  $("orders-nav-label").textContent = state.user.role === "CUSTOMER" ? "我的订单" : "销售订单";
  try {
    state.categories = await api("/categories");
    await activate("products");
    $("workspace").hidden = false;
  } catch (error) {
    // 初始数据失败时保留可见的登录页，让用户看到错误并重试。
    $("login-screen").hidden = false;
    throw error;
  }
}
async function activate(view) {
  state.view = view; state.page = 1;
  $("page-error").hidden = true;
  document.querySelectorAll("[data-view]").forEach((button) => button.classList.toggle("active", button.dataset.view === view));
  const customer = state.user.role === "CUSTOMER";
  const config = {
    products: [state.user.role === "ADMIN" ? "商品管理" : "商品货架", "PRODUCTS & SHELVES", customer ? "挑选校园里的日常好物，随时查看自己的订单。" : "每一件日常好物，都值得被好好打理。", "搜索商品名称或编号"],
    inventory: ["库存查询", "STOCK & SUPPLIES", "及时关注货架余量，让每一份需要都有着落。", "搜索商品名称或编号"],
    orders: [customer ? "我的订单" : "销售订单", "ORDERS & DAILY BUSINESS", customer ? "属于你的每一笔订单，都有清晰的来处。" : "查看订单与明细，受理顾客提交的订单并完成结算。", "搜索订单编号"],
    purchases: ["采购入库", "PURCHASES & SUPPLIES", "建立采购草稿，核对商品后确认入库。", "搜索采购编号或供应商"]
  }[view];
  $("page-title").textContent = config[0]; $("breadcrumb-title").textContent = config[0];
  $("page-eyebrow").textContent = config[1]; $("page-description").textContent = config[2];
  $("search").placeholder = config[3]; $("search").value = "";
  $("heading-action").hidden = view === "orders" ? customer : view !== "purchases" && !(view === "products" && state.user.role === "ADMIN");
  $("heading-action").textContent = view === "orders" ? "＋ 新建草稿" : view === "purchases" ? "＋ 新建采购" : "＋ 新增商品";
  const filters = view === "products" ? (customer ? [["1", "在售商品"]] : [["all", "全部状态"], ["1", "在售"], ["0", "已停用"]]) :
    view === "orders" ? [["", "全部状态"], ...(customer ? [] : [["pending", "待受理"]]), ["DRAFT", "草稿"], ["COMPLETED", "已完成"], ["CANCELLED", "已取消"]] :
    view === "purchases" ? [["", "全部状态"], ["DRAFT", "草稿"], ["RECEIVED", "已入库"], ["CANCELLED", "已取消"]] :
    [["", "全部库存"], ["NORMAL", "库存正常"], ["LOW_STOCK", "低于预警"], ["OUT_OF_STOCK", "暂无库存"]];
  $("status-filter").innerHTML = filters.map(([value, label]) => '<option value="' + value + '">' + label + "</option>").join("");
  $("category-filter").innerHTML = '<option value="">全部分类</option>' + categoryOptions();
  $("category-filter").hidden = view !== "products";
  $("page-tip").textContent = view === "orders" ? "库存在店员确认收款并结算时才扣减；已完成订单保持历史记录。" : view === "purchases" ? "采购草稿不增加库存；确认入库后同步生成库存流水。" : view === "inventory" ? "库存数量随采购和销售变化，预警下限可由管理员维护。" : "及时维护商品信息，让每一次选购都更安心。";
  await loadList();
}
async function loadList() {
  if (state.view === "purchases") return loadPurchases();
  const params = new URLSearchParams({q: $("search").value, page: state.page, page_size: state.pageSize});
  if (state.view === "orders" && $("status-filter").value === "pending") params.set("pending", "1");
  else params.set(state.view === "inventory" ? "stock_status" : "status", $("status-filter").value);
  if (state.view === "products" && $("category-filter").value) params.set("category_id", $("category-filter").value);
  const data = await api("/" + state.view + "?" + params);
  state.rows = Array.isArray(data) ? data : data.items;
  state.total = Array.isArray(data) ? data.length : data.total;
  const heads = state.view === "products" ? ["商品", "商品编号", "分类", "售价", "可售库存", "状态", "操作"] :
    state.view === "inventory" ? ["商品名称", "商品编号", "分类", "当前库存", "预警下限", "库存状态", "操作"] :
    ["订单编号", "创建时间", "状态", "明细合计", "应付金额", "优惠金额", "操作"];
  $("table-head").innerHTML = "<tr>" + heads.map((item) => "<th>" + item + "</th>").join("") + "</tr>";
  $("table-body").innerHTML = state.rows.length ? state.rows.map((row) => {
    if (state.view === "products") {
      const actions = state.user.role === "ADMIN" ? actionButton("edit-product", row.product_id, "编辑") + actionButton("delete-product", row.product_id, "删除", true) :
        row.status ? actionButton("shop", row.product_id, state.user.role === "CUSTOMER" ? "加入购物车" : "加入草稿") : "—";
      return "<tr><td>" + productCell(row) + "</td><td>" + escapeHTML(row.sku) + '</td><td><span class="category-pill">' + escapeHTML(row.category_name) + '</span></td><td class="price"><span>¥</span>' + price(row.sale_price) + '</td><td class="' + (row.quantity === 0 ? "stock-zero" : "") + '">' + row.quantity + " " + escapeHTML(row.unit) + "</td><td>" + badge(row.status ? "在售" : "已停用", row.status ? "green" : "gray") + "</td><td>" + actions + "</td></tr>";
    }
    if (state.view === "inventory") {
      return "<tr><td>" + escapeHTML(row.product_name) + "</td><td>" + escapeHTML(row.sku) + "</td><td>" + escapeHTML(row.category_name) + '</td><td class="price">' + row.quantity + "</td><td>" + row.min_quantity + "</td><td>" + badge(statusNames[row.stock_status], row.stock_status === "NORMAL" ? "green" : "amber") + "</td><td>" + (state.user.role === "ADMIN" ? actionButton("minimum", row.product_id, "设置预警") + actionButton("adjust", row.product_id, "调整库存") + actionButton("logs", row.product_id, "查看流水") : "—") + "</td></tr>";
    }
    return "<tr><td>" + escapeHTML(row.sale_no) + "</td><td>" + escapeHTML(row.created_at.replace("T", " ").slice(0, 16)) + "</td><td>" + badge(orderStatus(row), row.status === "DRAFT" ? "amber" : row.status === "COMPLETED" ? "green" : "gray") + '</td><td class="price"><span>¥</span>' + price(row.draft_amount) + '</td><td class="price">' + (payable(row) === null ? "—" : "<span>¥</span>" + price(payable(row))) + "</td><td>¥ " + price(row.discount_amount) + "</td><td>" + actionButton("detail", row.sale_id, "查看明细") + "</td></tr>";
  }).join("") : '<tr><td class="empty" colspan="' + heads.length + '"><strong>这里还没有记录</strong>' + (state.view === "orders" && state.user.role === "CUSTOMER" ? "试试调整筛选条件，或先到商品页加入购物车。" : "试试调整筛选条件，或新建一份草稿。") + "</td></tr>";
  if (state.view === "products") summary([["筛选商品", state.total, "件"], ["本页在售", state.rows.filter((p) => p.status).length, "件"], ["商品分类", state.categories.length, "类"]]);
  else if (state.view === "inventory") summary([["筛选商品", state.total, "件"], ["当前库存合计", state.rows.reduce((n, p) => n + p.quantity, 0), "件"], ["需关注库存", state.rows.filter((p) => p.stock_status !== "NORMAL").length, "件"]]);
  else summary([["筛选订单", state.total, "笔"], ["本页待处理", state.rows.filter((p) => p.status === "DRAFT").length, "笔"], ["本页已完成", state.rows.filter((p) => p.status === "COMPLETED").length, "笔"]]);
  $("table-count").textContent = "共 " + state.total + " 条记录" + (state.view === "inventory" ? "" : " · 每页 " + state.pageSize + " 条");
  $("page-number").textContent = state.page;
  $("previous-page").disabled = state.view === "inventory" || state.page <= 1;
  $("next-page").disabled = state.view === "inventory" || state.page * state.pageSize >= state.total;
}
async function loadPurchases() {
  const all = await api("/purchases");
  const q = $("search").value.trim().toLowerCase();
  const status = $("status-filter").value;
  state.rows = all.filter((row) => (!q || row.purchase_no.toLowerCase().includes(q) || row.supplier_name.toLowerCase().includes(q)) && (!status || row.status === status));
  state.total = state.rows.length;
  $("table-head").innerHTML = "<tr><th>采购编号</th><th>供应商</th><th>创建时间</th><th>状态</th><th>明细合计</th><th>操作</th></tr>";
  $("table-body").innerHTML = state.rows.length ? state.rows.map((row) => "<tr><td>" + escapeHTML(row.purchase_no) + "</td><td>" + escapeHTML(row.supplier_name) + "</td><td>" + escapeHTML(row.order_time.replace("T", " ").slice(0, 16)) + "</td><td>" + badge(statusNames[row.status], row.status === "DRAFT" ? "amber" : row.status === "RECEIVED" ? "green" : "gray") + '</td><td class="price">¥ ' + price(row.draft_amount) + "</td><td>" + actionButton("purchase-detail", row.purchase_id, "查看明细") + "</td></tr>").join("") : '<tr><td class="empty" colspan="6">暂无采购记录。</td></tr>';
  summary([["筛选采购单", state.total, "笔"], ["待确认", state.rows.filter((row) => row.status === "DRAFT").length, "笔"], ["已入库", state.rows.filter((row) => row.status === "RECEIVED").length, "笔"]]);
  $("table-count").textContent = "共 " + state.total + " 条记录";
  $("page-number").textContent = "1";
  $("previous-page").disabled = true; $("next-page").disabled = true;
}
function openEditor(title, content, wide = false) {
  $("editor-title").textContent = title; $("editor-content").innerHTML = content;
  $("editor-error").hidden = true; $("editor").classList.toggle("wide", wide);
  if (!$("editor").open) $("editor").showModal();
  placeToast();
}
function confirmation(title, description) {
  $("confirm-title").textContent = title; $("confirm-description").textContent = description;
  $("confirmation").showModal(); placeToast();
  return new Promise((resolve) => {
    $("confirm-cancel").onclick = () => {$("confirmation").close(); resolve(false);};
    $("confirm-accept").onclick = () => {$("confirmation").close(); resolve(true);};
    $("confirmation").oncancel = () => resolve(false);
  });
}
function productEditor(product = null) {
  openEditor(product ? "编辑商品" : "新增商品",
    '<form id="product-form"><div class="form-grid"><div><label for="p-sku">商品编号 *</label><input id="p-sku" maxlength="30" pattern="[A-Za-z0-9_-]+" required value="' + escapeHTML(product?.sku || "") + '"></div><div><label for="p-barcode">商品条码</label><input id="p-barcode" maxlength="32" pattern="[A-Za-z0-9_-]*" value="' + escapeHTML(product?.barcode || "") + '"></div><div class="span-two"><label for="p-name">商品名称 *</label><input id="p-name" maxlength="100" required value="' + escapeHTML(product?.product_name || "") + '"></div><div><label for="p-category">商品分类 *</label><select id="p-category">' + categoryOptions(product?.category_id, product?.category_name) + '</select></div><div><label for="p-price">售价（元）*</label><input id="p-price" type="number" step=".01" min="0" max="99999999.99" required value="' + escapeHTML(product?.sale_price || "") + '"></div><div><label for="p-spec">商品规格</label><input id="p-spec" maxlength="100" value="' + escapeHTML(product?.specification || "") + '"></div><div><label for="p-unit">计量单位 *</label><input id="p-unit" maxlength="20" required value="' + escapeHTML(product?.unit || "件") + '"></div><div class="span-two"><label for="p-status">商品状态</label><select id="p-status"><option value="1">在售</option><option value="0">已停用</option></select></div></div><p class="helper">新商品初始库存为零。有库存或历史业务记录的商品，请选择停用以保留记录。</p><div class="dialog-actions"><button type="submit" class="primary">保存商品</button></div></form>');
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
function adjustEditor(row) {
  openEditor("调整库存", '<form id="adjust-form"><p class="muted">' + escapeHTML(row.product_name) + " · 当前数量 " + row.quantity + '</p><div class="form-grid"><div class="span-two"><label for="adjust-quantity">新数量 *</label><input id="adjust-quantity" type="number" min="0" max="1000000" step="1" required value="' + row.quantity + '"></div><div class="span-two"><label for="adjust-reason">调整原因 *</label><textarea id="adjust-reason" maxlength="255" rows="2" required></textarea></div></div><p id="adjust-delta" class="helper" aria-live="polite">变化量：0</p><div class="dialog-actions"><button type="submit" class="primary">确认调整</button></div></form>');
  $("adjust-quantity").oninput = () => {$("adjust-delta").textContent = "变化量：" + ($("adjust-quantity").value === "" ? "—" : signed(Number($("adjust-quantity").value) - row.quantity));};
  $("adjust-form").onsubmit = (event) => {event.preventDefault(); busy(event.submitter, async () => {
    await api("/inventory/" + row.product_id + "/quantity", {method: "PATCH", body: {new_quantity: Number($("adjust-quantity").value), reason: $("adjust-reason").value}});
    $("editor").close(); toast("库存数量已调整。"); await loadList();
  }, "editor-error");};
}
async function inventoryLogs(row, page = 1) {
  const size = 10;
  const data = await api("/inventory/" + row.product_id + "/logs?page=" + page + "&page_size=" + size);
  const lines = data.items.length ? data.items.map((log) => "<tr><td>" + escapeHTML(String(log.created_at).replace("T", " ").slice(0, 19)) + "</td><td>" + escapeHTML(Object.hasOwn(changeTypes, log.change_type) ? changeTypes[log.change_type] : log.change_type) + "</td><td>" + signed(log.change_quantity) + "</td><td>" + log.before_quantity + " → " + log.after_quantity + "</td><td>" + escapeHTML(log.business_no || "—") + "</td><td>" + escapeHTML(log.employee_no || "—") + "</td><td>" + escapeHTML(log.remark || "—") + "</td></tr>").join("") :
    '<tr><td colspan="7" class="empty">这个商品还没有库存流水。</td></tr>';
  openEditor("库存流水", '<p class="muted">' + escapeHTML(row.product_name) + " · " + escapeHTML(row.sku) + '</p><div class="order-items log-table"><table><thead><tr><th>时间</th><th>类型</th><th>变化量</th><th>前后数量</th><th>单号</th><th>员工</th><th>备注</th></tr></thead><tbody>' + lines + '</tbody></table></div><div class="log-pager"><button id="log-previous" type="button" class="secondary small">上一页</button><span>第 ' + page + " 页 · 共 " + data.total + ' 条</span><button id="log-next" type="button" class="secondary small">下一页</button></div>', true);
  $("log-previous").disabled = page <= 1; $("log-next").disabled = page * size >= data.total;
  $("log-previous").onclick = (event) => busy(event.currentTarget, () => inventoryLogs(row, page - 1), "editor-error");
  $("log-next").onclick = (event) => busy(event.currentTarget, () => inventoryLogs(row, page + 1), "editor-error");
}
function paymentOptions(selected) {
  return [["CASH", "现金"], ["WECHAT", "微信"], ["ALIPAY", "支付宝"], ["BANK_CARD", "银行卡"]].map(([value, label]) => '<option value="' + value + '"' + (value === selected ? " selected" : "") + ">" + label + "</option>").join("");
}
async function activeProducts() {
  const items = [];
  for (let page = 1; ; page += 1) {
    const data = await api("/products?status=1&page_size=100&page=" + page);
    items.push(...data.items);
    if (!data.items.length || items.length >= data.total) return items;
  }
}
async function orderDetail(saleId, latest = null, notice = "") {
  const [order, catalog] = await Promise.all([latest || api("/orders/" + saleId), activeProducts()]);
  state.detail = order; state.catalog = catalog;
  const customer = state.user.role === "CUSTOMER";
  const draft = order.status === "DRAFT";
  const submitted = draft && Boolean(order.submitted_at);
  const waiting = draft && Number(order.is_customer_order) === 1 && !order.submitted_at;
  const editable = draft && !(customer && submitted);
  const message = !draft ? "此订单已完成或取消，保留原有记录，不再修改明细。" : customer ? (submitted ? "待店员受理。店员结算后订单完成，结算前可以取消订单。" : "这是你的购物车，确认选购内容后点击“提交订单”，库存在店员结算时才扣减。") :
    waiting ? "顾客尚未提交，暂不能结算。顾客提交后才可确认收款。" : submitted ? "顾客已提交，确认收款后完成结算，库存在结算时扣减。" : "这是一份尚未结算的草稿，库存在确认收款并结算时才扣减。";
  const lines = order.items.length ? order.items.map((item) => '<tr><td>' + escapeHTML(item.product_name) + '<span class="product-subtitle">' + escapeHTML(item.sku) + '</span></td><td>¥ ' + price(item.unit_price) + "</td><td>" + (editable ? '<input aria-label="' + escapeHTML(item.product_name) + '数量" type="number" min="1" max="1000000" value="' + item.quantity + '" data-quantity="' + item.item_id + '">' : item.quantity) + "</td><td>¥ " + price(item.line_amount) + "</td><td>" + (editable ? actionButton("save-line", item.item_id, "更新") + actionButton("remove-line", item.item_id, "移除", true) : "—") + "</td></tr>").join("") :
    '<tr><td colspan="5" class="empty">' + (customer ? "购物车" : "草稿") + "暂时没有明细，请添加商品。</td></tr>";
  const selectedProducts = new Set(order.items.map((item) => item.product_id));
  const available = catalog.filter((product) => !selectedProducts.has(product.product_id));
  openEditor("订单明细", '<div class="order-meta"><span>' + escapeHTML(order.sale_no) + "</span>" + badge(orderStatus(order), draft ? "amber" : order.status === "COMPLETED" ? "green" : "gray") + '</div><div class="order-message">' + message + '</div>' + (notice ? '<div class="order-message order-notice" role="status">' + escapeHTML(notice) + "</div>" : "") + '<div class="order-items"><table><thead><tr><th>商品</th><th>成交单价</th><th>数量</th><th>小计</th><th>操作</th></tr></thead><tbody>' + lines + '</tbody></table></div><div class="order-sums"><p class="order-total">明细合计<strong>¥ ' + price(order.draft_amount) + '</strong></p><p class="order-discount">优惠<strong>- ¥ ' + price(order.discount_amount) + '</strong></p><p class="order-payable">应付<strong>' + (payable(order) === null ? "—" : "¥ " + price(payable(order))) + "</strong></p></div>" +
    (editable ? '<form id="add-line-form" class="add-item-form"><div><label for="line-product">添加商品</label><select id="line-product" required><option value="">请选择商品</option>' + available.map((product) => '<option value="' + product.product_id + '">' + escapeHTML(product.product_name) + " · ¥" + price(product.sale_price) + "</option>").join("") + '</select></div><div><label for="line-quantity">数量</label><input id="line-quantity" type="number" min="1" max="1000000" value="1" required></div><button type="submit" class="secondary">' + (customer ? "加入购物车" : "加入草稿") + '</button></form><form id="order-info-form"><div class="form-grid"><div><label for="order-payment">支付方式</label><select id="order-payment">' + paymentOptions(order.payment_method) + '</select></div><div><label for="order-discount">优惠金额（元）</label><input id="order-discount" type="number" min="0" step=".01" value="' + price(order.discount_amount) + '"' + (customer ? " disabled" : "") + '></div><div class="span-two"><label for="order-remark">备注</label><textarea id="order-remark" maxlength="255" rows="2">' + escapeHTML(order.remark || "") + '</textarea>    </div></div><div class="dialog-actions"><button id="cancel-draft" type="button" class="secondary">' + (customer ? "取消订单" : "取消这份草稿") + '</button><button type="submit" class="primary">' + (customer ? "保存信息" : "保存草稿信息") + "</button>" + (customer ? '<button id="submit-order" type="button" class="primary">提交订单</button>' : waiting ? "" : '<button id="settle-order" type="button" class="primary">确认收款并结算</button>') + '</div></form>' :
        '<p class="helper">备注：' + escapeHTML(order.remark || "暂无") + "</p>" + (submitted ? '<div class="dialog-actions"><button id="cancel-draft" type="button" class="secondary">取消订单</button></div>' : "")), true);
      if (submitted) $("cancel-draft").onclick = (event) => cancelDraft(event.currentTarget, saleId);
      if (!editable) return;
  $("add-line-form").onsubmit = (event) => {event.preventDefault(); busy(event.submitter, async () => {
    await api("/orders/" + saleId + "/items", {method: "POST", body: {product_id: Number($("line-product").value), quantity: Number($("line-quantity").value)}});
    await orderDetail(saleId); await loadList(); toast(customer ? "商品已加入购物车。" : "商品已加入草稿。");
  }, "editor-error");};
  $("order-info-form").onsubmit = (event) => {event.preventDefault(); busy(event.submitter, async () => {
    const data = {payment_method: $("order-payment").value, remark: $("order-remark").value};
    if (!customer) data.discount_amount = $("order-discount").value;
    await api("/orders/" + saleId, {method: "PATCH", body: data});
    await orderDetail(saleId); await loadList(); toast(customer ? "信息已保存。" : "草稿信息已保存。");
  }, "editor-error");};
  $("cancel-draft").onclick = (event) => cancelDraft(event.currentTarget, saleId);
  if ($("submit-order")) $("submit-order").onclick = (event) => busy(event.currentTarget, async () => {
    await api("/orders/" + saleId, {method: "PATCH", body: {payment_method: $("order-payment").value, remark: $("order-remark").value}});
    const result = await api("/orders/" + saleId + "/submit", {method: "POST", body: {}});
    if (result.price_changed) {
      await orderDetail(saleId, result.order, "部分商品价格已更新，请确认新的金额后再次提交订单。"); await loadList(); toast("价格已更新，请确认后再提交。"); return;
    }
    await orderDetail(saleId); await loadList(); toast("订单已提交，请等待店员受理。");
  }, "editor-error");
  if ($("settle-order")) $("settle-order").onclick = (event) => busy(event.currentTarget, async () => {
    if (!await confirmation("确认收款并结算？", "结算后将扣减库存，订单变为已完成，不能再修改。")) return;
    const remark = $("order-remark").value;
    if (remark.trim() !== (order.remark || "").trim()) await api("/orders/" + saleId, {method: "PATCH", body: {remark}});
    await api("/orders/" + saleId + "/settle", {method: "POST", body: {payment_method: $("order-payment").value, discount_amount: $("order-discount").value}});
    await orderDetail(saleId); await loadList(); toast("订单已结算，库存已扣减。");
  }, "editor-error");
}
function cancelDraft(button, saleId) {
  const customer = state.user.role === "CUSTOMER";
  return busy(button, async () => {
    if (!await confirmation(customer ? "取消订单？" : "取消草稿订单？", "取消后保留订单记录，不能再修改或加入商品。")) return;
    await api("/orders/" + saleId + "/cancel", {method: "POST", body: {}});
    await orderDetail(saleId); await loadList(); toast(customer ? "订单已取消。" : "草稿订单已取消。");
  }, "editor-error");
}
async function newPurchase() {
  const suppliers = await api("/suppliers");
  openEditor("新建采购草稿", '<form id="new-purchase-form"><label for="supplier-id">供应商 *</label><select id="supplier-id" required><option value="">请选择供应商</option>' + suppliers.map((supplier) => '<option value="' + supplier.supplier_id + '">' + escapeHTML(supplier.supplier_name) + "</option>").join("") + '</select><p class="helper">新建后可逐项添加商品，确认前库存不会变化。</p><div class="dialog-actions"><button type="submit" class="primary">建立采购单</button></div></form>');
  $("new-purchase-form").onsubmit = (event) => {event.preventDefault(); busy(event.submitter, async () => {
    const order = await api("/purchases", {method: "POST", body: {supplier_id: Number($("supplier-id").value)}});
    await activate("purchases"); await purchaseDetail(order.purchase_id); toast("采购草稿已创建。");
  }, "editor-error");};
}
function purchaseProductOptions(products) {
  return '<option value="">请选择商品</option>' + products.map((product) => '<option value="' + product.product_id + '">' + escapeHTML(product.sku + " · " + product.product_name) + '</option>').join("");
}
async function purchaseDetail(purchaseId) {
  const [order, catalog] = await Promise.all([api("/purchases/" + purchaseId), api("/products?status=1&page_size=100")]);
  state.detail = order;
  const editable = order.status === "DRAFT";
  const lines = order.items.length ? order.items.map((item) => '<tr><td>' + escapeHTML(item.product_name) + '</td><td>' + (editable ? '<input aria-label="' + escapeHTML(item.product_name) + '采购数量" type="number" min="1" max="1000000" value="' + item.quantity + '" data-purchase-quantity="' + item.item_id + '">' : item.quantity) + '</td><td>' + (editable ? '<input aria-label="' + escapeHTML(item.product_name) + '进价" type="number" min="0" max="99999999.99" step=".01" value="' + price(item.unit_cost) + '" data-purchase-cost="' + item.item_id + '">' : '¥ ' + price(item.unit_cost)) + '</td><td>¥ ' + price(item.line_amount) + '</td><td>' + (editable ? actionButton("save-purchase-line", item.item_id, "更新") + actionButton("remove-purchase-line", item.item_id, "移除", true) : "—") + '</td></tr>').join("") : '<tr><td colspan="5" class="empty">尚无采购明细，请先添加商品。</td></tr>';
  openEditor("采购明细", '<div class="order-meta"><span>' + escapeHTML(order.purchase_no) + ' · ' + escapeHTML(order.supplier_name) + '</span>' + badge(statusNames[order.status], editable ? "amber" : "green") + '</div><div class="order-items"><table><thead><tr><th>商品</th><th>数量</th><th>进价</th><th>小计</th><th>操作</th></tr></thead><tbody>' + lines + '</tbody></table></div><p class="order-total">明细合计<strong>¥ ' + price(order.draft_amount) + '</strong></p>' + (editable ? '<div class="add-item-form"><div><label for="purchase-search">搜索可采购商品</label><input id="purchase-search" maxlength="100" placeholder="输入商品名称或编号"></div><button id="search-purchase-product" type="button" class="secondary">搜索商品</button></div><p id="purchase-search-count" class="helper">' + (catalog.total > catalog.items.length ? "当前显示前100件，请输入名称或编号搜索其他商品。" : "可按商品名称或编号缩小选择范围。") + '</p><form id="add-purchase-line" class="add-item-form"><div><label for="purchase-product">添加商品</label><select id="purchase-product" required>' + purchaseProductOptions(catalog.items) + '</select></div><div><label for="purchase-quantity">数量</label><input id="purchase-quantity" type="number" min="1" max="1000000" value="1" required></div><div><label for="purchase-cost">进价（元）</label><input id="purchase-cost" type="number" min="0" max="99999999.99" step=".01" required></div><button type="submit" class="secondary">加入采购单</button></form><div class="dialog-actions"><button id="cancel-purchase" type="button" class="secondary">取消采购单</button><button id="confirm-purchase" type="button" class="primary">确认入库</button></div>' : '<p class="helper">该采购单已结束，明细保留供查询。</p>'), true);
  if (!editable) return;
  $("search-purchase-product").onclick = (event) => busy(event.target, async () => {
    const q = $("purchase-search").value.trim();
    const found = await api("/products?status=1&page_size=100&q=" + encodeURIComponent(q));
    $("purchase-product").innerHTML = purchaseProductOptions(found.items);
    $("purchase-search-count").textContent = found.total > found.items.length ? "匹配结果超过100件，请输入更具体的名称或编号。" : "找到 " + found.total + " 件商品。";
  }, "editor-error");
  $("purchase-search").onkeydown = (event) => {if (event.key === "Enter") {event.preventDefault(); $("search-purchase-product").click();}};
  $("add-purchase-line").onsubmit = (event) => {event.preventDefault(); busy(event.submitter, async () => {
    await api("/purchases/" + purchaseId + "/items", {method: "POST", body: {product_id: Number($("purchase-product").value), quantity: Number($("purchase-quantity").value), unit_cost: $("purchase-cost").value}});
    await purchaseDetail(purchaseId); await loadList(); toast("商品已加入采购单。");
  }, "editor-error");};
  $("confirm-purchase").onclick = (event) => busy(event.target, async () => {
    if (!await confirmation("确认采购入库？", "入库后所有明细计入库存并生成采购流水，不能再修改。")) return;
    await api("/purchases/" + purchaseId + "/confirm", {method: "POST", body: {}});
    await purchaseDetail(purchaseId); await loadList(); toast("采购已入库，库存流水已记录。");
  }, "editor-error");
  $("cancel-purchase").onclick = (event) => busy(event.target, async () => {
    if (!await confirmation("取消采购草稿？", "取消后保留采购记录，但不能再修改。")) return;
    await api("/purchases/" + purchaseId + "/cancel", {method: "POST", body: {}});
    await purchaseDetail(purchaseId); await loadList(); toast("采购草稿已取消。");
  }, "editor-error");
}
async function newDraft(items = []) {
  const order = await api("/orders", {method: "POST", body: {payment_method: "CASH", items}});
  await activate("orders"); await orderDetail(order.sale_id); toast("草稿已创建，库存将在结算时扣减。");
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
  else busy(event.currentTarget, () => state.view === "purchases" ? newPurchase() : newDraft());
};
$("previous-page").onclick = (event) => {state.page -= 1; busy(event.currentTarget, loadList);};
$("next-page").onclick = (event) => {state.page += 1; busy(event.currentTarget, loadList);};
$("close-editor").onclick = () => $("editor").close();
["editor", "confirmation"].forEach((id) => $(id).addEventListener("close", placeToast));
$("table-body").onclick = (event) => {
  const button = event.target.closest("[data-action]"); if (!button) return;
  busy(button, async () => {
    const id = Number(button.dataset.id); const row = state.rows.find((item) => (item.product_id || item.sale_id || item.purchase_id) === id);
    if (button.dataset.action === "edit-product") productEditor(row);
    if (button.dataset.action === "minimum") minimumEditor(row);
    if (button.dataset.action === "adjust") adjustEditor(row);
    if (button.dataset.action === "logs") await inventoryLogs(row);
    if (button.dataset.action === "detail") await orderDetail(id);
    if (button.dataset.action === "purchase-detail") await purchaseDetail(id);
    if (button.dataset.action === "shop") {
      await api("/cart/items", {method: "POST", body: {product_id: id, quantity: 1}});
      toast(state.user.role === "CUSTOMER" ? "已加入购物车，可在“我的订单”中提交。" : "已加入草稿，可在“销售订单”中查看。");
    }
    if (button.dataset.action === "delete-product" && await confirmation("删除这个商品？", "仅无业务引用且库存为零的商品可以删除。已有历史记录的商品请改为停用。")) {
      await api("/products/" + id, {method: "DELETE"}); toast("未使用商品已删除。"); await loadList();
    }
  });
};
$("editor-content").onclick = (event) => {
  const button = event.target.closest("[data-action]"); if (!button || !["save-line", "remove-line", "save-purchase-line", "remove-purchase-line"].includes(button.dataset.action)) return;
  busy(button, async () => {
    const itemId = Number(button.dataset.id); const saleId = state.detail.sale_id;
    if (button.dataset.action === "save-line") {
      const quantity = Number(document.querySelector('[data-quantity="' + itemId + '"]').value);
      await api("/orders/" + saleId + "/items/" + itemId, {method: "PATCH", body: {quantity}});
    } else if (button.dataset.action === "remove-line") {
      await api("/orders/" + saleId + "/items/" + itemId, {method: "DELETE"});
    } else if (button.dataset.action === "save-purchase-line") {
      await api("/purchases/" + state.detail.purchase_id + "/items/" + itemId, {method: "PATCH", body: {quantity: Number(document.querySelector('[data-purchase-quantity="' + itemId + '"]').value), unit_cost: document.querySelector('[data-purchase-cost="' + itemId + '"]').value}});
    } else if (button.dataset.action === "remove-purchase-line") {
      await api("/purchases/" + state.detail.purchase_id + "/items/" + itemId, {method: "DELETE"});
    }
    if (state.detail.purchase_id) {await purchaseDetail(state.detail.purchase_id); await loadList(); toast("采购明细已更新。"); return;}
    await orderDetail(saleId); await loadList(); toast(state.user.role === "CUSTOMER" ? "购物车明细已更新。" : "草稿明细已更新。");
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
