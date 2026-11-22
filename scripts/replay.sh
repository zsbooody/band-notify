#!/usr/bin/env bash
# replay.sh —— 把 ZCode 日志截到某一刻，做成“当时状态”的快照。
#
# 用途：复现闸门 zcode-notify-gate / 等待器 zcode-settle-wait 在某个历史时刻的判定。
# 全程 DRY_RUN，不会真震。
#
# 用法：
#   band-notify-replay <输出目录> <UTC 截止时刻>
# 例：
#   band-notify-replay /tmp/rp 2026-10-08T10:20:30Z
#   SOURCE_LOG=~/.zcode/cli/log/zcode-2026-10-08.jsonl band-notify-replay /tmp/rp 2026-10-08T10:20:30Z
#
# 截完这样跑（快照是旧的，必须把陈旧阈值设大，才等价于“当时还是实时”）：
#   echo '{"session_id":"sess_xxx"}' | \
#     ZCODE_NOTIFY_LOG_DIR=<输出目录> BAND_NOTIFY_STATE_DIR=/tmp/replay-state \
#     BAND_NOTIFY_CONFIG_DIR=/tmp/replay-config \
#     ZCODE_NOTIFY_DRY_RUN=1 ZCODE_NOTIFY_MAX_WAIT=8 \
#     ZCODE_NOTIFY_TURN_STALE=86400 ZCODE_NOTIFY_TOOL_STALE=86400 \
#     zcode-settle-wait
set -uo pipefail

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
# shellcheck source=../lib/config.sh
. "$SCRIPT_DIR/../lib/config.sh"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

DEST="${1:-}"
CUT="${2:-}"
LOG_DIR="${ZCODE_NOTIFY_LOG_DIR:-${ZCODE_LOG_DIR:-$BAND_NOTIFY_ZCODE_LOG_DIR}}"
SOURCE_LOG="${SOURCE_LOG:-}"

if [ -z "$DEST" ] || [ -z "$CUT" ]; then
  usage
  exit 2
fi

mkdir -p "$DEST"
if [ "$(readlink -f "$DEST" 2>/dev/null)" = "$(readlink -f "$LOG_DIR" 2>/dev/null)" ]; then
  echo "✗ 输出目录不能等于日志目录（会截断源日志）" >&2
  exit 2
fi

DEST="$DEST" CUT="$CUT" LOG_DIR="$LOG_DIR" SOURCE_LOG="$SOURCE_LOG" python3 - <<'PY'
import json
import os
import pathlib
import sys

dest = pathlib.Path(os.environ["DEST"])
cut = os.environ["CUT"]
log_dir = pathlib.Path(os.environ["LOG_DIR"])
source_override = os.environ.get("SOURCE_LOG", "")

day = cut[:10]
requested = log_dir / ("zcode-%s.jsonl" % day)

if source_override:
    src = pathlib.Path(source_override)
    if not src.exists():
        sys.exit("找不到 SOURCE_LOG：%s" % src)
else:
    if requested.exists():
        src = requested
    else:
        candidates = sorted(log_dir.glob("zcode-*.jsonl"))
        if not candidates:
            sys.exit("找不到日志：%s" % log_dir)
        # 只选文件名日期 <= 截止日的最近一份，避免选到截止时刻之后的日志。
        eligible = []
        for path in candidates:
            name = path.name
            file_day = name[len("zcode-"):-len(".jsonl")] if name.startswith("zcode-") and name.endswith(".jsonl") else ""
            if len(file_day) == 10 and file_day <= day:
                eligible.append(path)
        if not eligible:
            sys.exit("没有不晚于 %s 的日志（可用：%s）" % (day, ", ".join(p.name for p in candidates)))
        src = eligible[-1]
        print("（%s 不存在，用 %s 代替）" % (requested.name, src.name))

good = 0
with open(src, "rb") as f:
    for raw in f:
        try:
            ts = json.loads(raw.decode("utf-8", "replace")).get("timestamp")
        except ValueError:
            ts = None
        if ts and ts > cut:
            break
        good += len(raw)

dest.mkdir(parents=True, exist_ok=True)
out = dest / src.name
with open(src, "rb") as f:
    out.write_bytes(f.read(good))
print("写出 %s（%d 字节，最后一条事件 ≤ %s）" % (out, good, cut))
PY
