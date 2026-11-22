#!/usr/bin/env bash
# band-notify 安装器：复制脚本、生成配置、装 systemd 用户服务、生成订阅页。
#
# 常用：
#   ./install.sh                 # 默认安装到 ~/.local，自动生成随机 topic
#   ./install.sh --with-pi       # 同时安装 pi 扩展
#   ./install.sh --dry-run       # 只打印计划，不写文件
#   ./install.sh --force         # 重新生成 topic/配置/单元（会先备份）
#
# 全部写入用户目录，不需要 sudo。防火墙规则只打印，不自动修改。
# 重复运行默认保留已有 config.json / env / ntfy-server.yml / systemd 单元，
# 避免把用户已开启的 ntfy 认证或自定义配置静默覆盖。
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/band-notify"
PREFIX="${HOME}/.local/bin"
LIB_ROOT="${HOME}/.local/lib/band-notify"
CONFIG_DIR="$DEFAULT_CONFIG_DIR"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/band-notify"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/band-notify"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
PORT=""
IFACE=""
TOPIC=""
EXPLICIT_TOPIC=0
PORT_EXPLICIT=0
IFACE_EXPLICIT=0
STATE_DIR_EXPLICIT=0
CACHE_DIR_EXPLICIT=0
WITH_SYSTEMD=1
WITH_PI=0
DRY_RUN=0
FORCE=0

usage() {
  cat <<'EOF'
用法：install.sh [选项]

  --prefix DIR        可执行文件目录（默认 ~/.local/bin）
  --lib-root DIR      安装文件目录（默认 ~/.local/lib/band-notify）
  --config-dir DIR    配置目录（默认 ${XDG_CONFIG_HOME:-~/.config}/band-notify）
                      非默认目录必须同时导出 BAND_NOTIFY_CONFIG_DIR=<同一路径>，
                      否则已安装的命令和插件找不到配置。
  --state-dir DIR     状态/日志/订阅页目录（默认 ${XDG_STATE_HOME:-~/.local/state}/band-notify）
  --cache-dir DIR     ntfy 缓存目录（默认 ${XDG_CACHE_HOME:-~/.cache}/band-notify）
  --port NUM          ntfy 端口（默认 2586；已有配置时沿用已有值）
  --iface NAME        局域网网卡（默认自动探测，回退 wlan0）
  --topic STR         ntfy topic（默认自动生成；已有配置时需配合 --force）
  --with-pi           同时安装/更新 pi 扩展（~/.pi/agent/extensions/pi-vibrate.ts）
  --no-systemd        不安装 systemd 用户服务
  --force             重新生成 topic/配置/单元（会先备份）
  --dry-run           只打印计划，不写文件
  -h, --help          显示本帮助
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
    --state-dir) [ $# -ge 2 ] || die "--state-dir 需要参数"; STATE_DIR="$2"; STATE_DIR_EXPLICIT=1; shift 2 ;;
    --cache-dir) [ $# -ge 2 ] || die "--cache-dir 需要参数"; CACHE_DIR="$2"; CACHE_DIR_EXPLICIT=1; shift 2 ;;
    --port) [ $# -ge 2 ] || die "--port 需要参数"; PORT="$2"; PORT_EXPLICIT=1; shift 2 ;;
    --iface) [ $# -ge 2 ] || die "--iface 需要参数"; IFACE="$2"; IFACE_EXPLICIT=1; shift 2 ;;
    --topic) [ $# -ge 2 ] || die "--topic 需要参数"; TOPIC="$2"; EXPLICIT_TOPIC=1; shift 2 ;;
    --with-pi) WITH_PI=1; shift ;;
    --no-systemd) WITH_SYSTEMD=0; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
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

if [ -n "${BAND_NOTIFY_CONFIG_DIR:-}" ] && [ "$BAND_NOTIFY_CONFIG_DIR" != "$CONFIG_DIR" ]; then
  die "BAND_NOTIFY_CONFIG_DIR=$BAND_NOTIFY_CONFIG_DIR 与本次 --config-dir $CONFIG_DIR 不一致"
