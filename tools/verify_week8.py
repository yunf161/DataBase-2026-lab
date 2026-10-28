"""在随机 SQL Server 数据库上运行第八周集成与浏览器验收，并清理测试库。"""
import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import threading
from pathlib import Path

from werkzeug.serving import make_server

from app import create_app
from app.config import ROOT
from tools.prepare_week7 import administrative_connection, drop_owned_database, provision_database


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default=r".\SQLEXPRESS")
    parser.add_argument("--node", default="node")
    parser.add_argument("--output", default=str(ROOT / "docs/week8-application/results"))
    parser.add_argument("--skip-browser", action="store_true")
    parser.add_argument("--skip-integration", action="store_true")
    args = parser.parse_args()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    environment = {**os.environ, "PYTHONUTF8": "1", "CAMPUS_TEST_SERVER": args.server}
    if args.skip_integration and not (output / "integration-output.txt").exists():
        parser.error("跳过集成测试前，输出目录必须已有集成测试结果。")
    if not args.skip_integration:
        with (output / "integration-output.txt").open("w", encoding="utf-8") as stream:
            result = subprocess.run([sys.executable, "-m", "pytest", "-q"], cwd=ROOT,
                                    env=environment, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            raise SystemExit((output / "integration-output.txt").read_text(encoding="utf-8"))
    if args.skip_browser:
        print("集成测试通过。")
        return

    database = "CampusStoreDB_W7_Test_" + secrets.token_hex(6)
    settings = provision_database(args.server, database)
    settings["LOG_PATH"] = str(ROOT / "instance/tests" / database / "week8-browser.jsonl")
    application = None
    server = None
    thread = None
    try:
        connection = administrative_connection(args.server, database)
        try:
            # 插入101个启用商品，确保浏览器能检验第100项之后的商品搜索入口。
            connection.execute("""WITH numbers AS (
                SELECT 1 AS n UNION ALL SELECT n+1 FROM numbers WHERE n<101
            ) INSERT dbo.Product(SKU,ProductName,CategoryID,Unit,SalePrice,Status)
            SELECT 'W8UI'+RIGHT('000'+CONVERT(varchar(3),n),3),
                   N'课堂搜索商品'+CONVERT(nvarchar(3),n),1,N'件',1.00,1
            FROM numbers OPTION (MAXRECURSION 0);""")
        finally:
            connection.close()
        application = create_app(settings)
        server = make_server("127.0.0.1", 0, application, threaded=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        command = [args.node, str(ROOT / "tools/verify_week8_browser.cjs"),
                   f"http://127.0.0.1:{server.server_port}", str(output)]
        with (output / "browser-output.txt").open("w", encoding="utf-8") as stream:
            result = subprocess.run(command, cwd=ROOT, env=environment,
                                    stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            raise SystemExit((output / "browser-output.txt").read_text(encoding="utf-8"))
    finally:
        if server:
            server.shutdown()
            server.server_close()
        if thread:
            thread.join(timeout=10)
        if application:
            for handler in application.extensions["audit_logger"].handlers:
                handler.close()
        drop_owned_database(args.server, database)
    browser = json.loads((output / "browser-results.json").read_text(encoding="utf-8"))
    integration_output = (output / "integration-output.txt").read_text(encoding="utf-8")
    count = re.search(r"(\d+) passed", integration_output)
    summary = {"integration_passed": int(count.group(1)) if count else None,
               "browser_checks": len(browser["checks"]),
               "javascript_errors": browser["javascript_errors"], "test_databases_cleaned": True}
    (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
