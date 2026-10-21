import argparse

from waitress import serve

from . import create_app

parser = argparse.ArgumentParser(description="校园小卖部 Web 应用")
parser.add_argument("--port", type=int, default=5070)
args = parser.parse_args()
print(f"校园小卖部：http://127.0.0.1:{args.port}（Ctrl+C 停止）", flush=True)
serve(create_app(), host="127.0.0.1", port=args.port, threads=6, expose_tracebacks=False)
