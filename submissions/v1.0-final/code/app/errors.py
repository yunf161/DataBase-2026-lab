import re
from dataclasses import dataclass

import pyodbc


@dataclass
class AppError(Exception):
    code: str
    message: str
    status: int = 400


UNAVAILABLE = AppError("DATABASE_UNAVAILABLE", "系统暂时无法连接数据服务，请稍后重试。", 503)
STATE_CHANGED = "订单状态已变化，请刷新后查看。"
GENERIC_RULE = "当前数据或订单状态不允许此操作，请刷新后检查。"
ERROR_MAP = {
    4060: UNAVAILABLE, 18456: UNAVAILABLE,
    1205: AppError("TRANSACTION_FAILED", "操作因并发冲突未生效，请稍后重试。", 409),
    229: AppError("FORBIDDEN", "当前账号没有执行此操作的权限。", 403),
    230: AppError("FORBIDDEN", "当前账号没有执行此操作的权限。", 403),
    2601: AppError("DUPLICATE_RECORD", "编号、条码或订单中的商品已存在，请检查后重试。", 409),
    51804: AppError("NOT_FOUND", "记录不存在或当前账号无法访问。", 404),
    51305: AppError("BUSINESS_RULE", "部分商品库存不足，订单未结算，请调整数量后重试。", 409),
    51302: AppError("BUSINESS_RULE", "订单还没有商品，无法继续。", 409),
    51303: AppError("BUSINESS_RULE", "优惠金额超过商品合计，请修改后重试。", 409),
    51304: AppError("BUSINESS_RULE", "订单含已停用商品，请移除后重试。", 409),
    51301: AppError("BUSINESS_RULE", "请先选择支付方式。", 409),
    51306: AppError("BUSINESS_RULE", "经办员工无收银职责，请联系管理员。", 409),
    51011: AppError("BUSINESS_RULE", "库存数量只能通过业务流程修改。", 409),
    51811: AppError("BUSINESS_RULE", "订单已提交，不能再修改，如需变更请先取消。", 409),
    51812: AppError("BUSINESS_RULE", "顾客尚未提交此订单，暂不能结算。", 409),
    51813: AppError("BUSINESS_RULE", "库存数量没有变化。", 409),
}
ERROR_MAP.update({n: ERROR_MAP[1205] for n in (1222, 3960, 3930)})
ERROR_MAP.update({n: ERROR_MAP[2601] for n in (2627,)})
ERROR_MAP[51808] = AppError("BUSINESS_RULE", "商品已停用或不存在，请刷新后重试。", 409)
ERROR_MAP.update({n: AppError("BUSINESS_RULE", STATE_CHANGED, 409)
                  for n in (51300, 51400, 51411, 51803, 51310, 51320, 51321, 51322)})
ERROR_MAP.update({n: AppError("BUSINESS_RULE", GENERIC_RULE, 409)
                  for n in (51801, 51802, 51805, 51806, 51807, 51810, 51220, 51221, 51401, 51402)})
ERROR_MAP.update({n: AppError("CONSTRAINT_CONFLICT", "数据与现有记录或数量、金额限制冲突，请检查后重试。", 409)
                  for n in (547, 8115, 8152, 2628)})
# 只接受后面紧跟 (SQLxxx)、"; ["（pyodbc 连接多条错误的格式）或文本结尾的括号数字，避免把用户数据中的数字当作错误号
NATIVE = re.compile(r"\((\d+)\)(?=\s*(?:\(SQL|;\s*\[|$))")


def database_error(error):
    args = error.args
    state = str(args[0]) if args else ""
    text = str(args[1]) if len(args) > 1 else str(error)
    natives = [int(n) for n in NATIVE.findall(text)]
    if state in {"HYT00", "HYT01"}:
        # 连接阶段超时才是服务不可用；语句执行超时多为锁等待，按并发冲突处理。
        return UNAVAILABLE if "SQLDriverConnect" in text else ERROR_MAP[1205]
    if state.startswith("08") or state in {"IM002", "28000"}:
        return UNAVAILABLE
    if state == "40001":
        return ERROR_MAP[1205]
    for number in natives:
        if number in ERROR_MAP:
            return ERROR_MAP[number]
    if isinstance(error, pyodbc.IntegrityError):
        return ERROR_MAP[547]
    return AppError("INTERNAL_ERROR", "系统暂时无法完成操作，请稍后重试。", 500)