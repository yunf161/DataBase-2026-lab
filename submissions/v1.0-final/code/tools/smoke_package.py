"""空环境复现：把交付包 zip 解压到系统临时目录，新建虚拟环境，只按包内 README 的命令操作，
最后用 admin 登录，并清理测试库和临时目录。结果写入 results/package-smoke.json。

README 里的命令从包内 README.md 的“从空环境复现”代码块中读取；只做三处必要的替换并如实记录：
把 `python` 换成指定的真实解释器、给 prepare_week7 加 --database 指定随机测试库、给启动命令换一个空闲端口。
"""
import argparse
import hashlib
import http.cookiejar
import json
import os
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PASSWORD = "Campus2026!"


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def readme_commands(readme):
    text = readme.read_text(encoding="utf-8")
    section = text[text.index("## 4. 从空环境复现"):]
    block = re.search(r"```powershell\n(.*?)```", section, re.S).group(1)
    commands = [line.strip() for line in block.splitlines() if line.strip() and not line.strip().startswith("#")]
    if len(commands) != 5:
        raise SystemExit("包内 README 的复现命令应为 5 条，实际 " + str(len(commands)) + " 条")
    return commands


def tokens(command, cwd):
    parts = [part.strip('"') for part in shlex.split(command, posix=False)]
    if parts[0].startswith(".\\"):
        parts[0] = str(Path(cwd) / parts[0][2:])
    return parts


def scrub(text, *paths):
    for path in paths:
        text = text.replace(str(path), "<TEMP>")
    return re.sub(r"[A-Za-z]:\\Users\\[^\\\s]+", "<USER_HOME>", text)


