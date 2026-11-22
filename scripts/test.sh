#!/usr/bin/env bash
# 本地测试：语法检查 + Python 单测 + dsh 插件离线自测。不碰真 ntfy / 真 harness。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

echo "== bash -n =="
for f in install.sh uninstall.sh lib/config.sh \
         bin/band-notify bin/band-notify-hook \
         scripts/*.sh; do
  bash -n "$f"
  printf '  ok  %s\n' "$f"
done

echo "== shellcheck（可选） =="
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S error install.sh uninstall.sh lib/config.sh bin/band-notify bin/band-notify-hook scripts/*.sh
  echo "  ok"
else
  echo "  - 未安装 shellcheck，跳过"
fi

echo "== node --check =="
node --check dsh-plugin/index.js
node --check dsh-plugin/test/simulate.mjs
echo "  ok"

echo "== Python 语法 =="
PYTHONDONTWRITEBYTECODE=1 python3 tests/check_syntax.py

echo "== Python 单测 =="
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v

echo "== dsh 插件离线自测 =="
node dsh-plugin/test/simulate.mjs

echo
echo "✅ 全部通过"
