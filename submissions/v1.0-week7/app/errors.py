import re
from dataclasses import dataclass

import pyodbc


@dataclass
class AppError(Exception):
    code: str
    message: str
    status: int = 400


def database_error(error):
    state = str(error.args[0]) if error.args else ""
    native = {int(n) for n in re.findall(r"\((\d+)\)", str(error))}
    if state.startswith("08") or state in {"HYT00", "HYT01", "IM002"}:
        return AppError("DATABASE_UNAVAILABLE", "系统暂时无法连接数据服务，请稍后重试。", 503)
    if 229 in native:
        return AppError("FORBIDDEN", "当前账号没有执行此操作的权限。", 403)
    if native & {2601, 2627}:
        return AppError("DUPLICATE_RECORD", "编号、条码或订单中的商品已存在，请检查后重试。", 409)
    if 51804 in native:
        return AppError("NOT_FOUND", "记录不存在或当前账号无法访问。", 404)
    if native & {51801, 51802, 51803, 51805, 51806, 51807, 51808, 51810,
                 51220, 51221, 51320, 51321, 51400, 51401, 51402, 51411}:
        return AppError("BUSINESS_RULE", "当前数据或订单状态不允许此操作，请刷新后检查。", 409)
    if isinstance(error, pyodbc.IntegrityError) or native & {547, 8115, 8152, 2628}:
        return AppError("CONSTRAINT_CONFLICT", "数据与现有记录或数量、金额限制冲突，请检查后重试。", 409)
    return AppError("INTERNAL_ERROR", "系统暂时无法完成操作，请稍后重试。", 500)
