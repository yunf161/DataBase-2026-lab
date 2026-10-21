import json
import os
import secrets
from pathlib import Path

import pytest

from app import create_app
from app.config import ROOT
from tools.prepare_week7 import DEMO_PASSWORD, drop_owned_database, provision_database


@pytest.fixture(scope="session")
def settings():
    server = os.environ.get("CAMPUS_TEST_SERVER", r".\SQLEXPRESS")
    database = "CampusStoreDB_W7_Test_" + secrets.token_hex(6)
    configuration = provision_database(server, database)
    configuration.update(TESTING=True, LOG_PATH=str(ROOT / "instance/tests" / database / "application.jsonl"))
    try:
        yield configuration
    finally:
        drop_owned_database(server, database)


@pytest.fixture(scope="session")
def app(settings):
    application = create_app(settings)
    yield application
    for handler in application.extensions["audit_logger"].handlers:
        handler.close()


@pytest.fixture
def client(app):
    return app.test_client()


class SessionClient:
    def __init__(self, client, username):
        self.client = client
        initial = client.get("/api/auth/session").json
        response = client.post("/api/auth/login", json={"username": username, "password": DEMO_PASSWORD},
                               headers={"X-CSRF-Token": initial["data"]["csrf_token"]})
        assert response.status_code == 200, response.json
        self.user = response.json["data"]["user"]
        self.token = response.json["data"]["csrf_token"]

    def get(self, path, **kwargs):
        return self.client.get("/api" + path, **kwargs)

    def send(self, method, path, data=None, **kwargs):
        return self.client.open("/api" + path, method=method, json=data if data is not None else {},
                                headers={"X-CSRF-Token": self.token}, **kwargs)


@pytest.fixture
def login(app):
    return lambda username: SessionClient(app.test_client(), username)


@pytest.fixture
def product_data():
    return {"sku": "T" + secrets.token_hex(6), "product_name": "测试文具", "category_id": 5,
            "sale_price": "6.50", "unit": "件", "status": 1}


def pytest_terminal_summary(terminalreporter, exitstatus, config):
    output = os.environ.get("CAMPUS_TEST_RESULTS")
    if not output:
        return
    results = []
    for outcome, reports in terminalreporter.stats.items():
        for report in reports:
            if getattr(report, "when", None) == "call":
                results.append({"test": report.nodeid, "result": outcome, "duration": round(report.duration, 3)})
    path = Path(output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"exit_status": exitstatus, "results": results}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
