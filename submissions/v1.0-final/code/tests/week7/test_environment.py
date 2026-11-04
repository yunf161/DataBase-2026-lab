"""环境工具测试：不连接数据库，只检查驱动选择和预检逻辑。"""
import json
import sys

import pyodbc
import pytest

from tools import doctor, prepare_week7
from tools.prepare_week7 import DriverUnavailable, pick_driver

DRIVERS = ["SQL Server", "ODBC Driver 17 for SQL Server", "ODBC Driver 18 for SQL Server", "Microsoft Access Driver (*.mdb)"]


def test_highest_installed_odbc_driver_is_chosen():
    assert pick_driver(DRIVERS) == "ODBC Driver 18 for SQL Server"
    assert pick_driver(["ODBC Driver 9 for SQL Server", "ODBC Driver 17 for SQL Server"]) == "ODBC Driver 17 for SQL Server"
    assert pick_driver(["ODBC Driver 17 for SQL Server", "ODBC Driver 100 for SQL Server"]) == "ODBC Driver 100 for SQL Server"


def test_explicit_driver_must_be_installed():
    assert pick_driver(DRIVERS, "ODBC Driver 17 for SQL Server") == "ODBC Driver 17 for SQL Server"
    with pytest.raises(DriverUnavailable, match="ODBC Driver 99 for SQL Server"):
        pick_driver(DRIVERS, "ODBC Driver 99 for SQL Server")


def test_missing_driver_gives_chinese_guidance():
    with pytest.raises(DriverUnavailable) as error:
        pick_driver(["SQL Server", "Microsoft Access Driver (*.mdb)"])
    assert "ODBC Driver" in str(error.value) and "安装" in str(error.value)


def test_prepare_tool_reports_missing_driver_without_traceback(monkeypatch, capsys):
    monkeypatch.setattr(pyodbc, "drivers", lambda: ["SQL Server"])
    monkeypatch.delenv("CAMPUS_DB_DRIVER", raising=False)
    with pytest.raises(SystemExit) as stop:
        prepare_week7.cli(["--server", "."])
    assert stop.value.code == 1
    error = capsys.readouterr().err
    assert "准备失败" in error and "安装" in error and "Traceback" not in error


def test_provisioned_settings_record_the_driver():
    assert "driver" in prepare_week7.provision_database.__code__.co_varnames
    assert "--driver" in prepare_week7.build_parser().format_help()


def test_python_check_flags_windowsapps_stub():
    good = doctor.check_python((3, 13, 1), r"C:\repo\.venv\Scripts\python.exe", r"C:\Python\python.exe")
    assert all(check.ok for check in good)
    stub = doctor.check_python((3, 13, 1), r"C:\Users\me\AppData\Local\Microsoft\WindowsApps\python.exe")
    assert [check.ok for check in stub] == [True, False]
    assert "WindowsApps" in stub[1].advice
    old = doctor.check_python((3, 8, 10), r"C:\Python\python.exe")
    assert old[0].ok is False and "3.10" in old[0].advice


def test_lock_file_parser_ignores_comments_and_normalizes_names():
    parsed = doctor.parse_lock("# 注释\nFlask==3.1.3\n\ntyping_extensions==4.16.0\n")
    assert parsed == {"flask": "3.1.3", "typing-extensions": "4.16.0"}


def test_dependency_check_reports_missing_and_mismatched():
    lock = "Flask==3.1.3\npyodbc==5.3.0\nwaitress==3.0.2\n"
    versions = {"flask": "3.1.3", "pyodbc": "5.2.0"}
    check = doctor.check_dependencies(lock, lambda name: versions.get(name))
    assert check.ok is False
    assert "waitress" in check.detail and "pyodbc" in check.detail and "5.2.0" in check.detail
    assert "pip install -r requirements-lock.txt" in check.advice
    versions.update(pyodbc="5.3.0", waitress="3.0.2")
    assert doctor.check_dependencies(lock, lambda name: versions.get(name)).ok is True
    assert doctor.check_dependencies(None, lambda name: None).ok is False


def test_driver_check_uses_same_selection_rule():
    check, driver = doctor.check_driver(DRIVERS)
    assert check.ok and driver == "ODBC Driver 18 for SQL Server"
    check, driver = doctor.check_driver(["SQL Server"])
    assert check.ok is False and driver is None and "安装" in check.advice


class FakeCursor:
    def __init__(self, row):
        self.row = row

    def fetchone(self):
        return self.row


class FakeConnection:
    def __init__(self, permission=1, database_id=7):
        self.statements = []
        self.permission = permission
        self.database_id = database_id

    def execute(self, sql, *parameters):
        self.statements.append(sql)
        if "HAS_PERMS_BY_NAME" in sql:
            return FakeCursor((self.permission,))
        if "DB_ID" in sql:
            return FakeCursor((self.database_id,))
        return FakeCursor(("SERVER", "17.0.1000"))

    def close(self):
        pass


def test_connection_failure_suggests_server_argument():
    def refuse():
        raise pyodbc.Error("08001", "[08001] 无法连接")
    check, connection = doctor.check_connection(refuse, ".")
    assert check.ok is False and connection is None
    assert "--server" in check.advice and "SQLEXPRESS" in check.advice


def test_database_checks_are_read_only_and_report_each_item(tmp_path):
    connection = FakeConnection()
    permission = doctor.check_create_permission(connection)
    assert permission.ok is True
    assert doctor.check_create_permission(FakeConnection(permission=0)).ok is False
    assert doctor.check_database(connection, "CampusStoreDB_W7_Development").ok is True
    missing = doctor.check_database(FakeConnection(database_id=None), "CampusStoreDB_W7_Development")
    assert missing.ok is False and "prepare_week7" in missing.advice
    assert connection.statements and all(sql.lstrip().upper().startswith("SELECT") for sql in connection.statements)


def test_settings_check_reads_database_name(tmp_path):
    path = tmp_path / "settings.json"
    absent, settings = doctor.check_settings(path)
    assert absent.ok is False and settings == {}
    path.write_text(json.dumps({"DB_DATABASE": "CampusStoreDB_W7_Development"}), encoding="utf-8")
    present, settings = doctor.check_settings(path)
    assert present.ok is True and settings["DB_DATABASE"] == "CampusStoreDB_W7_Development"
    path.write_text("{坏的", encoding="utf-8")
    assert doctor.check_settings(path)[0].ok is False


def test_report_exit_code_ignores_skipped_checks_but_fails_on_failures(capsys):
    ok = doctor.Check("甲", True, "正常", "")
    skipped = doctor.Check("乙", None, "未执行", "")
    bad = doctor.Check("丙", False, "异常", "按提示处理")
    assert doctor.report([ok, skipped]) == 0
    assert doctor.report([ok, bad]) == 1
    output = capsys.readouterr().out
    assert "[通过] 甲" in output and "[跳过] 乙" in output and "[失败] 丙" in output and "按提示处理" in output


def test_doctor_runs_without_database_when_driver_missing(monkeypatch, capsys):
    monkeypatch.setattr(pyodbc, "drivers", lambda: [])
    monkeypatch.setattr(sys, "argv", ["doctor", "--server", "."])
    assert doctor.main() == 1
    output = capsys.readouterr().out
    assert "[失败] ODBC 驱动" in output and "[跳过] SQL Server 连接" in output and "Traceback" not in output
