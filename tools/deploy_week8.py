"""在已有第七周应用数据库中增量部署第八周视图、过程和授权，不重建数据。"""
import argparse
import sys

import pyodbc

from app.config import DATABASE_NAME, ROOT, load_settings
from tools.prepare_week7 import administrative_connection, run_script


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", help="SQL Server实例；默认取本地应用配置")
    parser.add_argument("--database", help="已有CampusStoreDB_W7_*数据库；默认取本地应用配置")
    args = parser.parse_args()
    settings = {} if args.server and args.database else load_settings()
    server = args.server or settings["DB_SERVER"]
    database = args.database or settings["DB_DATABASE"]
    if not DATABASE_NAME.fullmatch(database):
        raise ValueError("只能部署到CampusStoreDB_W7_*应用数据库。")
    connection = administrative_connection(server, database)
    try:
        required = ("app.AppUser", "app.v_Catalog", "dbo.InventoryLog")
        for name in required:
            if connection.execute("SELECT OBJECT_ID(?);", name).fetchone()[0] is None:
                raise ValueError(f"缺少第七周或第六周对象：{name}，请先完成原部署。")
        run_script(connection, ROOT / "sql/week8/application.sql")
        print(f"第八周增量已部署：{server} / {database}；原订单、库存和用户数据保留。")
    finally:
        connection.close()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, pyodbc.Error) as error:
        print("部署失败：" + str(error), file=sys.stderr)
        sys.exit(1)
