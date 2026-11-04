"""从冻结SQL建立W6副本，真实迁移后改为W7名称；只操作本次创建的库。"""
import argparse
import json
import os
import re
import secrets
import sys
from pathlib import Path

import pyodbc
from werkzeug.security import generate_password_hash

from app.config import DATABASE_NAME, ROOT
from app.database import SQL_OPTIONS, connection_string

DEMO_PASSWORD = "Campus2026!"
DRIVER_NAME = re.compile(r"ODBC Driver (\d+) for SQL Server\Z")


class DriverUnavailable(ValueError):
    pass


def pick_driver(drivers, requested=None):
    installed = sorted((name for name in drivers if DRIVER_NAME.fullmatch(name)),
                       key=lambda name: int(DRIVER_NAME.fullmatch(name).group(1)))
    if requested:
        if requested not in drivers:
            raise DriverUnavailable("没有安装指定的驱动“" + requested + "”。已安装的 SQL Server ODBC 驱动："
                                    + (("、".join(installed)) or "无") + "。")
        return requested
    if not installed:
        raise DriverUnavailable("没有找到 SQL Server 的 ODBC 驱动（ODBC Driver xx for SQL Server）。"
                                "请从微软官网下载并安装“Microsoft ODBC Driver 18 for SQL Server”，安装后重新运行。")
    return installed[-1]


def resolve_driver(requested=None):
    return pick_driver(pyodbc.drivers(), requested or os.environ.get("CAMPUS_DB_DRIVER"))


def administrative_connection(server, database="master", driver=None):
    settings = {"DB_SERVER": server, "DB_DATABASE": database, "DB_DRIVER": resolve_driver(driver)}
    connection = pyodbc.connect(connection_string(settings), autocommit=True, timeout=8)
    connection.timeout = 60
    connection.execute(SQL_OPTIONS)
    return connection


def run_script(connection, source, replace_database=None):
    sql = source.read_text(encoding="utf-8-sig")
    if replace_database:
        sql = sql.replace("CampusStoreDB", replace_database)
    cursor = connection.cursor()
    try:
        for batch in re.split(r"(?im)^GO\s*$", sql):
            # ODBC会把批次开头注释保存在模块定义里；与sqlcmd一致从实际语句开始发送。
            batch = re.sub(r"\A(?:\s+|--[^\n]*(?:\n|$)|/\*.*?\*/)*", "", batch, flags=re.S)
            if batch.strip():
                cursor.execute(batch)
                while cursor.nextset():
                    pass
    finally:
        cursor.close()


def drop_owned_database(server, name, driver=None):
    if not (re.fullmatch(r"CampusStoreDB_W6_W7_[a-f0-9]{12}", name) or
            re.fullmatch(r"CampusStoreDB_W7_Test_[a-f0-9]{12}", name)):
        raise ValueError("拒绝删除非随机测试数据库")
    connection = administrative_connection(server, driver=driver)
    try:
        if connection.execute("SELECT DB_ID(?);", name).fetchone()[0] is not None:
            # 标识符只能来自以上固定前缀与十六进制随机串，不能用于Web输入。
            connection.execute("ALTER DATABASE [" + name + "] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;")
            connection.execute("DROP DATABASE [" + name + "];")
    finally:
        connection.close()


def seed_users(connection, password):
    for username, name, role, employee_no in [
        ("admin", "店铺管理员", "ADMIN", "E001"),
        ("staff", "值班店员", "STAFF", "E003"),
        ("customer", "校园顾客", "CUSTOMER", None),
        ("customer2", "另一位顾客", "CUSTOMER", None),
    ]:
        employee_id = None
        if employee_no:
            employee_id = connection.execute("SELECT EmployeeID FROM dbo.Employee WHERE EmployeeNo=?;", employee_no).fetchone()[0]
        connection.execute("""
          INSERT app.AppUser(Username,PasswordHash,DisplayName,RoleName,EmployeeID) VALUES(?,?,?,?,?);
        """, username, generate_password_hash(password), name, role, employee_id)


def provision_database(server, target, password=DEMO_PASSWORD, *, apply_week9=True, driver=None):
    if not DATABASE_NAME.fullmatch(target):
        raise ValueError("目标库名必须为 CampusStoreDB_W7_ 加字母、数字或下划线")
    driver = resolve_driver(driver)
    staging = "CampusStoreDB_W6_W7_" + secrets.token_hex(6)
    master = administrative_connection(server, driver=driver)
    created = False
    renamed = False
    connection = None
    try:
        if master.execute("SELECT DB_ID(?);", target).fetchone()[0] is not None:
            raise ValueError("目标数据库已存在，拒绝覆盖；请使用现有配置启动，或指定另一个新库名。")
        if master.execute("SELECT DB_ID(?);", staging).fetchone()[0] is not None:
            raise ValueError("随机暂存库名冲突，请重试。")
        created = True
        # 随机名称已确认不存在；由冻结01创建，失败时清理本次可能留下的暂存库。
        connection = administrative_connection(server, driver=driver)
        baseline = ROOT / "submissions/v0.1-week4/sql"
        for filename in ["01_create_campus_store_database.sql", "02_business_procedures.sql",
                         "view.sql", "role.sql", "03_sample_data.sql"]:
            run_script(connection, baseline / filename, staging)
        run_script(connection, ROOT / "sql/week6/baseline.sql")
        run_script(connection, ROOT / "sql/week6/migration.sql")
        connection.close()
        connection = None
        master.execute("ALTER DATABASE [" + staging + "] MODIFY NAME = [" + target + "];")
        renamed = True
        connection = administrative_connection(server, target, driver)
        run_script(connection, ROOT / "sql/week7/application.sql")
        if apply_week9:
            run_script(connection, ROOT / "sql/week9/application_v2.sql")
        seed_users(connection, password)
        print("已创建迁移后的第七周独立应用数据库：" + target, flush=True)
        return {
            "DB_SERVER": server, "DB_DATABASE": target, "DB_DRIVER": driver,
            "SECRET_KEY": secrets.token_urlsafe(48), "DEFAULT_CASHIER_NO": "E003",
        }
    except BaseException:
        if connection:
            connection.close()
            connection = None
        if created:
            # 精确目标在函数开始已验证不存在；失败只清理由本函数新建的库。
            owned = target if renamed else staging
            if master.execute("SELECT DB_ID(?);", owned).fetchone()[0] is not None:
                master.execute("ALTER DATABASE [" + owned + "] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;")
                master.execute("DROP DATABASE [" + owned + "];")
        raise
    finally:
        if connection:
            connection.close()
        master.close()


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default=r".\SQLEXPRESS")
    parser.add_argument("--database", default="CampusStoreDB_W7_Development")
    parser.add_argument("--settings", default=str(ROOT / "instance/settings.json"))
    parser.add_argument("--driver", help="ODBC 驱动名称；默认使用已安装的最高版本 ODBC Driver xx for SQL Server")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    driver = resolve_driver(args.driver)
    settings = provision_database(args.server, args.database, driver=driver)
    destination = Path(args.settings)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("使用驱动：" + driver)
    print("本地配置已写入 instance/settings.json；该目录不提交版本库。")
    print("演示账号：admin / staff / customer / customer2，密码均为 " + DEMO_PASSWORD)
    print("启动：.venv\\Scripts\\python.exe -m app")


def cli(argv=None):
    try:
        main(argv)
    except (ValueError, pyodbc.Error) as error:
        print("准备失败：" + str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    cli()
