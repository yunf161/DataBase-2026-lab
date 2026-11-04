"""把已有的第七周开发库升级到第九周应用增量；只执行可重复的结构/过程脚本，不删除数据。"""
import argparse
import sys

import pyodbc

from app.config import DATABASE_NAME, ROOT
from tools.prepare_week7 import administrative_connection, run_script


def upgrade_database(server, database, driver=None):
    if not DATABASE_NAME.fullmatch(database):
        raise ValueError("目标库名必须为 CampusStoreDB_W7_ 加字母、数字或下划线")
    connection = administrative_connection(server, database, driver)
    try:
        run_script(connection, ROOT / "sql/week9/application_v2.sql")
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default=r".\SQLEXPRESS")
    parser.add_argument("--database", required=True)
    parser.add_argument("--driver", help="ODBC 驱动名称；默认使用已安装的最高版本")
    args = parser.parse_args()
    upgrade_database(args.server, args.database, args.driver)
    print("已升级第九周应用增量：" + args.database)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, pyodbc.Error) as error:
        print("升级失败：" + str(error), file=sys.stderr)
        sys.exit(1)
