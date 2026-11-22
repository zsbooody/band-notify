# band-notify

把 AI coding agent「停工等待输入」的信号，变成手环振动提醒。

> Turn your AI coding agents' “waiting for input” events into a wearable vibration,
> via a self-hosted [ntfy](https://ntfy.sh) server on your LAN.

长时间跑任务时，agent 停下来等你确认、等你回答、或者任务结束，你未必在电脑前。
band-notify 把这些事件通过本机 ntfy → 局域网 → 手机通知 → 手环振动串起来，
让你离开工位也不会漏掉。

## 链路

```
AI coding agent (hooks/plugin)
        │  HTTP POST
        ▼
  本机 ntfy 服务 (默认 :2586)
        │  局域网
        ▼
  手机 ntfy App（状态栏通知）
        ▼
  手机健康 App 的通知同步（如华为运动健康）
        ▼
  手环振动
```

手环通常不开放第三方应用或振动 API，所以本项目走「手机系统通知同步」这条通用路线。
代价是只有系统级短振，无法自定义振动节奏。

## 支持的 harness

| Harness | 接入方式 | 文档 |
|---|---|---|
| pi | 扩展 `agent_settled` / `ui_prompt_start` | [docs/harness-pi.md](docs/harness-pi.md) |
| Grok | hooks：`Stop` / `StopFailure` / `Notification` | [docs/harness-grok.md](docs/harness-grok.md) |
| Kimi | `config.toml` 的 `[[hooks]]` | [docs/harness-kimi.md](docs/harness-kimi.md) |
| ZCode | `Stop` 闸门 + 等待器（整件事结束只震一次） | [docs/harness-zcode.md](docs/harness-zcode.md) |
| DSH | 宿主插件订阅 `session/event` | [docs/harness-dsh.md](docs/harness-dsh.md) |

所有 harness 共用同一个 ntfy 服务与 topic；通知标题里带 harness 名，一眼知道是谁在等你。

## 要求

- Linux（systemd 用户服务、`ip`、`ss`；脚本按 Linux 编写）
- [ntfy](https://github.com/binwiederhier/ntfy/releases) 2.x 服务端二进制
- `bash`、`curl`、`python3`
- 可选：`jq`（更快的 JSON 处理）、`qrencode`（订阅二维码）、`ufw`（防火墙）
- 手机安装 ntfy App，并允许通知；如果用手环，需要在手机健康 App 里开启通知同步
- 已在 Huawei Band 10 + Android 上实测；任何能把手机通知同步到手环的设备理论上都可用

## 快速开始

```bash
git clone <repo-url> band-notify
cd band-notify

# 1. 先安装 ntfy 服务端二进制（不随仓库分发）；确保 `ntfy --version` 可用
#    https://github.com/binwiederhier/ntfy/releases

# 2. 安装 band-notify（全部写入用户目录，不需要 sudo）
./install.sh --with-pi
```

`install.sh` 会：

- 复制脚本到 `~/.local/lib/band-notify`
- 在 `~/.local/bin` 建立命令软链
- 生成 `~/.config/band-notify/{config.json,env}`（随机 topic，权限 600）
- 生成 ntfy 配置 `~/.config/band-notify/ntfy-server.yml`
- 安装并启用 systemd 用户服务 `band-notify-ntfy`
- 在 `~/.local/state/band-notify/` 生成订阅页/二维码
- `--with-pi` 时安装/更新 pi 扩展

安装完成后，用手机打开订阅页（或直接扫码）：

```bash
xdg-open ~/.local/state/band-notify/subscribe.html
# 或者重新生成：
band-notify-subscribe
```

### 手机侧

1. 安装 ntfy App（F-Droid / GitHub Releases；自建服务器不需要 FCM/GMS）。
2. 扫码，或手动填 Server `http://<LAN_IP>:<PORT>` 和 Topic。
3. Android 省电策略设为「无限制」、允许自启动/后台运行。
4. 如果用手环：在手机健康 App 里允许通知使用权，勾选 ntfy，提醒模式设为「多设备提醒」。
5. 手环关闭勿扰/睡眠模式，振动强度不要设为「无」，测试时不要放在充电座上。

### 配置第一个 harness

以 Grok 为例，在 `~/.grok/hooks/band-notify.json` 写入：

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "/home/<you>/.local/bin/band-notify-hook grok Stop", "timeout": 5 } ] }
    ],
    "StopFailure": [
      { "hooks": [ { "type": "command", "command": "/home/<you>/.local/bin/band-notify-hook grok StopFailure", "timeout": 5 } ] }
    ],
    "Notification": [
      { "matcher": "permission_prompt", "hooks": [ { "type": "command", "command": "/home/<you>/.local/bin/band-notify-hook grok PermissionRequest", "timeout": 5 } ] }
    ]
  }
}
```

其他 harness 见 [docs/](docs/)。

## 配置

配置优先级：环境变量 > `~/.config/band-notify/config.json` > 默认值。
`install.sh` 同时生成 `config.json`（给 Python/JS/TS 用）和 `env`（给 shell 脚本用）。

`install.sh --config-dir` 指向非默认目录时，必须同时导出
`BAND_NOTIFY_CONFIG_DIR=<同一路径>`，否则已安装的命令和插件找不到配置；
默认目录安装不需要设置。

| 键 | 默认 | 说明 |
|---|---|---|
| `server` | `http://127.0.0.1:2586` | 本机 ntfy 地址；PC 侧一律走回环 |
| `port` | `2586` | ntfy 监听端口 |
| `topic` | 安装时随机生成 | ntfy topic，等同口令；不要提交到 Git |
| `lanInterface` | `wlan0` | 探测局域网 IP 的网卡；`auto` 逻辑会回退到默认路由 |
| `repoDir` | `~/.local/lib/band-notify` | 安装目录；pi 扩展用它自动刷新订阅页 |
| `stateDir` | `~/.local/state/band-notify` | 日志、状态、订阅页 |
| `minRunMs` | `10000` | pi 单轮短于该时长不提醒（0 = 都提醒） |
| `confirmMs` / `retryMs` | `180000` / `15000` | 手机离线时的重试总时长/间隔 |
| `zcodeLogDir` | `~/.zcode/cli/log` | ZCode 运行时日志目录 |
| `zcodeProcess` | `/opt/ZCode/zcode` | 判断 ZCode 是否仍在运行的进程模式 |