def run_step(name, command, cwd, environment, notes, record, interpreter=None, expect_failure=False):
    arguments = tokens(command, cwd)
    if interpreter and arguments[0] == "python":
        arguments[0] = interpreter
    started = time.time()
    completed = subprocess.run(arguments, cwd=cwd, env=environment, capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
    output = (completed.stdout + completed.stderr).strip()
    step = {"step": name, "readme_command": command, "replacements": notes, "exit_code": completed.returncode,
            "seconds": round(time.time() - started, 1),
            "output_tail": scrub(output, cwd, Path(cwd).parent).splitlines()[-30:]}
    step["ok"] = (completed.returncode != 0) if expect_failure else (completed.returncode == 0)
    record.append(step)
    print(("通过" if step["ok"] else "失败") + "：" + name + "（退出码 " + str(completed.returncode) + "）", flush=True)
    return completed


def http_json(opener, url, body=None, token=None):
    request = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode("utf-8"),
                                     method="GET" if body is None else "POST")
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("X-CSRF-Token", token)
    try:
        with opener.open(request, timeout=10) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read().decode("utf-8"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zip", default=str(ROOT / "submissions/v1.0-final.zip"))
    parser.add_argument("--server", default=".")
    parser.add_argument("--python", default=getattr(sys, "_base_executable", sys.executable),
                        help="用来创建虚拟环境的真实 Python 解释器")
    parser.add_argument("--output", default=str(ROOT / "results/package-smoke.json"))
    args = parser.parse_args()
    archive = Path(args.zip).resolve()
    work = Path(tempfile.mkdtemp(prefix="campus-smoke-"))
    database = "CampusStoreDB_W7_Test_" + secrets.token_hex(6)
    port = free_port()
    steps, result = [], {}
    server = None
    environment = {**os.environ, "PYTHONUTF8": "1"}
    for key in ("CAMPUS_SETTINGS", "CAMPUS_DB_SERVER", "CAMPUS_DB_DATABASE", "CAMPUS_DB_DRIVER", "CAMPUS_SECRET_KEY",
                "VIRTUAL_ENV"):
        environment.pop(key, None)
    interpreter_version = subprocess.run([args.python, "--version"], capture_output=True, text=True).stdout.strip()
    code = work / "v1.0-final" / "code"
    database_created = False
    first_doctor = {}
    try:
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(work)
        commands = readme_commands(work / "v1.0-final" / "README.md")
        venv_command, install_command, doctor_command, prepare_command, start_command = commands
        run_step("1 建虚拟环境", venv_command, code, environment,
                 ["python → 指定的真实解释器：" + interpreter_version], steps, args.python)
        run_step("2 安装依赖", install_command, code, environment, [], steps)
        run_step("3 环境预检（建库之前，预期缺 instance/settings.json）",
                 doctor_command.replace('"."', '"' + args.server + '"'), code, environment,
                 ["--server 使用 " + args.server], steps, expect_failure=True)
        first_doctor = steps[-1]
        failed_items = [line for line in first_doctor["output_tail"] if line.startswith("[失败]")]
        # 建库之前一定缺 settings.json；开发库是否存在取决于这台机器上有没有默认开发库。
        first_doctor["ok"] = first_doctor["ok"] and any("settings.json" in line for line in failed_items) \
            and all("settings.json" in line or "开发库" in line for line in failed_items)
        prepare = prepare_command.replace('"."', '"' + args.server + '"') + " --database " + database
        database_created = True
        run_step("4 准备数据库", prepare, code, environment,
                 ["追加 --database " + database + "（随机测试库，结束后清理）"], steps)
        run_step("5 环境预检（建库之后，预期全部通过）", doctor_command.replace('"."', '"' + args.server + '"'),
                 code, environment, ["--server 使用 " + args.server], steps)
        start = start_command.replace("5070", str(port))
        server = subprocess.Popen(tokens(start, code), cwd=code, env=environment, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
        login = {"url": "http://127.0.0.1:" + str(port), "started": False}
        base = login["url"]
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        deadline = time.time() + 40
        while time.time() < deadline and server.poll() is None:
            try:
                status, payload = http_json(opener, base + "/api/auth/session")
                login["started"] = status == 200
                break
            except (urllib.error.URLError, ConnectionError, TimeoutError):
                time.sleep(0.5)
        if login["started"]:
            token = payload["data"]["csrf_token"]
            status, payload = http_json(opener, base + "/api/auth/login",
                                        {"username": "admin", "password": PASSWORD}, token)
            login.update(login_status=status, ok=payload.get("ok"), role=(payload.get("data") or {}).get("user", {}).get("role"),
                         message=payload.get("message"))
            if status == 200:
                status, payload = http_json(opener, base + "/api/products?page_size=5")
                login.update(products_status=status, products_total=(payload.get("data") or {}).get("total"))
        login["ok"] = bool(login.get("login_status") == 200 and login.get("role") == "ADMIN"
                           and login.get("products_status") == 200)
        steps.append({"step": "6 启动并用 admin 登录", "readme_command": start_command,
                      "replacements": ["端口 5070 → " + str(port)], "ok": login["ok"], "detail": login})
        print(("通过" if login["ok"] else "失败") + "：6 启动并用 admin 登录", flush=True)
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
        cleanup = {"database": database, "database_dropped": None, "temp_directory_removed": None}
        if database_created and code.exists():
            dropped = subprocess.run(
                [str(code / ".venv/Scripts/python.exe"), "-c",
                 "from tools.prepare_week7 import drop_owned_database; drop_owned_database(" + repr(args.server)
                 + ", " + repr(database) + ")"], cwd=code, env=environment, capture_output=True, text=True)
            exists = subprocess.run(
                ["sqlcmd", "-S", args.server, "-E", "-No", "-h", "-1", "-W", "-Q",
                 "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name=N'" + database + "'"],
                capture_output=True, text=True)
            lines = exists.stdout.strip().splitlines()
            cleanup["database_dropped"] = dropped.returncode == 0 and bool(lines) and lines[-1].strip() == "0"
        for attempt in range(5):
            shutil.rmtree(work, ignore_errors=True)
            if not work.exists():
                break
            time.sleep(1)
        cleanup["temp_directory_removed"] = not work.exists()
        steps.append({"step": "7 清理", "ok": bool(cleanup["database_dropped"] is not False and cleanup["temp_directory_removed"]),
                      "detail": cleanup})
        print("清理：" + json.dumps(cleanup, ensure_ascii=False), flush=True)
    doctor_second = next((s for s in steps if s["step"].startswith("5 ")), {})
    passed_checks = sum(line.startswith("[通过]") for line in doctor_second.get("output_tail", []))
    result = {
        "run_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "package": {"file": archive.name, "bytes": archive.stat().st_size,
                    "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                    "note": "被测 zip。最终交付的 zip 与它的差别只有 results/package-smoke.json（本文件）和重新生成的 SHA256SUMS.json"},
        "interpreter": interpreter_version, "server": args.server, "database": database, "port": port,
        "doctor_before_prepare_failed_items": [line for line in first_doctor.get("output_tail", [])
                                              if line.startswith("[失败]")] if steps else [],
        "doctor_after_prepare_passed_checks": passed_checks,
        "steps": steps,
        "passed": all(step.get("ok") for step in steps),
    }
    Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("结果：" + ("全部通过" if result["passed"] else "有失败项") + "，已写入 " + args.output)
    sys.exit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
