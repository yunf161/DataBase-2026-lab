"""一条命令运行真实SQL集成测试和独立浏览器验收，自动清理随机测试数据库。"""
import argparse
import json
import os
import secrets
import subprocess
import sys
import threading
from pathlib import Path

from werkzeug.serving import make_server

from app import create_app
from app.config import ROOT
from tools.prepare_week7 import DriverUnavailable, drop_owned_database, provision_database, resolve_driver


def run(command, environment, destination):
    with destination.open("w", encoding="utf-8") as stream:
        completed = subprocess.run(command, cwd=ROOT, env=environment, stdout=stream, stderr=subprocess.STDOUT)
    if completed.returncode:
        print(destination.read_text(encoding="utf-8", errors="replace"))
        raise SystemExit(completed.returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default=r".\SQLEXPRESS")
    parser.add_argument("--output", default=str(ROOT / "results/app-test"))
    parser.add_argument("--browser-executable", default=os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE"))
    parser.add_argument("--driver", help="ODBC 驱动名称；默认使用已安装的最高版本")
    parser.add_argument("--skip-browser", action="store_true")
    parser.add_argument("--only-browser", action="store_true")
    args = parser.parse_args()
    try:
        driver = resolve_driver(args.driver)
    except DriverUnavailable as error:
        raise SystemExit("准备失败：" + str(error))
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    environment = {**os.environ, "PYTHONUTF8": "1", "CAMPUS_TEST_SERVER": args.server, "CAMPUS_DB_DRIVER": driver,
                   "CAMPUS_TEST_RESULTS": str(output / "integration-results.json")}
    if not args.only_browser:
        run([sys.executable, "-m", "pytest", "-v", "--junitxml=" + str(output / "integration-junit.xml")],
            environment, output / "integration-output.txt")
        print("真实 SQL Server 集成测试通过。", flush=True)
    elif not (output / "integration-results.json").exists():
        raise SystemExit("只复核浏览器前，必须已有集成测试证据。")
    if args.skip_browser:
        return
    database = "CampusStoreDB_W7_Test_" + secrets.token_hex(6)
    settings = provision_database(args.server, database, driver=driver)
    settings["LOG_PATH"] = str(ROOT / "instance/tests" / database / "browser-application.jsonl")
    application = create_app(settings)
    server = None
    thread = None
    try:
        server = make_server("127.0.0.1", 0, application, threaded=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        command = [sys.executable, "-m", "tools.verify_week7_browser",
                   "--url", "http://127.0.0.1:" + str(server.server_port), "--output", str(output),
                   "--server", args.server, "--database", database, "--driver", driver]
        if args.browser_executable:
            command.extend(["--browser-executable", args.browser_executable])
        run(command, environment, output / "browser-output.txt")
        print("独立数据库上的浏览器验收通过。", flush=True)
    finally:
        if server:
            server.shutdown()
            server.server_close()
        if thread:
            thread.join(timeout=10)
        for handler in application.extensions["audit_logger"].handlers:
            handler.close()
        drop_owned_database(args.server, database, driver)
    integrations = json.loads((output / "integration-results.json").read_text(encoding="utf-8"))
    browsers = json.loads((output / "browser-results.json").read_text(encoding="utf-8"))
    summary = {
        "integration_passed": sum(row["result"] == "passed" for row in integrations["results"]),
        "browser_passed": len(browsers["results"]),
        "javascript_errors": browsers["javascript_errors"],
        "test_databases_cleaned": True,
    }
    (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
