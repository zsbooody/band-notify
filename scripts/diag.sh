#!/usr/bin/env bash
# 一键排查："手环不震了"到底卡在哪一层
# 三查：① 扩展有没有把消息发出来 ② 手机 ntfy 有没有连着 ③ 各 harness 的 hook 有没有就位
set -uo pipefail

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
# shellcheck source=../lib/config.sh
. "$SCRIPT_DIR/../lib/config.sh"

TOPIC="${BAND_NOTIFY_TOPIC:-}"
SERVER="$BAND_NOTIFY_SERVER"
PORT="$BAND_NOTIFY_PORT"
STATE_DIR="$BAND_NOTIFY_STATE_DIR"
PROJECT="$(basename "$(pwd)")"
[ -n "$PROJECT" ] || PROJECT="unknown"
echo "项目名（通知正文里的前缀）：$PROJECT"
echo

echo "① 最近 30 分钟，服务端有没有收到【本项目】的通知？"
if [ -z "$TOPIC" ]; then
  echo "   ❌ 未配置 topic（先跑 install.sh 或设置 BAND_NOTIFY_TOPIC）"
elif JSON=$(curl -fsS -m 5 "$SERVER/$TOPIC/json?poll=1&since=30m" 2>/dev/null); then
  HIT=$(printf '%s\n' "$JSON" | grep -Fc -- "$PROJECT" || true)
  if [ "${HIT:-0}" -gt 0 ]; then
    echo "   ✅ 有 $HIT 条 → 扩展正常，消息已发出（问题在手机侧）"
    printf '%s\n' "$JSON" | grep -F -- "$PROJECT" | tail -3
  else
    echo "   ❌ 0 条 → 本窗口没发消息。逐项检查："
    echo "      · pi 窗口有没有 /reload？（扩展只在 pi 启动时加载）"
    echo "      · 扩展文件在不在：ls ~/.pi/agent/extensions/pi-vibrate.ts"
    echo "      · 本轮运行时长是否 < BAND_NOTIFY_MIN_RUN_MS（默认 10 秒，短问答不提醒）"
    echo "      · 是否设了 PI_VIBRATE_DISABLE=1"
    echo "      · 手机端是否在线（看第 ② 步）"
  fi
else
  echo "   ❌ 无法读取服务端缓存：ntfy 未运行、端口不对，或 topic 不存在"
  echo "      → 先跑 band-notify-check"
fi
echo

echo "② 手机 ntfy 现在连上了吗（订阅者数）？"
if METRICS=$(curl -fsS -m 3 "$SERVER/metrics" 2>/dev/null); then
  SUB=$(printf '%s\n' "$METRICS" | awk '/^ntfy_subscribers_total/{print $2; exit}')
  if [ -n "${SUB:-}" ] && [ "$SUB" -ge 1 ] 2>/dev/null; then
    echo "   ✅ subscribers=$SUB → 手机在线"
    ss -tn state established "( sport = :$PORT )" 2>/dev/null | tail -n +2 | sed 's/^/      /'
  else
    echo "   ❌ subscribers=${SUB:-?} → 手机 App 没连上"
    echo "      检查省电策略=无限制/自启动/后台锁定；打开一下 ntfy App"
  fi
else
  echo "   ❌ 无法读取 $SERVER/metrics（服务未运行或 enable-metrics 关闭）"
fi
echo

echo "③ 各 harness 的 hook 就位情况"
LIB_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
HOOK=$(command -v band-notify-hook 2>/dev/null || true)
[ -n "$HOOK" ] || HOOK="$LIB_ROOT/bin/band-notify-hook"
if [ -n "$HOOK" ] && [ -x "$HOOK" ]; then
  echo "   ✅ 通用钩子 band-notify-hook 可执行（$HOOK）"
else
  echo "   ❌ 缺 band-notify-hook（跑 install.sh）"
fi

PI_EXT="$HOME/.pi/agent/extensions/pi-vibrate.ts"
if [ -s "$PI_EXT" ]; then
  echo "   ✅ pi: 扩展文件存在（改过之后需在该窗口 /reload）"
else
  echo "   - pi: 未安装扩展（可选）"
fi