fi
if [ "$CONFIG_DIR" != "$DEFAULT_CONFIG_DIR" ] && [ "${BAND_NOTIFY_CONFIG_DIR:-}" != "$CONFIG_DIR" ]; then
  die "自定义 --config-dir 需要同时导出 BAND_NOTIFY_CONFIG_DIR=$CONFIG_DIR（pi/DSH 插件和命令都依赖它）"
fi
if [ "$EXPLICIT_TOPIC" -eq 1 ] && [ -e "$CONFIG_DIR/config.json" ] && [ "$FORCE" -ne 1 ]; then
  die "已有配置；要改 topic 请加 --force（会备份旧配置并轮换 topic）"
fi

read_existing_config() {
  if [ "$FORCE" -eq 0 ] && [ -f "$CONFIG_DIR/config.json" ]; then
    python3 - "$CONFIG_DIR/config.json" <<'PY'
import json, sys
try:
    cfg = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    cfg = {}
print(cfg.get("topic", ""))
print(cfg.get("port", ""))
print(cfg.get("stateDir", ""))
print(cfg.get("lanInterface", ""))
print(cfg.get("repoDir", ""))
PY
  fi
}

if [ "$FORCE" -eq 0 ] && [ -f "$CONFIG_DIR/config.json" ]; then
  EXISTING=$(read_existing_config)
  EX_TOPIC=$(printf '%s\n' "$EXISTING" | sed -n '1p')
  EX_PORT=$(printf '%s\n' "$EXISTING" | sed -n '2p')
  EX_STATE=$(printf '%s\n' "$EXISTING" | sed -n '3p')
  EX_IFACE=$(printf '%s\n' "$EXISTING" | sed -n '4p')
  EX_REPO=$(printf '%s\n' "$EXISTING" | sed -n '5p')
  [ -z "$TOPIC" ] && [ -n "$EX_TOPIC" ] && TOPIC="$EX_TOPIC"
  if [ "$PORT_EXPLICIT" -eq 1 ] && [ -n "$EX_PORT" ] && [ "$PORT" != "$EX_PORT" ]; then
    warn "已有配置，沿用端口 $EX_PORT（要改端口请加 --force）"; PORT="$EX_PORT"
  elif [ "$PORT_EXPLICIT" -eq 0 ] && [ -n "$EX_PORT" ]; then
    PORT="$EX_PORT"
  fi
  if [ "$STATE_DIR_EXPLICIT" -eq 1 ] && [ -n "$EX_STATE" ] && [ "$STATE_DIR" != "$EX_STATE" ]; then
    warn "已有配置，沿用状态目录 $EX_STATE（要改请加 --force）"; STATE_DIR="$EX_STATE"
  elif [ "$STATE_DIR_EXPLICIT" -eq 0 ] && [ -n "$EX_STATE" ]; then
    STATE_DIR="$EX_STATE"
  fi
  if [ "$IFACE_EXPLICIT" -eq 1 ] && [ -n "$EX_IFACE" ] && [ "$IFACE" != "$EX_IFACE" ]; then
    warn "已有配置，沿用网卡 $EX_IFACE（要改请加 --force）"; IFACE="$EX_IFACE"
  elif [ "$IFACE_EXPLICIT" -eq 0 ] && [ -z "$IFACE" ] && [ -n "$EX_IFACE" ]; then
    IFACE="$EX_IFACE"
  fi
  if [ -n "$EX_REPO" ] && [ "$LIB_ROOT" != "$EX_REPO" ]; then
    warn "已有配置，沿用安装目录 $EX_REPO（要改请加 --force）"; LIB_ROOT="$EX_REPO"
  fi
fi
if [ -z "$TOPIC" ] && [ "$FORCE" -eq 0 ] && [ -f "$CONFIG_DIR/env" ]; then
  TOPIC=$(bash -c 'set -a; . "$1" >/dev/null 2>&1; printf "%s" "${BAND_NOTIFY_TOPIC:-}"' _ "$CONFIG_DIR/env" || true)
