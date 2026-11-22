#!/usr/bin/env python3
"""不写 __pycache__ 的 Python 语法检查。"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = [
    *ROOT.glob("bin/*"),
    *ROOT.glob("lib/**/*.py"),
    *ROOT.glob("tests/*.py"),
]

checked = 0
failed = 0
for path in FILES:
    if path.is_dir():
        continue
    if path.suffix != ".py" and path.name not in {"zcode-notify-gate", "zcode-settle-wait"}:
        continue
    try:
        compile(path.read_text(encoding="utf-8"), str(path), "exec")
        checked += 1
    except SyntaxError as exc:
        failed += 1
        print(f"FAIL {path}: {exc}", file=sys.stderr)

print(f"Python 语法检查：{checked} 个文件通过，{failed} 个失败")
sys.exit(1 if failed else 0)
