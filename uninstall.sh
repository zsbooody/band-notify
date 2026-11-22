#!/usr/bin/env bash
# band-notify 卸载器：停服务、删软链和安装文件；配置/状态默认保留。
#
#   ./uninstall.sh            # 询问后卸载
#   ./uninstall.sh --yes      # 不询问
#   ./uninstall.sh --purge    # 同时删除配置、状态、缓存
#
# 安全：只删除带 install.sh 标记文件的目录；非默认路径或 --purge 目录
# 缺少标记时会拒绝删除。--force 可跳过标记校验，但仍拒绝 /、$HOME 等危险路径。
set -euo pipefail
umask 077

PREFIX="${HOME}/.local/bin"
LIB_ROOT="${HOME}/.local/lib/band-notify"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/band-notify"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/band-notify"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/band-notify"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_NAME="band-notify-ntfy"
UNIT_FILE="$SYSTEMD_DIR/${UNIT_NAME}.service"
PURGE=0
YES=0
FORCE=0

usage() {
  cat <<'EOF'
用法：uninstall.sh [选项]

  --prefix DIR      可执行文件目录（默认 ~/.local/bin）
  --lib-root DIR    安装文件目录（默认 ~/.local/lib/band-notify）
  --config-dir DIR  配置目录（默认 ${XDG_CONFIG_HOME:-~/.config}/band-notify）
  --state-dir DIR   状态目录（默认 ${XDG_STATE_HOME:-~/.local/state}/band-notify）
  --cache-dir DIR   缓存目录（默认 ${XDG_CACHE_HOME:-~/.cache}/band-notify）
  --purge           同时删除配置、状态和缓存
  --yes             不询问，直接执行
  --force           跳过 band-notify 标记校验（仍拒绝危险路径）
  -h, --help        显示帮助
EOF
}

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
warn() { printf '! %s\n' "$*" >&2; }

abs_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$PWD" "$1" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || die "--prefix 需要参数"; PREFIX="$2"; shift 2 ;;
    --lib-root) [ $# -ge 2 ] || die "--lib-root 需要参数"; LIB_ROOT="$2"; shift 2 ;;
    --config-dir) [ $# -ge 2 ] || die "--config-dir 需要参数"; CONFIG_DIR="$2"; shift 2 ;;
    --state-dir) [ $# -ge 2 ] || die "--state-dir 需要参数"; STATE_DIR="$2"; shift 2 ;;
    --cache-dir) [ $# -ge 2 ] || die "--cache-dir 需要参数"; CACHE_DIR="$2"; shift 2 ;;
    --purge) PURGE=1; shift ;;
    --yes) YES=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

PREFIX=$(abs_path "$PREFIX")
LIB_ROOT=$(abs_path "$LIB_ROOT")
CONFIG_DIR=$(abs_path "$CONFIG_DIR")
STATE_DIR=$(abs_path "$STATE_DIR")
CACHE_DIR=$(abs_path "$CACHE_DIR")
SYSTEMD_DIR=$(abs_path "$SYSTEMD_DIR")

assert_safe_path() {
  local path="$1" label="$2"
  case "$path" in
    ""|"/"|"$HOME"|"$HOME/"|"/home"|"/home/"|"/root"|"/root/"|"/usr"|"/usr/"|"/etc"|"/etc/"|"/var"|"/var/")
      die "拒绝删除危险的 $label 路径：$path" ;;
  esac
  local depth
  depth=$(printf '%s' "$path" | tr -cd '/' | wc -c)
  [ "$depth" -ge 2 ] || die "拒绝删除过浅的 $label 路径：$path"
}

require_marker() {
  local dir="$1" marker="$2" label="$3"
  if [ -f "$dir/$marker" ]; then
    return 0
  fi
  if [ "$FORCE" -eq 1 ]; then
    warn "跳过 $label 标记校验：$dir"
    return 0
  fi
  die "$label 缺少 band-notify 标记（$dir/$marker），拒绝删除。确认无误可加 --force"
}

assert_safe_path "$LIB_ROOT" "安装目录"
assert_safe_path "$CONFIG_DIR" "配置目录"
assert_safe_path "$STATE_DIR" "状态目录"
assert_safe_path "$CACHE_DIR" "缓存目录"

cat <<EOF
将执行：
  停止/禁用  systemd 用户服务 $UNIT_NAME
  删除单元   $UNIT_FILE
  删除软链   $PREFIX/band-notify*、zcode-notify-*（仅当指向 $LIB_ROOT）
  删除目录   $LIB_ROOT
$( [ "$PURGE" -eq 1 ] && printf '  删除配置   %s\n  删除状态   %s\n  删除缓存   %s\n' "$CONFIG_DIR" "$STATE_DIR" "$CACHE_DIR" || printf '  保留配置/状态/缓存（加 --purge 才删）\n' )
EOF

if [ "$YES" -ne 1 ]; then
  read -r -p "继续？[y/N] " answer
  case "$answer" in y|Y|yes|YES) ;; *) echo "已取消"; exit 1 ;; esac
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
  rm -f "$UNIT_FILE"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user reset-failed "$UNIT_NAME" 2>/dev/null || true
else
  rm -f "$UNIT_FILE"
fi

for name in band-notify band-notify-hook zcode-notify-gate zcode-settle-wait \
            band-notify-check band-notify-diag band-notify-subscribe band-notify-drill \
            band-notify-replay band-notify-uninstall; do
  path="$PREFIX/$name"
  if [ -L "$path" ]; then
    target=$(readlink -f "$path" 2>/dev/null || true)
    case "$target" in
      "$LIB_ROOT"/*) rm -f "$path" ;;
    esac
  fi
done

if [ -e "$LIB_ROOT" ]; then
  require_marker "$LIB_ROOT" ".band-notify-install" "安装目录"
  rm -rf "$LIB_ROOT"
else
  warn "安装目录不存在：$LIB_ROOT（跳过）"
fi

if [ "$PURGE" -eq 1 ]; then
  for pair in "$CONFIG_DIR:.band-notify-config:配置目录" \
              "$STATE_DIR:.band-notify-state:状态目录" \
              "$CACHE_DIR:.band-notify-cache:缓存目录"; do
    dir=${pair%%:*}
    rest=${pair#*:}
    marker=${rest%%:*}
    label=${rest#*:}
    if [ -e "$dir" ]; then
      require_marker "$dir" "$marker" "$label"
      rm -rf "$dir"
    fi
  done
fi

cat <<EOF
✅ 已卸载 band-notify。
  - pi 扩展（~/.pi/agent/extensions/pi-vibrate.ts）未删除，如不再使用请手动删除。
  - DSH 插件软链（~/.dsh/profiles/desktop/node_modules/dsh-band-notify）未删除；
    如不再使用，请同时从 profile 的 package.json 里移除 dependencies/bundles 条目。
  - 系统/用户安装的 ntfy 二进制未删除。
  - 本仓库目录未删除。
EOF
