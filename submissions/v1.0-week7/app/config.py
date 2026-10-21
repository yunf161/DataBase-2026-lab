import json
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATABASE_NAME = re.compile(r"CampusStoreDB_W7_[A-Za-z0-9_]{1,60}\Z")


def load_settings(overrides=None):
    path = Path(os.environ.get("CAMPUS_SETTINGS", ROOT / "instance/settings.json"))
    settings = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    for key in ("DB_SERVER", "DB_DATABASE", "DB_DRIVER", "SECRET_KEY"):
        if os.environ.get("CAMPUS_" + key):
            settings[key] = os.environ["CAMPUS_" + key]
    settings.update(overrides or {})
    if not DATABASE_NAME.fullmatch(settings.get("DB_DATABASE", "")):
        raise RuntimeError("请先运行 tools/prepare_week7.py，配置独立的 CampusStoreDB_W7_* 应用数据库。")
    if len(settings.get("SECRET_KEY", "")) < 32:
        raise RuntimeError("SECRET_KEY 至少32个字符，请使用准备工具生成本地配置。")
    return {
        "DB_SERVER": r".\SQLEXPRESS", "DB_DRIVER": "ODBC Driver 18 for SQL Server",
        "DB_TIMEOUT": 5, "DEFAULT_CASHIER_NO": "E003",
        "LOG_PATH": str(ROOT / "instance/logs/application.jsonl"),
        "MAX_CONTENT_LENGTH": 128 * 1024,
        "SESSION_COOKIE_HTTPONLY": True, "SESSION_COOKIE_SAMESITE": "Lax",
        "SESSION_COOKIE_SECURE": False, "PERMANENT_SESSION_LIFETIME": 3600,
        "SESSION_REFRESH_EACH_REQUEST": False,
        **settings,
    }
