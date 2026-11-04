import pyodbc
import pytest

from app.errors import database_error

STATE_CHANGED = "订单状态已变化，请刷新后查看。"
CONFLICT = "操作因并发冲突未生效，请稍后重试。"


def sql_error(number, state="42000", cls=pyodbc.ProgrammingError, user_text=""):
    return cls(state, f"[{state}] [Microsoft][ODBC Driver 17 for SQL Server][SQL Server]{user_text} ({number}) (SQLExecDirectW)")


@pytest.mark.parametrize("number,message", [
    (51305, "部分商品库存不足，订单未结算，请调整数量后重试。"),
    (51302, "订单还没有商品，无法继续。"),
    (51303, "优惠金额超过商品合计，请修改后重试。"),
    (51304, "订单含已停用商品，请移除后重试。"),
    (51808, "商品已停用或不存在，请刷新后重试。"),
    (51301, "请先选择支付方式。"),
    (51306, "经办员工无收银职责，请联系管理员。"),
    *[(n, STATE_CHANGED) for n in (51300, 51400, 51411, 51803, 51310, 51320, 51321, 51322)],
    (51011, "库存数量只能通过业务流程修改。"),
    (51811, "订单已提交，不能再修改，如需变更请先取消。"),
    (51812, "顾客尚未提交此订单，暂不能结算。"),
    (51813, "库存数量没有变化。"),
])
def test_business_rule_messages(number, message):
    error = database_error(sql_error(number))
    assert (error.code, error.status, error.message) == ("BUSINESS_RULE", 409, message)


@pytest.mark.parametrize("number", [51801, 51802, 51805, 51806, 51807, 51810, 51220, 51221, 51401, 51402])
def test_other_business_rules_keep_generic_message(number):
    error = database_error(sql_error(number))
    assert (error.code, error.status) == ("BUSINESS_RULE", 409)
    assert error.message == "当前数据或订单状态不允许此操作，请刷新后检查。"


@pytest.mark.parametrize("number,word", [(51201, "没有明细"), (51202, "库存记录"), (51203, "采购职责"), (51204, "供应商"),
                                         (51814, "供应商"), (51200, "采购单"), (51210, "采购单"), (51222, "采购单"), (51410, "采购单")])
def test_purchase_errors_are_business_rules(number, word):
    error = database_error(sql_error(number))
    assert (error.code, error.status) == ("BUSINESS_RULE", 409) and word in error.message


def test_not_found_and_forbidden():
    assert (database_error(sql_error(51804)).code, database_error(sql_error(51804)).status) == ("NOT_FOUND", 404)
    assert (database_error(sql_error(229)).code, database_error(sql_error(229)).status) == ("FORBIDDEN", 403)


@pytest.mark.parametrize("number", [2601, 2627])
def test_duplicate_keys(number):
    error = database_error(sql_error(number, "23000", pyodbc.IntegrityError))
    assert (error.code, error.status) == ("DUPLICATE_RECORD", 409)


def test_duplicate_sku_229_is_not_a_permission_error():
    error = database_error(sql_error(2627, "23000", pyodbc.IntegrityError, "The duplicate key value is (229)."))
    assert (error.code, error.status) == ("DUPLICATE_RECORD", 409)


def test_user_data_number_does_not_hide_51804():
    error = database_error(sql_error(51804, user_text="SKU (229) not found."))
    assert (error.code, error.status) == ("NOT_FOUND", 404)


def test_multiple_errors_joined_by_semicolon():
    text = "[42000] [x][SQL Server]a (229) (SQLExecDirectW);[42000] [x][SQL Server]b (51305) (SQLExecDirectW)"
    assert database_error(pyodbc.ProgrammingError("42000", text)).code == "FORBIDDEN"
    text = "[42000] [x][SQL Server]a (51305); [42000] [x][SQL Server]b (51302)"
    assert database_error(pyodbc.ProgrammingError("42000", text)).message == "部分商品库存不足，订单未结算，请调整数量后重试。"
    assert database_error(pyodbc.ProgrammingError("42000", "boom (229). (51305)")).code == "BUSINESS_RULE"


def test_semicolon_inside_user_text_is_not_an_error_boundary():
    text = "[22001] [x][SQL Server]String or binary data would be truncated. Truncated value: 'a (229); b'. (2628) (SQLExecDirectW)"
    error = database_error(pyodbc.DataError("22001", text))
    assert (error.code, error.status) == ("CONSTRAINT_CONFLICT", 409)


def test_real_pyodbc_multi_error_format():
    text = ("[23000] [Microsoft][ODBC Driver 18 for SQL Server][SQL Server]Violation of UNIQUE KEY constraint. "
            "The duplicate key value is (229). (2627) (SQLExecDirectW); [01000] [Microsoft][ODBC Driver 18 for SQL Server]"
            "[SQL Server]The statement has been terminated. (3621)")
    error = database_error(pyodbc.IntegrityError("23000", text))
    assert (error.code, error.status) == ("DUPLICATE_RECORD", 409)


@pytest.mark.parametrize("number", [1205, 1222, 3960, 3930])
def test_transaction_failures_by_number(number):
    error = database_error(sql_error(number))
    assert (error.code, error.status, error.message) == ("TRANSACTION_FAILED", 409, CONFLICT)


def test_transaction_failure_by_sqlstate():
    error = database_error(pyodbc.Error("40001", "serialization failure"))
    assert (error.code, error.status, error.message) == ("TRANSACTION_FAILED", 409, CONFLICT)


@pytest.mark.parametrize("error", [
    sql_error(18456, "28000", pyodbc.InterfaceError),
    sql_error(4060, "42000", pyodbc.ProgrammingError),
    pyodbc.Error("28000", "login failed"),
    pyodbc.OperationalError("08001", "cannot connect"),
])
def test_unavailable(error):
    mapped = database_error(error)
    assert (mapped.code, mapped.status) == ("DATABASE_UNAVAILABLE", 503)


def test_column_permission_denied_230_is_forbidden_like_229():
    denied, column_denied = database_error(sql_error(229)), database_error(sql_error(230))
    assert (column_denied.code, column_denied.status) == ("FORBIDDEN", 403)
    assert column_denied.message == denied.message


@pytest.mark.parametrize("state", ["HYT00", "HYT01"])
def test_query_timeout_is_transaction_conflict(state):
    text = f"[{state}] [Microsoft][ODBC Driver 18 for SQL Server]Query timeout expired (0) (SQLExecDirectW)"
    error = database_error(pyodbc.OperationalError(state, text))
    assert (error.code, error.status, error.message) == ("TRANSACTION_FAILED", 409, CONFLICT)


@pytest.mark.parametrize("state", ["HYT00", "HYT01"])
def test_connection_timeout_is_unavailable(state):
    text = f"[{state}] [Microsoft][ODBC Driver 18 for SQL Server]Login timeout expired (0) (SQLDriverConnect)"
    error = database_error(pyodbc.OperationalError(state, text))
    assert (error.code, error.status) == ("DATABASE_UNAVAILABLE", 503)


def test_unknown_error_is_internal():
    error = database_error(sql_error(99999))
    assert (error.code, error.status) == ("INTERNAL_ERROR", 500)
