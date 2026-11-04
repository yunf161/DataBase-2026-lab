"""生成最终交付包 submissions/v1.0-final 及同名 zip。

只在源仓库中运行（包内的 tools 目录仅作为交付内容）；只创建或重建 v1.0-final，不触碰其他提交目录。
包内结构：README.md、code/（应用、SQL、测试、工具）、results/、docs/、report/、ai_log/、SHA256SUMS.json。
文本文件中的本机路径替换成占位符，仓库里的原始文件不改；Markdown 的相对链接按包内位置改写，并在最后逐个检查。
"""
import argparse
import hashlib
import json
import posixpath
import re
import shutil
import sys
import zipfile
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
NAME = "v1.0-final"
CODE_DIRS = ["app", "sql", "tests", "tools", "submissions/v0.1-week4/sql"]
# Verify-CampusStore.ps1 在 code/docs/week5-er 下读取这一份只读验证 SQL。
CODE_FILES = ["requirements.txt", "requirements-dev.txt", "requirements-lock.txt", "pytest.ini",
              "docs/week5-er/verification.sql"]
DOC_DIRS = ["results", "docs", "report", "ai_log"]
# 复制自第 1—4 周和第 6 周的原始 AI 记录：只替换本机路径，不改写其中的相对链接（它们原本指向旧提交包的内部结构）。
KEEP_LINKS = ("ai_log/week1-4/", "ai_log/week6/")
SKIP_DIR_NAMES = {"__pycache__", ".venv", "instance", ".vs", ".pytest_cache", ".git"}
SKIP_FILES = {".github/copilot-instructions.md"}
SKIP_SUFFIXES = {".pyc"}
TEXT_SUFFIXES = {".md", ".txt", ".json", ".jsonl", ".xml", ".csv", ".svg", ".drawio", ".sql", ".py", ".ps1",
                 ".cjs", ".ini", ".html", ".css", ".js"}
SEP = r"(?:\\\\|\\|/)"
REPO_PATH = re.compile(r"[A-Za-z]:" + SEP + "class" + SEP + "grade3" + SEP + "database" + SEP + "repos", re.I)
HOME_PATH = re.compile(r"[A-Za-z]:" + SEP + r"Users" + SEP + r"[^\\/\s\"'<>|:*?,;)\]]+", re.I)
LOCAL_PATH = re.compile(r"[A-Za-z]:" + SEP + r"(?:Users|class)" + SEP, re.I)
LINK = re.compile(r"(!?\[[^\]\n]*\]\()([^)\s]+)((?:\s+\"[^\"]*\")?\))")
NOTICE = """
> **交付包说明（v1.0-final）**：包根目录有 `README.md`（本文件）、`code/`、`results/`、`docs/`、`report/`、`ai_log/` 和 `SHA256SUMS.json`。
> **所有命令都要先进入 `code/` 目录再运行**（`cd code`）。下文提到的 `app/`、`sql/`、`tests/`、`tools/`、`requirements*.txt` 都在 `code/` 下，
> “项目结构图”描述的是源仓库，对应关系是：仓库根目录 = `code/`。`results/`、`docs/`、`report/`、`ai_log/` 在包根目录，文中的相对链接已按包内位置改写。
> 工具运行时产生的 `instance/`、`.venv/` 也都建在 `code/` 下。
"""


def skipped(relative):
    parts = relative.split("/")
    return (relative in SKIP_FILES or any(part in SKIP_DIR_NAMES for part in parts)
            or Path(relative).suffix in SKIP_SUFFIXES)


def collect():
    """返回 [(源相对路径, 包内相对路径)]。"""
    entries = []
    for directory in CODE_DIRS:
        for path in sorted((ROOT / directory).rglob("*")):
            relative = path.relative_to(ROOT).as_posix()
            if path.is_file() and not skipped(relative):
                entries.append((relative, "code/" + relative))
    for relative in CODE_FILES:
        if not (ROOT / relative).is_file():
            raise SystemExit("缺少文件：" + relative)
        entries.append((relative, "code/" + relative))
    for directory in DOC_DIRS:
        for path in sorted((ROOT / directory).rglob("*")):
            relative = path.relative_to(ROOT).as_posix()
            if path.is_file() and not skipped(relative):
                entries.append((relative, relative))
    entries.append(("README.md", "README.md"))
    return entries


def sanitize(text):
    text = REPO_PATH.sub("<REPO_ROOT>", text)
    return HOME_PATH.sub("<USER_HOME>", text)


def mapping_directory(source_directory, mapping):
    """目录链接：由其下任一文件在包内的位置推出该目录在包内的位置。"""
    prefix = source_directory.rstrip("/") + "/"
    for source, location in mapping.items():
        if source.startswith(prefix):
            depth = source[len(prefix):].count("/")
            return posixpath.normpath(posixpath.join(posixpath.dirname(location), *([".."] * depth)))
    return None


