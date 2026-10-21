import json
import logging
import traceback
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal
from logging.handlers import RotatingFileHandler
from pathlib import Path

import pyodbc
from flask import Flask, g, jsonify, request, session
from flask.json.provider import DefaultJSONProvider
from werkzeug.exceptions import HTTPException

from .config import load_settings
from .database import Database
from .errors import AppError, database_error
from .repositories import AuthRepository, StoreRepository
from .routes import api, check_csrf, pages
from .services import AuthService, StoreService


class JSONProvider(DefaultJSONProvider):
    @staticmethod
    def default(value):
        if isinstance(value, Decimal):
            return format(value, ".2f")
        if isinstance(value, (date, datetime)):
            return value.isoformat()
        return DefaultJSONProvider.default(value)


def create_app(overrides=None):
    app = Flask(__name__)
    app.config.update(load_settings(overrides))
    app.json = JSONProvider(app)
    app.json.ensure_ascii = False
    database = Database(app.config)
    app.extensions["database"] = database
    app.extensions["auth_service"] = AuthService(AuthRepository(database))
    app.extensions["store_service"] = StoreService(StoreRepository(database), app.config)
    log_path = Path(app.config["LOG_PATH"])
    log_path.parent.mkdir(parents=True, exist_ok=True)
    audit = logging.getLogger("campus_store." + uuid.uuid4().hex)
    audit.setLevel(logging.INFO)
    audit.propagate = False
    handler = RotatingFileHandler(log_path, maxBytes=2_000_000, backupCount=3, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(message)s"))
    audit.addHandler(handler)
    app.extensions["audit_logger"] = audit

    @app.before_request
    def request_context():
        g.request_id = uuid.uuid4().hex
        g.user = None
        g.response_code = "OK"
        if request.path.startswith("/api/"):
            user_id = session.get("user_id")
            if type(user_id) is int:
                g.user = app.extensions["auth_service"].session_user(user_id)
                if g.user is None:
                    session.clear()
            if request.endpoint and request.endpoint.startswith("api.") and request.endpoint not in {
                "api.auth_session", "api.login", "api.logout"
            } and not g.user:
                raise AppError("AUTH_REQUIRED", "请先登录后继续。", 401)
            check_csrf()

    def failure(error):
        g.response_code = error.code
        return jsonify(ok=False, code=error.code, message=error.message, data=None,
                       request_id=g.request_id), error.status

    @app.errorhandler(AppError)
    def app_error(error):
        return failure(error)

    @app.errorhandler(pyodbc.Error)
    def sql_error(error):
        audit.error(json.dumps({
            "time": datetime.now(timezone.utc).isoformat(), "event": "database_error",
            "request_id": g.request_id, "operation": request.endpoint,
            "details": str(error), "traceback": traceback.format_exc(),
        }, ensure_ascii=False))
        return failure(database_error(error))

    @app.errorhandler(HTTPException)
    def http_error(error):
        status = error.code or 500
        code = {400: "INVALID_INPUT", 404: "NOT_FOUND", 405: "METHOD_NOT_ALLOWED",
                413: "REQUEST_TOO_LARGE"}.get(status, "HTTP_ERROR")
        message = {400: "提交内容格式不正确。", 404: "页面或接口不存在。",
                   405: "此操作方式不受支持。", 413: "提交内容过大，请减少明细后重试。"}.get(status, "请求暂时无法处理。")
        return failure(AppError(code, message, status))

    @app.errorhandler(Exception)
    def unexpected_error(error):
        audit.error(json.dumps({
            "time": datetime.now(timezone.utc).isoformat(), "event": "unexpected_error",
            "request_id": g.request_id, "operation": request.endpoint,
            "details": str(error), "traceback": traceback.format_exc(),
        }, ensure_ascii=False))
        return failure(AppError("INTERNAL_ERROR", "系统暂时无法完成操作，请稍后重试。", 500))

    @app.after_request
    def finish_request(response):
        response.headers["X-Request-ID"] = g.get("request_id", "")
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "same-origin"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
            "connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
        )
        if request.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
            user = g.get("user") or {}
            audit.info(json.dumps({
                "time": datetime.now(timezone.utc).isoformat(), "event": "request",
                "request_id": g.get("request_id"), "operation": request.endpoint or "unknown",
                "method": request.method, "user_id": user.get("user_id"),
                "role": user.get("role", "ANONYMOUS"), "error_code": g.get("response_code"),
                "status": response.status_code, "result": "success" if response.status_code < 400 else "failure",
            }, ensure_ascii=False))
        return response

    app.register_blueprint(pages)
    app.register_blueprint(api)
    return app