fi
if [ "$FORCE" -eq 0 ] && [ -f "$CONFIG_DIR/ntfy-server.yml" ]; then
  EX_CACHE=$(sed -n 's/^cache-file:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' \
    "$CONFIG_DIR/ntfy-server.yml" | head -1)
  if [ -n "$EX_CACHE" ]; then
    EX_CACHE_DIR=$(dirname "$EX_CACHE")
    if [ "$CACHE_DIR_EXPLICIT" -eq 1 ] && [ "$CACHE_DIR" != "$EX_CACHE_DIR" ]; then
      warn "已有 ntfy 配置，沿用缓存目录 $EX_CACHE_DIR（要改请加 --force）"
    fi
    CACHE_DIR="$EX_CACHE_DIR"
  fi
fi

# 已有配置里的路径可能是旧的相对值；统一成绝对路径再使用。
LIB_ROOT=$(abs_path "$LIB_ROOT")
STATE_DIR=$(abs_path "$STATE_DIR")
CACHE_DIR=$(abs_path "$CACHE_DIR")

[ -n "$PORT" ] || PORT=2586
case "$PORT" in
  ''|*[!0-9]*) die "端口必须是数字：$PORT" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "端口超出范围：$PORT"

if [ -z "$TOPIC" ]; then
  if command -v openssl >/dev/null 2>&1; then
    TOPIC=$(openssl rand -hex 16)
  elif command -v python3 >/dev/null 2>&1; then
    TOPIC=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
  else
    die "需要 openssl 或 python3 之一来生成 topic"
  fi
fi
case "$TOPIC" in
  *[!A-Za-z0-9_-]*) die "topic 只能包含字母、数字、下划线和连字符：$TOPIC" ;;
esac

if [ -z "$IFACE" ]; then
  IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
  [ -n "$IFACE" ] || IFACE=wlan0
fi

command -v python3 >/dev/null 2>&1 || die "需要 python3（写 JSON 配置、解析 hook），请先安装"
command -v curl >/dev/null 2>&1 || die "需要 curl，请先安装"

NTFY_BIN=$(command -v ntfy 2>/dev/null || true)
if [ -z "$NTFY_BIN" ] && [ -x "$HOME/.local/bin/ntfy" ]; then
  NTFY_BIN="$HOME/.local/bin/ntfy"
fi
if [ -z "$NTFY_BIN" ]; then
  cat >&2 <<'EOF'
✗ 未找到 ntfy 可执行文件。
  请先安装 ntfy（官方 Release 或发行版包），再重新运行 install.sh：
    https://github.com/binwiederhier/ntfy/releases
  例如把二进制放到 ~/.local/bin/ntfy 并 chmod +x。
EOF
  exit 1
fi

CACHE_FILE="$CACHE_DIR/ntfy-cache.db"
AUTH_FILE="$CONFIG_DIR/auth.yml"
UNIT_NAME="band-notify-ntfy"
UNIT_FILE="$SYSTEMD_DIR/${UNIT_NAME}.service"

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF
dry-run：
  可执行文件      $PREFIX
  安装目录        $LIB_ROOT
  配置目录        $CONFIG_DIR
  状态目录        $STATE_DIR
  缓存目录        $CACHE_DIR
  systemd 目录    $SYSTEMD_DIR
  ntfy 二进制     $NTFY_BIN
  ntfy 端口       $PORT
  网卡            $IFACE
  topic           $TOPIC
  systemd         $([ "$WITH_SYSTEMD" -eq 1 ] && echo "安装 $UNIT_FILE" || echo "跳过")
  pi 扩展         $([ "$WITH_PI" -eq 1 ] && echo "安装到 ~/.pi/agent/extensions/" || echo "跳过")
  订阅页          $STATE_DIR/subscribe.html
EOF
  exit 0
fi

say() { printf '  %s\n' "$*"; }
backup() {
  local path="$1"
  [ -e "$path" ] || return 0
  local dest="${path}.bak.$(date +%s)"
  cp -a "$path" "$dest"
  say "备份：$dest"
}

