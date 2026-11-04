"""环境预检：只读检查本机环境，不创建、修改或删除任何数据库。"""
import argparse
import json
import re
import sys
from collections import namedtuple
from importlib import metadata
from pathlib import Path

import pyodbc

from app.config import ROOT
from app.database import connection_string
from tools.prepare_week7 import DriverUnavailable, pick_driver

# ok 为 True/False 表示通过/失败，None 表示因前置项失败而跳过。
Check = namedtuple("Check", "name ok detail advice")
MINIMUM_PYTHON = (3, 10)
DEVELOPMENT_DATABASE = "CampusStoreDB_W7_Development"
SERVER_HINT = "可以用 --server 指定实例：默认实例写 \".\"，SQL Server Express 通常写 \".\\SQLEXPRESS\"。"


def check_python(version, executable, base_executable=None):
    number = ".".join(str(part) for part in version[:3])
    minimum = ".".join(str(part) for part in MINIMUM_PYTHON)
    results = [Check("Python 版本", tuple(version[:2]) >= MINIMUM_PYTHON, number,
                     "请安装 Python " + minimum + " 或更高版本，并用它重建 .venv。")]
    stub = [path for path in (executable, base_executable) if path and "windowsapps" in str(path).lower()]
    results.append(Check(
        "Python 解释器", not stub, str(executable),
        "当前是 WindowsApps 里的占位程序（应用执行别名），不是真正的 Python。"
        "请改用 .\\.venv\\Scripts\\python.exe，或安装真实的 Python 后重建 .venv。"))
    return results


def parse_lock(text):
    packages = {}
    for line in text.splitlines():
        found = re.fullmatch(r"([A-Za-z0-9_.\-]+)==(\S+)", line.strip())
        if found:
            packages[re.sub(r"[-_.]+", "-", found.group(1)).lower()] = found.group(2)
    return packages


def installed_version(name):
    try:
        return metadata.version(name)
    except metadata.PackageNotFoundError:
        return None


def check_dependencies(lock_text, version_of=installed_version):
    advice = "在仓库根目录运行：.\\.venv\\Scripts\\python.exe -m pip install -r requirements-lock.txt"
    if lock_text is None:
        return Check("依赖版本", False, "找不到 requirements-lock.txt", "请确认在仓库根目录运行，且锁定文件未被删除。")
    required = parse_lock(lock_text)
    missing = [name for name in required if version_of(name) is None]
    different = [name + "（已装 " + version_of(name) + "，要求 " + required[name] + "）"
                 for name in required if version_of(name) not in (None, required[name])]
    if missing or different:
        detail = "；".join(part for part in ("缺少：" + "、".join(missing) if missing else "",
                                            "版本不符：" + "、".join(different) if different else "") if part)
        return Check("依赖版本", False, detail, advice)
    return Check("依赖版本", True, "共 " + str(len(required)) + " 个包，与 requirements-lock.txt 一致", "")


def check_driver(drivers, requested=None):
    try:
        driver = pick_driver(drivers, requested)
    except DriverUnavailable as error:
        return Check("ODBC 驱动", False, str(error), "安装 Microsoft ODBC Driver 18 for SQL Server 后重试。"), None
    return Check("ODBC 驱动", True, driver, ""), driver


def check_connection(connect, server):
    try:
        connection = connect()
        row = connection.execute("SELECT @@SERVERNAME, CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50));").fetchone()
    except pyodbc.Error as error:
        return Check("SQL Server 连接", False, "无法连接 " + server + "：" + str(error)[:160],
                     "确认 SQL Server 服务已启动并允许 Windows 身份登录。" + SERVER_HINT), None
    return Check("SQL Server 连接", True, str(row[0]) + "（版本 " + str(row[1]) + "）", ""), connection


def check_create_permission(connection):
    allowed = connection.execute("SELECT HAS_PERMS_BY_NAME(NULL, NULL, 'CREATE ANY DATABASE');").fetchone()[0]
    return Check("建库权限", bool(allowed), "当前账号可以创建数据库" if allowed else "当前账号不能创建数据库",
                 "让管理员为当前 Windows 账号授予 dbcreator 或 sysadmin 服务器角色。")


def check_database(connection, name):
    exists = connection.execute("SELECT DB_ID(?);", name).fetchone()[0] is not None
    return Check("开发库", exists, name + (" 已存在" if exists else " 不存在"),
                 "运行：.\\.venv\\Scripts\\python.exe -m tools.prepare_week7 --server \".\"")


def check_settings(path):
    path = Path(path)
    advice = "运行 tools.prepare_week7 生成 instance/settings.json。"
    if not path.exists():
        return Check("instance/settings.json", False, "文件不存在", advice), {}
    try:
        settings = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(settings, dict):
            raise ValueError()
    except ValueError:
        return Check("instance/settings.json", False, "文件不是有效的 JSON 对象", advice), {}
    return Check("instance/settings.json", True, "数据库：" + str(settings.get("DB_DATABASE", "未配置")), ""), settings


def report(checks):
    labels = {True: "通过", False: "失败", None: "跳过"}
    for check in checks:
        print("[" + labels[check.ok] + "] " + check.name + "：" + check.detail)
        if check.ok is False and check.advice:
            print("    建议：" + check.advice)
    failures = sum(check.ok is False for check in checks)
    print("预检完成：" + ("全部通过。" if not failures else str(failures) + " 项失败。"))
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default=r".\SQLEXPRESS")
    parser.add_argument("--driver", help="ODBC 驱动名称；默认使用已安装的最高版本")
    parser.add_argument("--settings", default=str(ROOT / "instance/settings.json"))
    args = parser.parse_args()
    lock = ROOT / "requirements-lock.txt"
    checks = check_python(sys.version_info, sys.executable, getattr(sys, "_base_executable", None))
    checks.append(check_dependencies(lock.read_text(encoding="utf-8") if lock.exists() else None))
    driver_check, driver = check_driver(pyodbc.drivers(), args.driver)
    checks.append(driver_check)
    connection = None
    if driver:
        settings = {"DB_SERVER": args.server, "DB_DATABASE": "master", "DB_DRIVER": driver}
        connection_check, connection = check_connection(
            lambda: pyodbc.connect(connection_string(settings), autocommit=True, timeout=8), args.server)
        checks.append(connection_check)
    else:
        checks.append(Check("SQL Server 连接", None, "未执行：没有可用的 ODBC 驱动", ""))
    settings_check, saved = check_settings(args.settings)
    try:
        if connection:
            checks.append(check_create_permission(connection))
            checks.append(check_database(connection, saved.get("DB_DATABASE") or DEVELOPMENT_DATABASE))
        else:
            checks.extend(Check(name, None, "未执行：无法连接 SQL Server", "") for name in ("建库权限", "开发库"))
    finally:
        if connection:
            connection.close()
    checks.append(settings_check)
    return report(checks)


if __name__ == "__main__":
    sys.exit(main())