if [ -d "$HOME/.grok/hooks" ] && ls "$HOME"/.grok/hooks/*.json >/dev/null 2>&1; then
  echo "   ✅ grok: 已配置 $(ls "$HOME"/.grok/hooks/*.json | wc -l) 个 hook 文件"
  command -v grok >/dev/null 2>&1 && echo "      $(grok inspect 2>/dev/null | grep -A1 'Hooks (' | head -2 | tr '\n' ' ')"
else
  echo "   - grok: 未配置（可选）"
fi

if [ -f "$HOME/.kimi-code/config.toml" ]; then
  if grep -q 'event = "Stop"' "$HOME/.kimi-code/config.toml" 2>/dev/null; then
    echo "   ✅ kimi: config.toml 里 Stop hook 已配置"
  else
    echo "   ⚠️ kimi: config.toml 存在，但没有 Stop hook"
  fi
else
  echo "   - kimi: 未配置（可选）"
fi

ZCODE_CONFIG="$HOME/.zcode/cli/config.json"
ZCODE_GATE=$(command -v zcode-notify-gate 2>/dev/null || true)
ZCODE_WAITER=$(command -v zcode-settle-wait 2>/dev/null || true)
[ -n "$ZCODE_GATE" ] || ZCODE_GATE="$LIB_ROOT/bin/zcode-notify-gate"
[ -n "$ZCODE_WAITER" ] || ZCODE_WAITER="$LIB_ROOT/bin/zcode-settle-wait"
ZCODE_LOGSTATE="$LIB_ROOT/lib/zcode-notify/logstate.py"
if [ -f "$ZCODE_CONFIG" ] && grep -q '"Stop"' "$ZCODE_CONFIG" 2>/dev/null; then
  if grep -q '"enabled": *true' "$ZCODE_CONFIG" 2>/dev/null; then
    if grep -q 'zcode-notify-gate' "$ZCODE_CONFIG" 2>/dev/null \
       && [ -x "$ZCODE_GATE" ] && [ -x "$ZCODE_WAITER" ] && [ -s "$ZCODE_LOGSTATE" ]; then
      echo "   ✅ zcode: Stop → 闸门，等待器 + 共用判定模块就位"
      echo "      最近判定：$(tail -1 "$STATE_DIR/zcode-gate.log" 2>/dev/null | cut -c1-110)"
    else
      echo "   ⚠️ zcode: Stop hook 在，但闸门/等待器/logstate 不齐（会退回裸钩子或按节点连震）"
    fi
  else
    echo "   ⚠️ zcode: Stop hook 在，但 hooks.enabled 不是 true（整段不生效）"
  fi
elif [ -f "$ZCODE_CONFIG" ]; then
  echo "   - zcode: 没有配置 Stop hook（可选）"
else
  echo "   - zcode: 未安装（可选）"
fi

DSH_PROFILE="${BAND_NOTIFY_DSH_PROFILE:-$HOME/.dsh/profiles/desktop}"
DSH_LOG="$STATE_DIR/dsh-band-notify.log"
if [ -e "$DSH_PROFILE/node_modules/dsh-band-notify" ] \
   && grep -q '"dsh-band-notify"' "$DSH_PROFILE/package.json" 2>/dev/null; then
  echo "   ✅ dsh: 插件已 link 进 desktop profile（改完靠 HMR 自动重组，不用重启）"
  if grep -q 'loaded v' "$DSH_LOG" 2>/dev/null; then
    echo "      最近加载：$(grep 'loaded v' "$DSH_LOG" | tail -1 | cut -c1-105)"
  elif grep -q 'disabled: no topic configured' "$DSH_LOG" 2>/dev/null; then
    echo "      ⚠️ 插件已加载但未配置 topic：先跑 install.sh，或在 DSH 配置里设置 topic"
  else
    echo "      ⚠️ 插件日志里没有 loaded：DSH 没重组/插件加载失败"
  fi
  grep -q 'sent ' "$DSH_LOG" 2>/dev/null && echo "      最近推送：$(grep 'sent ' "$DSH_LOG" | tail -1 | cut -c1-105)"
  grep -q 'skip turn/end' "$DSH_LOG" 2>/dev/null && echo "      最近跳过：$(grep 'skip turn/end' "$DSH_LOG" | tail -1 | cut -c1-105)"
else
  echo "   - dsh: 未挂载插件（可选；装法见 docs/harness-dsh.md）"
fi
echo

echo "④ 结论速查"
cat <<'TIP'
   ①有 + ②在  + 手环不震 → 手机弹没弹？
        手机弹了       → 运动健康：ntfy 是否勾选 / 提醒模式是否"多设备提醒"；手环勿扰、振动强度、是否在充电座上
        手机没弹       → 手机通知权限/静音/被系统冻结
   ①有 + ②不在        → 手机 App 掉线了（省电策略没设"无限制"）
   ①无                → 扩展没生效（/reload）或没达到提醒门槛
TIP