echo "== 1. 复制文件 =="
mkdir -p "$PREFIX" "$LIB_ROOT" "$CONFIG_DIR" "$STATE_DIR" "$STATE_DIR/logs" "$CACHE_DIR"
chmod 700 "$CONFIG_DIR" "$STATE_DIR" "$CACHE_DIR" 2>/dev/null || true
printf 'band-notify\n' >"$LIB_ROOT/.band-notify-install"
printf 'band-notify\n' >"$CONFIG_DIR/.band-notify-config"
printf 'band-notify\n' >"$STATE_DIR/.band-notify-state"
printf 'band-notify\n' >"$CACHE_DIR/.band-notify-cache"
for item in bin lib scripts extensions config systemd dsh-plugin; do
  mkdir -p "$LIB_ROOT/$item"
  cp -a "$SCRIPT_DIR/$item/." "$LIB_ROOT/$item/"
  say "$item/"
done
cp -a "$SCRIPT_DIR/uninstall.sh" "$LIB_ROOT/uninstall.sh"
chmod +x "$LIB_ROOT"/bin/* "$LIB_ROOT"/scripts/*.sh "$LIB_ROOT/uninstall.sh" 2>/dev/null || true

echo "== 2. 命令软链 =="
link_cmd() {
  local target="$1" name="$2"
  if [ -e "$PREFIX/$name" ] && [ ! -L "$PREFIX/$name" ]; then
    backup "$PREFIX/$name"
  fi
  ln -sfn "$LIB_ROOT/$target" "$PREFIX/$name"
  say "$PREFIX/$name -> $LIB_ROOT/$target"
}
link_cmd bin/band-notify band-notify
link_cmd bin/band-notify-hook band-notify-hook
link_cmd bin/zcode-notify-gate zcode-notify-gate
link_cmd bin/zcode-settle-wait zcode-settle-wait
link_cmd scripts/check.sh band-notify-check
link_cmd scripts/diag.sh band-notify-diag
link_cmd scripts/make-subscribe.sh band-notify-subscribe
link_cmd scripts/drill.sh band-notify-drill
link_cmd scripts/replay.sh band-notify-replay
link_cmd uninstall.sh band-notify-uninstall

echo "== 3. 写配置 =="
if [ -e "$CONFIG_DIR/config.json" ] && [ "$FORCE" -eq 0 ]; then
  say "保留已有配置：$CONFIG_DIR/config.json（用 --force 重新生成）"
else
  [ -e "$CONFIG_DIR/config.json" ] && backup "$CONFIG_DIR/config.json"
  python3 - "$CONFIG_DIR/config.json" "$TOPIC" "$PORT" "$IFACE" "$STATE_DIR" "$LIB_ROOT" "$STATE_DIR/subscribe.html" <<'PY'
import json
import os
import pathlib
import sys

path, topic, port, iface, state, repo, subscribe = sys.argv[1:8]
cfg = {
    "server": f"http://127.0.0.1:{port}",
    "port": int(port),
    "topic": topic,
    "lanInterface": iface,
    "repoDir": repo,
    "stateDir": state,
    "zcodeLogDir": str(pathlib.Path.home() / ".zcode/cli/log"),
    "zcodeProcess": "/opt/ZCode/zcode",
    "minRunMs": 10000,
    "confirmMs": 180000,
    "retryMs": 15000,
    "firstDelay": 5,
    "quietSeconds": 15,
    "maxWait": 5400,
    "cooldownSeconds": 60,
    "subscribePage": subscribe,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
PY
  say "配置：$CONFIG_DIR/config.json（权限 600）"
fi

if [ -e "$CONFIG_DIR/env" ] && [ "$FORCE" -eq 0 ]; then
  say "保留已有环境变量：$CONFIG_DIR/env（用 --force 重新生成）"
else
  [ -e "$CONFIG_DIR/env" ] && backup "$CONFIG_DIR/env"
  {
    printf 'BAND_NOTIFY_CONFIG_DIR=%q\n' "$CONFIG_DIR"
    printf 'BAND_NOTIFY_SERVER=%q\n' "http://127.0.0.1:$PORT"
    printf 'BAND_NOTIFY_PORT=%q\n' "$PORT"
    printf 'BAND_NOTIFY_TOPIC=%q\n' "$TOPIC"
    printf 'BAND_NOTIFY_IFACE=%q\n' "$IFACE"
    printf 'BAND_NOTIFY_STATE_DIR=%q\n' "$STATE_DIR"
    printf 'BAND_NOTIFY_SUBSCRIBE_DIR=%q\n' "$STATE_DIR"
    printf 'BAND_NOTIFY_REPO_DIR=%q\n' "$LIB_ROOT"
    printf 'BAND_NOTIFY_REPO=%q\n' "$LIB_ROOT"
    printf 'BAND_NOTIFY_ZCODE_LOG_DIR=%q\n' "$HOME/.zcode/cli/log"
    printf 'BAND_NOTIFY_ZCODE_PROCESS=%q\n' "/opt/ZCode/zcode"
    if [ "$WITH_SYSTEMD" -eq 1 ]; then
      printf 'BAND_NOTIFY_SYSTEMD_UNIT=%q\n' "$UNIT_NAME"
    fi
  } >"$CONFIG_DIR/env"
  chmod 600 "$CONFIG_DIR/env"
  say "环境变量：$CONFIG_DIR/env（权限 600）"
fi

if [ -e "$CONFIG_DIR/ntfy-server.yml" ] && [ "$FORCE" -eq 0 ]; then
  say "保留已有 ntfy 配置：$CONFIG_DIR/ntfy-server.yml（用 --force 重新生成；不会动你的 auth 设置）"
else
  [ -e "$CONFIG_DIR/ntfy-server.yml" ] && backup "$CONFIG_DIR/ntfy-server.yml"
  python3 - "$LIB_ROOT/config/ntfy-server.yml.in" "$CONFIG_DIR/ntfy-server.yml" "$PORT" "$CACHE_FILE" "$AUTH_FILE" <<'PY'
import os
import sys

src, dst, port, cache, auth = sys.argv[1:6]
text = open(src, encoding="utf-8").read()
text = text.replace("__PORT__", str(port)).replace("__CACHE_FILE__", cache).replace("__AUTH_FILE__", auth)
with open(dst, "w", encoding="utf-8") as f:
    f.write(text)
os.chmod(dst, 0o600)
PY
  say "ntfy 配置：$CONFIG_DIR/ntfy-server.yml（权限 600）"
fi

echo "== 4. systemd 用户服务 =="
if [ "$WITH_SYSTEMD" -eq 1 ]; then
  if command -v systemctl >/dev/null 2>&1; then
    mkdir -p "$SYSTEMD_DIR"
    if [ -e "$UNIT_FILE" ] && [ "$FORCE" -eq 0 ]; then
      say "保留已有单元：$UNIT_FILE（用 --force 重新生成）"
    else
      [ -e "$UNIT_FILE" ] && backup "$UNIT_FILE"
      python3 - "$LIB_ROOT/systemd/band-notify-ntfy.service" "$UNIT_FILE" "$NTFY_BIN" "$CONFIG_DIR" <<'PY'
import sys

src, dst, ntfy, config_dir = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
text = text.replace("%h/.local/bin/ntfy", ntfy).replace("%h/.config/band-notify", config_dir)
with open(dst, "w", encoding="utf-8") as f:
    f.write(text)
PY
      say "单元：$UNIT_FILE"
    fi
    systemctl --user daemon-reload 2>/dev/null || true
    if systemctl --user is-active --quiet "$UNIT_NAME" 2>/dev/null; then
      if [ "$FORCE" -eq 1 ]; then
        systemctl --user restart "$UNIT_NAME" 2>/dev/null || say "⚠️ 重启服务失败：journalctl --user -u $UNIT_NAME -n 50 --no-pager"
        say "服务已重启：systemctl --user status $UNIT_NAME"
      else
        say "服务已在运行；配置未变，不重启（改端口/配置请用 --force）"
      fi
    elif ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}$"; then
      say "⚠️ 端口 $PORT 已被占用（可能已有 ntfy 服务）。"
      say "   已安装单元但跳过自动启动；请停掉旧服务，或用 --port 换端口后重装。"
    elif systemctl --user enable --now "$UNIT_NAME"; then
      say "服务已启用：systemctl --user status $UNIT_NAME"
    else
      say "⚠️ systemd 用户服务不可用或启动失败：journalctl --user -u $UNIT_NAME -n 50 --no-pager"
    fi
  else
    say "! 未找到 systemctl，跳过 systemd 安装"
  fi
else
  say "跳过（--no-systemd）"
fi

echo "== 5. 生成订阅页 =="
SUBSCRIBE_OK=1
if [ -f "$CONFIG_DIR/env" ]; then
  if ! BAND_NOTIFY_CONFIG_DIR="$CONFIG_DIR" BAND_NOTIFY_ENV_FILE="$CONFIG_DIR/env" \
       "$LIB_ROOT/scripts/make-subscribe.sh"; then
    SUBSCRIBE_OK=0
  fi
else
  if ! BAND_NOTIFY_CONFIG_DIR="$CONFIG_DIR" BAND_NOTIFY_TOPIC="$TOPIC" \
       BAND_NOTIFY_SERVER="http://127.0.0.1:$PORT" BAND_NOTIFY_PORT="$PORT" \
       BAND_NOTIFY_IFACE="$IFACE" BAND_NOTIFY_STATE_DIR="$STATE_DIR" \
       BAND_NOTIFY_SUBSCRIBE_DIR="$STATE_DIR" "$LIB_ROOT/scripts/make-subscribe.sh"; then
    SUBSCRIBE_OK=0
  fi
fi
if [ "$SUBSCRIBE_OK" -eq 1 ]; then
  say "订阅页：$STATE_DIR/subscribe.html"
else
  say "⚠️ 订阅页生成失败（见上面的错误；不影响服务）。修复后运行 band-notify-subscribe。"
fi

echo "== 6. pi 扩展（可选） =="
if [ "$WITH_PI" -eq 1 ]; then
  PI_DIR="$HOME/.pi/agent/extensions"
  if [ -d "$HOME/.pi/agent" ]; then
    mkdir -p "$PI_DIR"
    [ -e "$PI_DIR/pi-vibrate.ts" ] && backup "$PI_DIR/pi-vibrate.ts"
    install -m 600 "$LIB_ROOT/extensions/pi-vibrate.ts" "$PI_DIR/pi-vibrate.ts"
    say "已安装：$PI_DIR/pi-vibrate.ts（在 pi 里 /reload 或重启生效）"
  else
    say "! 未找到 ~/.pi/agent，跳过 pi 扩展"
  fi
else
  say "跳过（用 --with-pi 安装）"
fi

cat <<EOF

✅ 安装完成
  topic          $TOPIC
  配置目录       $CONFIG_DIR
  状态目录       $STATE_DIR
  缓存目录       $CACHE_DIR
  订阅页         $STATE_DIR/subscribe.html
  自检           $PREFIX/band-notify-check
  一键排查       $PREFIX/band-notify-diag
  卸载           $PREFIX/band-notify-uninstall

下一步：
  1. 手机打开 $STATE_DIR/subscribe.html 扫码订阅（或按页面手动填 Server/Topic）
  2. 防火墙只对可信局域网放行 tcp/$PORT，例如：
       sudo ufw allow from 192.168.0.0/16 to any port $PORT proto tcp
  3. 按 docs/harness-*.md 配置各 harness 的 hooks
  4. 自检：$PREFIX/band-notify-check
EOF

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *)
    printf '\n提示：%s 不在 PATH。把下面这行加到 shell profile：\n  export PATH="%s:$PATH"\n' \
      "$PREFIX" "$PREFIX"
    ;;
esac
