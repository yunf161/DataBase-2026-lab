from contextlib import contextmanager, suppress

import pyodbc

# 每个请求使用独立物理连接，避免 EXECUTE AS / SESSION_CONTEXT 留在连接池。
pyodbc.pooling = False
PRINCIPALS = {
    "AUTH": "EXECUTE AS USER = 'WebAuth';",
    "ADMIN": "EXECUTE AS USER = 'WebAdmin';",
    "STAFF": "EXECUTE AS USER = 'WebStaff';",
    "CUSTOMER": "EXECUTE AS USER = 'WebCustomer';",
}
SQL_OPTIONS = """
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF; SET NOCOUNT ON; SET XACT_ABORT ON;
"""


def odbc_value(value):
    return "{" + str(value).replace("}", "}}") + "}"


def connection_string(settings, database=None):
    return (
        "DRIVER=" + odbc_value(settings["DB_DRIVER"]) +
        ";SERVER=" + odbc_value(settings["DB_SERVER"]) +
        ";DATABASE=" + odbc_value(database or settings["DB_DATABASE"]) +
        ";Trusted_Connection=yes;Encrypt=yes;TrustServerCertificate=yes;"
    )


class Database:
    def __init__(self, settings):
        self.settings = settings

    @contextmanager
    def transaction(self, role, user_id=None):
        if role not in PRINCIPALS:
            raise ValueError("未知数据库执行身份")
        connection = pyodbc.connect(
            connection_string(self.settings), timeout=self.settings["DB_TIMEOUT"], autocommit=False
        )
        try:
            connection.timeout = 15
            connection.execute(SQL_OPTIONS)
            connection.execute(
                "EXEC sys.sp_set_session_context @key=N'WebUserID',@value=?,@read_only=1;",
                user_id,
            )
            connection.execute(PRINCIPALS[role])
            yield connection
            connection.commit()
        except BaseException:
            with suppress(pyodbc.Error):
                connection.rollback()
            raise
        finally:
            with suppress(pyodbc.Error):
                connection.execute("REVERT;")
            connection.close()


def records(connection, sql, *parameters):
    cursor = connection.cursor()
    try:
        cursor.execute(sql, *parameters)
        while cursor.description is None:
            if not cursor.nextset():
                return []
        names = [column[0] for column in cursor.description]
        return [dict(zip(names, row)) for row in cursor.fetchall()]
    finally:
        cursor.close()


def one(connection, sql, *parameters):
    rows = records(connection, sql, *parameters)
    return rows[0] if rows else None
