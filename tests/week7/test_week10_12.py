"""第十至十二周的 SQL 验证脚本：在独立的随机测试库上运行 tools.verify_week12，要求全部检查项通过。"""
import json

from tools.verify_week12 import main


def test_week10_to_12_sql_verification_scripts_all_pass(settings, tmp_path):
    code = main(["--server", settings["DB_SERVER"], "--output", str(tmp_path)])
    summary = json.loads((tmp_path / "summary.json").read_text(encoding="utf-8"))
    problems = [(s["name"], s["error"], s["failed_rows"]) for s in summary["scripts"] if s["error"] or s["failed_rows"]]
    assert code == 0 and summary["passed"], problems
    assert [s["name"] for s in summary["scripts"]] == [
        "test_week10", "test_week11", "window_query", "recursive_query", "test_week12"]
    assert all(s["checks"] and s["checks"]["failed"] == 0 for s in summary["scripts"] if s["name"] != "window_query")
    assert summary["test_database_cleaned"] is True
