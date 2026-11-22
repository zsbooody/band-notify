#!/usr/bin/env bash
# 链路自检：ntfy 服务 → 发一条测试通知 → 回读确认
set -uo pipefail

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
# shellcheck source=../lib/config.sh
. "$SCRIPT_DIR/../lib/config.sh"

TOPIC="${BAND_NOTIFY_TOPIC:-}"
SERVER="$BAND_NOTIFY_SERVER"
PORT="$BAND_NOTIFY_PORT"
UNIT="${BAND_NOTIFY_SYSTEMD_UNIT:-}"
SUBSCRIBE_PAGE="$BAND_NOTIFY_SUBSCRIBE_DIR/subscribe.html"
LANIP=$(band_notify_lan_ip "$BAND_NOTIFY_IFACE")
FAIL=0

printf '手机端应订阅：http://%s:%s  (topic %s)\n' "${LANIP:-<LAN_IP>}" "$PORT" "${TOPIC:-<未配置>}"
[ -n "$TOPIC" ] || { printf '! 未配置 topic：先跑 install.sh，或设置 BAND_NOTIFY_TOPIC\n'; FAIL=1; }
[ -n "$LANIP" ] || printf '! 没探测到局域网 IPv4（网卡 %s），手机可能连不上\n' "${BAND_NOTIFY_IFACE:-auto}"

echo "== 1. systemd 服务 =="
if [ -z "$UNIT" ]; then
  echo "- 未配置 systemd 单元（--no-systemd 或手动运行 ntfy），跳过"
elif systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
  echo "✓ $UNIT 正在运行"
else
  echo "✗ $UNIT 未运行：systemctl --user start $UNIT"
  FAIL=1
fi

echo "== 2. 端口监听 =="
if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}$"; then
  echo "✓ :$PORT 正在监听"
else
  echo "✗ $PORT 未监听"
  FAIL=1
fi

echo "== 3. 防火墙（可选）=="
if command -v ufw >/dev/null 2>&1; then
  if sudo -n ufw status 2>/dev/null | grep -qE "(^|[^0-9])${PORT}(/tcp)?([^0-9]|$)"; then
    echo "✓ ufw 已放行 $PORT"
  else
    echo "! 未查到 ufw $PORT 规则（若手机连不上，检查防火墙）"
  fi
else
  echo "- 未安装 ufw，跳过"
fi

echo "== 3.5 手机订阅状态 =="
if METRICS=$(curl -fsS -m 2 "$SERVER/metrics" 2>/dev/null); then
  SUBS=$(printf '%s\n' "$METRICS" | awk '/^ntfy_subscribers_total/{print $2; exit}')
  if [ "${SUBS:-0}" = "0" ]; then
    echo "! 手机端当前不在线（subscribers=0）：通知只会进 ntfy 缓存，手环不会振"
    echo "  → 打开手机 ntfy App 让它重连；省电策略设为「无限制」、允许自启动/后台运行"
  else
    echo "✓ 手机端在线（subscribers=${SUBS:-?}）"
  fi
else
  echo "✗ 无法读取 $SERVER/metrics（ntfy 未运行、端口不对，或 enable-metrics 关闭）"
  FAIL=1
fi

echo "== 3.6 订阅码是否当前网段 =="
if [ ! -f "$SUBSCRIBE_PAGE" ]; then
  echo "! 还没生成订阅页：跑 band-notify-subscribe"
else
  PAGE_IP=$(grep -oE 'ntfy://[0-9.]+:[0-9]+' "$SUBSCRIBE_PAGE" 2>/dev/null | head -1 | sed 's#^ntfy://##; s#:[0-9]*$##')
  if [ -z "${PAGE_IP:-}" ]; then
    echo "! subscribe.html 里没找到订阅地址（重跑 band-notify-subscribe）"
  elif [ "$PAGE_IP" = "${LANIP:-}" ]; then
    echo "✓ 订阅码是本机当前 IP（$LANIP）"
  else
    echo "! 订阅码是旧 IP（$PAGE_IP），本机现在是 ${LANIP:-?} —— 手机端连的是旧地址"
    echo "  → 跑 band-notify-subscribe 重新生成，手机重扫一次"
    FAIL=1
  fi
fi

echo "== 4. 发送测试通知（priority 5，手环应振动）=="
if [ -n "$TOPIC" ] && [ -x "$SCRIPT_DIR/../bin/band-notify" ]; then
  if "$SCRIPT_DIR/../bin/band-notify" "链路自检" "看到这条 + 手环振动 = 全链路通" 5; then
    echo "✓ 已发送到 topic $TOPIC"
  else
    echo "✗ 发送失败"
    FAIL=1
  fi
else
  echo "✗ 缺少 topic 或 bin/band-notify，跳过发送"
  FAIL=1
fi

echo "== 5. 回读确认 =="
sleep 1
if [ -n "$TOPIC" ]; then
  curl -fsS -m 5 "$SERVER/$TOPIC/json?poll=1&since=1m" 2>/dev/null | tail -1 || {
    echo "! 回读失败（服务端缓存不可读）"
    FAIL=1
  }
fi

cat <<'TIP'

现在看手机：
  手机收到通知、但手环没振 → 华为运动健康 > 设备 > 消息通知 里勾选 ntfy，并把提醒模式设为「多设备提醒」
  手机也没收到          → 手机浏览器打开 SERVER 地址测试连通性；检查 ntfy App 是否在订阅该 topic
  换过热点/重启过手机    → 网段可能变了：跑 band-notify-subscribe 重新扫码（第 3.6 步会告诉你）
TIP

exit "$FAIL"
