"""第十至十二周数据库验证：新建随机测试库（部署第一阶段到第十二周的全部脚本），依次运行
sql/week10/test_week10.sql、sql/week11/test_week11.sql、sql/week11/window_query.sql、
sql/week12/recursive_query.sql、sql/week12/test_week12.sql，把每个脚本的消息和结果集原样保存到
results/week10-12/*.txt，汇总写入 results/week10-12/summary.json，最后删除测试库（--keep 时保留）。
任一脚本报错或结果表里出现“未通过”，退出码为 1。"""
import argparse
import json
import re
import secrets
import sys
import time
import unicodedata
from datetime import datetime
from pathlib import Path

import pyodbc

from app.config import ROOT
from tools.prepare_week7 import administrative_connection, drop_owned_database, provision_database, resolve_driver

SCRIPTS = [
    ("test_week10", "sql/week10/test_week10.sql", "第十周：存储过程与函数"),
    ("test_week11", "sql/week11/test_week11.sql", "第十一周：触发器与窗口函数（核对）"),
    ("window_query", "sql/week11/window_query.sql", "第十一周：三类窗口查询结果"),
    ("recursive_query", "sql/week12/recursive_query.sql", "第十二周：层级递归查询"),
    ("test_week12", "sql/week12/test_week12.sql", "第十二周：订单完成与补货入库事务"),
]
PREFIX = re.compile(r"^(\[[^\]]*\])+")


def width(text):
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)


def cell(value):
    if value is None:
        return "NULL"
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S")
    return str(value)


def table(columns, rows):
    data = [[cell(v) for v in row] for row in rows]
    sizes = [max([width(c)] + [width(r[i]) for r in data]) for i, c in enumerate(columns)]
    pad = lambda text, size: text + " " * (size - width(text))
    lines = [" | ".join(pad(c, sizes[i]) for i, c in enumerate(columns)).rstrip(),
             "-+-".join("-" * s for s in sizes)]
    lines += [" | ".join(pad(r[i], sizes[i]) for i in range(len(columns))).rstrip() for r in data]
    lines.append("(" + str(len(data)) + " 行)")
    return "\n".join(lines)


def batches(path):
    sql = path.read_text(encoding="utf-8-sig")
    for batch in re.split(r"(?im)^GO\s*$", sql):
        batch = re.sub(r"\A(?:\s+|--[^\n]*(?:\n|$)|/\*.*?\*/)*", "", batch, flags=re.S)
        if batch.strip():
            yield batch


def run(connection, path):
    """逐批执行脚本，按出现顺序收集 PRINT 消息和结果集；返回输出文本、结果集列表和错误。"""
    out, sets, error = [], [], None
    cursor = connection.cursor()

    def drain():
        while True:
            for _, message in cursor.messages or []:
                out.append(PREFIX.sub("", message))
            if cursor.description:
                columns = [d[0] for d in cursor.description]
                rows = cursor.fetchall()
                sets.append((columns, rows))
                out.append(table(columns, rows))
            if not cursor.nextset():
                for _, message in cursor.messages or []:
                    out.append(PREFIX.sub("", message))
                break

    try:
        for batch in batches(path):
            cursor.execute(batch)
            drain()
    except pyodbc.Error as caught:
        error = PREFIX.sub("", str(caught.args[1] if len(caught.args) > 1 else caught))
        out.append("脚本执行出错：" + error)
    finally:
        cursor.close()
    return "\n\n".join(out), sets, error


def failures(sets):
    """结果表中“结论”列为“未通过”的行数，以及汇总表里的失败数。"""
    count = 0
    for columns, rows in sets:
        if "结论" in columns:
            index = columns.index("结论")
            count += sum(1 for row in rows if row[index] == "未通过")
    return count


def checks(sets):
    for columns, rows in sets:
        if columns == ["项目", "检查项", "通过", "失败"] and rows and all(value is not None for value in rows[0][1:4]):
            return {"items": int(rows[0][1]), "passed": int(rows[0][2]), "failed": int(rows[0][3])}
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default=r".\SQLEXPRESS")
    parser.add_argument("--driver", help="ODBC 驱动名称；默认使用已安装的最高版本")
    parser.add_argument("--output", default=str(ROOT / "results/week10-12"))
    parser.add_argument("--keep", action="store_true", help="保留测试库，便于在 SSMS 中查看")
    args = parser.parse_args(argv)
    driver = resolve_driver(args.driver)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    database = "CampusStoreDB_W7_Test_" + secrets.token_hex(6)
    summary = {"run_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "server": args.server,
               "database": database, "scripts": [], "passed": False}
    started = time.perf_counter()
    try:
        provision_database(args.server, database, driver=driver)
        for name, script, title in SCRIPTS:
            connection = administrative_connection(args.server, database, driver)
            connection.timeout = 300
            try:
                begun = time.perf_counter()
                text, sets, error = run(connection, ROOT / script)
            finally:
                connection.close()
            header = "# " + title + "\n# 脚本：" + script + "\n# 数据库：" + database + \
                     "\n# 运行时间：" + datetime.now().strftime("%Y-%m-%d %H:%M:%S") + "\n\n"
            (output / (name + ".txt")).write_text(header + text + "\n", encoding="utf-8")
            failed = failures(sets)
            entry = {"name": name, "script": script, "title": title, "error": error, "failed_rows": failed,
                     "checks": checks(sets), "seconds": round(time.perf_counter() - begun, 1)}
            summary["scripts"].append(entry)
            print(("通过" if not error and not failed else "失败") + "：" + title +
                  ("" if not entry["checks"] else "（检查项 " + str(entry["checks"]["items"]) + "，失败 " +
                   str(entry["checks"]["failed"]) + "）") + ("" if not error else " 错误：" + error), flush=True)
        summary["passed"] = all(not s["error"] and not s["failed_rows"] for s in summary["scripts"])
    finally:
        summary["seconds"] = round(time.perf_counter() - started, 1)
        if args.keep:
            summary["kept_database"] = database
            print("已保留测试库：" + database)
        else:
            drop_owned_database(args.server, database, driver)
            summary["test_database_cleaned"] = True
        (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": summary["passed"], "output": str(output)}, ensure_ascii=False))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, pyodbc.Error) as error:
        print("验证失败：" + str(error), file=sys.stderr)
        sys.exit(1)