完整配置与各 harness 的细节见 `docs/`。修改 `env` 后，重新跑一次相关命令或重启服务即可。

## 日常命令

```bash
band-notify "构建完成" "make -j8 退出码 0" 5   # 手动推送
band-notify-check                            # 全链路自检（会真的震一次）
band-notify-diag                             # 只读排查，不推送
band-notify-subscribe                        # 按当前 IP 重新生成订阅页
band-notify-drill                            # 断网重连演练（会发 3 条）
band-notify-replay <目录> <UTC 时刻>          # ZCode 日志快照复盘，不真震
```

## 卸载

```bash
./uninstall.sh            # 停服务、删软链和安装目录；保留配置/状态
./uninstall.sh --purge    # 同时删除配置、状态、缓存

band-notify-uninstall            # 安装后等价的命令
band-notify-uninstall --purge
```

卸载只删除带 `install.sh` 标记文件的目录；非默认路径或 `--purge` 目录缺少标记时会拒绝。
pi 扩展和 DSH 插件软链不会自动删除，脚本结束时会打印手动步骤。

## 排障

先跑：

```bash
band-notify-diag
```

它按三层定位：

1. **agent 有没有把消息发出来** —— 查服务端缓存里有没有当前项目的消息。
2. **手机 ntfy 有没有连着** —— 查 `subscribers` 数量。
3. **各 harness 的 hook 有没有就位** —— 检查扩展/钩子/插件与日志。

常见问题与详细步骤见 [docs/troubleshooting.md](docs/troubleshooting.md)。

## 安全与隐私

默认配置是**可信局域网**假设：ntfy 匿名读写、HTTP 明文、topic 当口令。
共享网络（公司、宿舍、咖啡厅）请先看 [SECURITY.md](SECURITY.md) 和
[docs/security.md](docs/security.md)，至少做到：

- 不把端口暴露到公网
- 只放行手机 IP / 可信网段
- 需要时开启 ntfy 认证
- 共享网络可用 `BAND_NOTIFY_INCLUDE_PROJECT=0` 隐藏通知里的项目名
  （DSH 也可设 `includeProjectName: false`）
- 不要把 topic、内网 IP、日志贴到公开 issue

## 已知限制

- 手环只有系统级短振，无法自定义振动模式/时长。
- 延迟约 1–3 秒；手机不在线、手环蓝牙断连、充电中、勿扰/睡眠、未佩戴都会漏。
- 手机热点换新会话时，`/24` 网段可能变化；手机里的订阅地址会失效。
  跑 `band-notify-subscribe`，手机重扫一次即可。
- ZCode 闸门依赖 ZCode 运行时日志的内部事件名；ZCode 升级后可能需要调整
  `lib/zcode-notify/logstate.py`。
- 脚本按 Linux 编写；macOS/Windows 可以复用 hooks 思路，但系统服务/防火墙部分需要自行替换。

## 开发与测试

```bash
./scripts/test.sh
```

包含：`bash -n`、可选的 `shellcheck`、`node --check`、Python 语法检查、
`logstate` 单测，以及 dsh 插件的离线自测（只连本地假 ntfy，不碰真服务）。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。第三方组件与商标说明见
[NOTICE](NOTICE) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
