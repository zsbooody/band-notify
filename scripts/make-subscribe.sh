#!/usr/bin/env bash
# 按当前局域网 IP 重新生成订阅二维码/页面。
# 热点换网段后跑这个 → 手机扫新码重新订阅。
set -euo pipefail
umask 077

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
# shellcheck source=../lib/config.sh
. "$SCRIPT_DIR/../lib/config.sh"

band_notify_require_topic

IP=$(band_notify_lan_ip "${BAND_NOTIFY_IFACE:-}")
[ -n "$IP" ] || { echo "✗ 没探测到局域网 IPv4，先连上手机热点（或设置 BAND_NOTIFY_IFACE）" >&2; exit 1; }

PORT="$BAND_NOTIFY_PORT"
TOPIC="$BAND_NOTIFY_TOPIC"
LINK="ntfy://${IP}:${PORT}/${TOPIC}?secure=false"
OUT_DIR="${BAND_NOTIFY_SUBSCRIBE_DIR:-$BAND_NOTIFY_STATE_DIR}"
QR="$OUT_DIR/subscribe-qr.png"
HTML="$OUT_DIR/subscribe.html"
mkdir -p "$OUT_DIR"

escape_html() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

QR_HTML=""
if command -v qrencode >/dev/null 2>&1; then
  qrencode -o "$QR" -s 8 -m 3 "$LINK"
  B64=$(base64 "$QR" | tr -d '\n')
  QR_HTML="<p><img src=\"data:image/png;base64,${B64}\" width=\"320\" height=\"320\" alt=\"ntfy 订阅二维码\"></p>"
else
  rm -f "$QR"
  QR_HTML="<p style=\"color:#b00\">未安装 <code>qrencode</code>，无法生成二维码；请按下面的手动步骤订阅，或安装 qrencode 后重跑。</p>"
  echo "! 未安装 qrencode，已生成无二维码的手动订阅页" >&2
fi

TOPIC_HTML=$(printf '%s' "$TOPIC" | escape_html)
LINK_HTML=$(printf '%s' "$LINK" | escape_html)
SERVER_HTML=$(printf 'http://%s:%s' "$IP" "$PORT" | escape_html)

cat >"$HTML" <<HTML
<!doctype html>
<html lang="zh">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ntfy 订阅 · band-notify</title>
<body style="font-family:system-ui,sans-serif;max-width:720px;margin:40px auto;padding:0 16px;line-height:1.7">
<h1>手机扫码直接订阅</h1>
<p>手机「相机 / 扫一扫」扫下面的码 → 自动打开 ntfy App 并订阅该 topic（HTTP，所以链接里带 <code>secure=false</code>）。</p>
${QR_HTML}
<h2>扫码没反应就手动填</h2>
<table border="1" cellpadding="8" cellspacing="0">
<tr><td><b>Server</b></td><td><code>${SERVER_HTML}</code></td></tr>
<tr><td><b>Topic</b></td><td><code>${TOPIC_HTML}</code></td></tr>
</table>
<p>ntfy → 右下角 <b>＋</b> → 填 Topic → 勾 <b>Use another server</b> → Server 填上面的地址 → Subscribe。</p>
<h2>深链原文</h2>
<p><code>${LINK_HTML}</code></p>
<p style="color:#888">生成时间：$(date '+%F %T')　本机 IP：${IP}</p>
</body>
</html>
HTML
chmod 600 "$HTML" 2>/dev/null || true
[ -f "$QR" ] && chmod 600 "$QR" 2>/dev/null || true

echo "✓ 已刷新：IP=${IP}  port=${PORT}  topic=${TOPIC}"
echo "  深链：${LINK}"
echo "  页面：${HTML}"
echo "  二维码：${QR}"
command -v xdg-open >/dev/null 2>&1 && echo "  打开：xdg-open ${HTML}"
