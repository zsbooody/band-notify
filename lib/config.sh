#!/usr/bin/env bash
# band-notify 共享配置（shell 版）
#
# 优先级：环境变量 > ${XDG_CONFIG_HOME:-~/.config}/band-notify/env > 默认值
# 所有脚本都 source 本文件，避免 topic / 端口 / 网卡 / 路径散落在各处。

BAND_NOTIFY_CONFIG_DIR="${BAND_NOTIFY_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/band-notify}"
BAND_NOTIFY_ENV_FILE="${BAND_NOTIFY_ENV_FILE:-$BAND_NOTIFY_CONFIG_DIR/env}"

if [ -f "$BAND_NOTIFY_ENV_FILE" ]; then
  # env 文件只补缺省，不覆盖调用者已设置的真实环境变量。
  __bn_saved_names=()
  __bn_saved_values=()
  while IFS= read -r __bn_name; do
    __bn_saved_names+=("$__bn_name")
    __bn_saved_values+=("${!__bn_name}")
  done < <(compgen -v 2>/dev/null | grep -E '^BAND_NOTIFY_' || true)
  set -a
  # shellcheck disable=SC1090
  . "$BAND_NOTIFY_ENV_FILE"
  set +a
  if [ "${#__bn_saved_names[@]}" -gt 0 ]; then
    for __bn_i in "${!__bn_saved_names[@]}"; do
      export "${__bn_saved_names[$__bn_i]}=${__bn_saved_values[$__bn_i]}"
    done
  fi
  unset __bn_saved_names __bn_saved_values __bn_name __bn_i
fi

: "${BAND_NOTIFY_SERVER:=http://127.0.0.1:2586}"
if [ -z "${BAND_NOTIFY_PORT:-}" ]; then
  BAND_NOTIFY_PORT=$(printf '%s' "$BAND_NOTIFY_SERVER" | sed -nE 's#^[a-zA-Z]+://[^/:]+:([0-9]+).*#\1#p')
  BAND_NOTIFY_PORT="${BAND_NOTIFY_PORT:-2586}"
fi
: "${BAND_NOTIFY_TOPIC:=}"
: "${BAND_NOTIFY_IFACE:=wlan0}"
: "${BAND_NOTIFY_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/band-notify}"
: "${BAND_NOTIFY_CONFIG_JSON:=$BAND_NOTIFY_CONFIG_DIR/config.json}"
: "${BAND_NOTIFY_SUBSCRIBE_DIR:=$BAND_NOTIFY_STATE_DIR}"
: "${BAND_NOTIFY_ZCODE_LOG_DIR:=$HOME/.zcode/cli/log}"
: "${BAND_NOTIFY_ZCODE_PROCESS:=/opt/ZCode/zcode}"
: "${BAND_NOTIFY_MIN_RUN_MS:=10000}"
: "${BAND_NOTIFY_CONFIRM_MS:=180000}"
: "${BAND_NOTIFY_RETRY_MS:=15000}"

export BAND_NOTIFY_CONFIG_DIR BAND_NOTIFY_SERVER BAND_NOTIFY_PORT BAND_NOTIFY_TOPIC \
  BAND_NOTIFY_IFACE BAND_NOTIFY_STATE_DIR BAND_NOTIFY_CONFIG_JSON BAND_NOTIFY_SUBSCRIBE_DIR \
  BAND_NOTIFY_ZCODE_LOG_DIR BAND_NOTIFY_ZCODE_PROCESS BAND_NOTIFY_MIN_RUN_MS \
  BAND_NOTIFY_CONFIRM_MS BAND_NOTIFY_RETRY_MS

# topic 是 ntfy 的访问凭据：只允许 ntfy 支持的字符，避免拼进 JSON/URL 时被注入。
band_notify_require_topic() {
  if [ -z "${BAND_NOTIFY_TOPIC:-}" ]; then
    printf 'band-notify：未配置 topic。请先运行 install.sh，或编辑 %s 设置 BAND_NOTIFY_TOPIC。\n' \
      "$BAND_NOTIFY_ENV_FILE" >&2
    return 1
  fi
  case "$BAND_NOTIFY_TOPIC" in
    *[!A-Za-z0-9_-]*)
      printf 'band-notify：topic 只能包含字母、数字、下划线和连字符（当前值含非法字符）。\n' >&2
      return 1
      ;;
  esac
}

# 解析当前脚本的真实目录（支持被 symlink 到 ~/.local/bin 的情况）。
band_notify_script_dir() {
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  local path
  path=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")
  dirname "$path"
}

# 按优先级探测一个非回环 IPv4 网卡地址：显式 IFACE > 默认路由网卡 > wlan0 > 第一个非回环地址。
band_notify_lan_ip() {
  local iface="${1:-${BAND_NOTIFY_IFACE:-}}"
  local ip=""
  if [ -n "$iface" ]; then
    ip=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  fi
  if [ -z "$ip" ]; then
    iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    [ -n "$iface" ] && ip=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  fi
  if [ -z "$ip" ]; then
    ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '$2 != "lo" {print $4}' | cut -d/ -f1 | head -1)
  fi
  printf '%s' "$ip"
}
