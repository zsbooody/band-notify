#!/usr/bin/env bash
# 断网重连演练：每隔 5 秒发一条，共 3 条。
# 用法：手机先关 WiFi → 在本机跑 band-notify-drill → 等它跑完 → 手机开 WiFi → 看收到几条。
set -uo pipefail

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
# shellcheck source=../lib/config.sh
. "$SCRIPT_DIR/../lib/config.sh"

NOTIFY="$SCRIPT_DIR/../bin/band-notify"
if [ ! -x "$NOTIFY" ]; then
  echo "✗ 找不到可执行的 bin/band-notify" >&2
  exit 1
fi

FAIL=0
for i in 1 2 3; do
  if "$NOTIFY" "离线演练 #$i" "第 $i 条 / 共 3 条（$(date +%H:%M:%S)）" 5; then
    :
  else
    echo "! 第 $i 条发送失败" >&2
    FAIL=1
  fi
  [ "$i" -lt 3 ] && sleep 5
done

if [ "$FAIL" -ne 0 ]; then
  echo "有发送失败：先检查 band-notify-check 和 ntfy 服务状态。" >&2
  exit 1
fi
echo "发完了。现在把手机 WiFi 打开，看能看到几条：3 条=会自动补发；1 条或 0 条=App 不做缓存补发。"