def rewrite_links(text, source_relative, mapping, dropped):
    base = posixpath.dirname(source_relative)
    target_base = posixpath.dirname(mapping[source_relative])

    def replace(match):
        opener, target, closer = match.groups()
        if re.match(r"^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|#|<)", target):
            return match.group(0)
        path, hash_mark, fragment = unquote(target).partition("#")
        resolved = posixpath.normpath(posixpath.join(base, path))
        new_location = mapping.get(resolved) or mapping_directory(resolved, mapping)
        if new_location is None:
            dropped.append((source_relative, target))
            return opener[:-2].lstrip("!")[1:] + "（包内未收录）"
        relative = posixpath.relpath(new_location, target_base)
        if path.endswith("/"):
            relative += "/"
        return opener + relative + (hash_mark + fragment if hash_mark else "") + closer

    lines, fenced = [], False
    for line in text.split("\n"):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            lines.append(line)
        else:
            lines.append(line if fenced else LINK.sub(replace, line))
    return "\n".join(lines)


def build(output):
    mapping = dict(collect())
    problems, dropped, code_hits = [], [], []
    if output.exists():
        shutil.rmtree(output)
    for source_relative, location in mapping.items():
        data = (ROOT / source_relative).read_bytes()
        suffix = Path(source_relative).suffix
        is_code = location.startswith("code/")
        if suffix in TEXT_SUFFIXES:
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                problems.append("非 UTF-8 文本，原样复制：" + source_relative)
                text = None
            if text is not None:
                if is_code:
                    if LOCAL_PATH.search(text):
                        code_hits.append(source_relative)
                else:
                    text = sanitize(text)
                    if suffix == ".md" and not location.startswith(KEEP_LINKS):
                        text = rewrite_links(text, source_relative, mapping, dropped)
                        if source_relative == "README.md":
                            first_break = text.index("\n")
                            text = text[:first_break + 1] + NOTICE + text[first_break + 1:]
                    data = text.encode("utf-8")
        destination = output / location
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    return mapping, problems, dropped, code_hits


def write_checksums(output):
    sums = {}
    for path in sorted(output.rglob("*")):
        relative = path.relative_to(output).as_posix()
        if path.is_file() and relative != "SHA256SUMS.json":
            sums[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    (output / "SHA256SUMS.json").write_text(json.dumps(sums, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return sums


def make_zip(output, archive):
    if archive.exists():
        archive.unlink()
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(output.rglob("*")):
            if path.is_file():
                bundle.write(path, NAME + "/" + path.relative_to(output).as_posix())


def verify(output, archive, sums):
    failures = []
    on_disk = {p.relative_to(output).as_posix() for p in output.rglob("*") if p.is_file()}
    for relative in sorted(on_disk - {"SHA256SUMS.json"}):
        if hashlib.sha256((output / relative).read_bytes()).hexdigest() != sums.get(relative):
            failures.append("校验和不一致：" + relative)
    with zipfile.ZipFile(archive) as bundle:
        names = {n[len(NAME) + 1:] for n in bundle.namelist() if not n.endswith("/")}
        if names != on_disk:
            failures.append("zip 与目录文件不一致：" + ", ".join(sorted(names ^ on_disk)[:5]))
        for relative in sorted(names - {"SHA256SUMS.json"}):
            if hashlib.sha256(bundle.read(NAME + "/" + relative)).hexdigest() != sums.get(relative):
                failures.append("zip 内校验和不一致：" + relative)
    for relative in on_disk:
        parts = relative.split("/")
        if any(p in SKIP_DIR_NAMES for p in parts) or relative.endswith("copilot-instructions.md") or relative.endswith(".pyc"):
            failures.append("包含不应打包的文件：" + relative)
        if not relative.startswith("code/") and Path(relative).suffix in TEXT_SUFFIXES:
            try:
                text = (output / relative).read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            if LOCAL_PATH.search(text):
                failures.append("仍含本机路径：" + relative)
        if relative.endswith(".md") and not relative.startswith(KEEP_LINKS):
            failures.extend(check_links(output, relative))
    return failures


def check_links(output, relative):
    failures, fenced = [], False
    base = posixpath.dirname(relative)
    text = (output / relative).read_text(encoding="utf-8")
    for number, line in enumerate(text.split("\n"), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        for match in LINK.finditer(line):
            target = match.group(2)
            if re.match(r"^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|#|<)", target):
                continue
            path = unquote(target).partition("#")[0]
            if not path:
                continue
            resolved = posixpath.normpath(posixpath.join(base, path))
            if resolved.startswith("..") or not (output / resolved).exists():
                failures.append("失效链接 " + relative + ":" + str(number) + " → " + target)
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", default=str(ROOT / "submissions"))
    args = parser.parse_args()
    root = Path(args.output_root).resolve()
    output, archive = root / NAME, root / (NAME + ".zip")
    mapping, problems, dropped, code_hits = build(output)
    sums = write_checksums(output)
    make_zip(output, archive)
    failures = verify(output, archive, sums)
    print("已生成：" + str(output) + "（" + str(len(sums)) + " 个文件，不含 SHA256SUMS.json）")
    print("zip：" + str(archive) + "，" + str(archive.stat().st_size) + " 字节")
    for source, target in dropped:
        print("未收录的链接目标已改为纯文本：" + source + " → " + target)
    for item in problems:
        print("注意：" + item)
    for item in code_hits:
        print("注意：代码文件中含本机路径形式的文本（未修改）：" + item)
    for item in failures:
        print("失败：" + item)
    if failures:
        sys.exit(1)
    print("校验通过。")


if __name__ == "__main__":
    main()
