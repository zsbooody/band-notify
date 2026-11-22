# pi 接入

## 安装

```bash
./install.sh --with-pi
```

或手动复制：

```bash
mkdir -p ~/.pi/agent/extensions
cp extensions/pi-vibrate.ts ~/.pi/agent/extensions/
```

扩展只在 **pi 启动时加载**。已经打开的窗口需要 `/reload` 或重启 pi。

## 行为

| pi 事件 | 通知 |
|---|---|
| `agent_settled`（agent 不会再自动继续） | 「pi 停工等你」priority 5 |
| `ui_prompt_start`（弹窗等你选择/确认） | 「pi 需要你操作」priority 4 |
| 单轮运行时长 < `PI_VIBRATE_MIN_MS`（默认 10s） | 不提醒（短问答不打扰） |
| `PI_VIBRATE_DISABLE=1` | 全部关闭 |

- `agent_settled` 时如果别的扩展又起了新 run（`ctx.isIdle()` 为 false），不提醒。
- 手机不在线时按 `retryMs`（默认 15s）重发，最长 `confirmMs`（默认 3 分钟）；
  新一回合开始会取消上一轮的重试链。
- 会话启动/每轮开始时做一次链路体检：手机没连上会在 pi 界面提示，并尝试运行
  `scripts/make-subscribe.sh` 刷新订阅页。

## 配置

扩展读取 `~/.config/band-notify/config.json`，并支持环境变量覆盖：

| 变量 | 默认 | 说明 |
|---|---|---|
| `BAND_NOTIFY_SERVER` / `PI_VIBRATE_SERVER` | 配置值 / `http://127.0.0.1:2586` | ntfy 地址 |
| `BAND_NOTIFY_TOPIC` / `PI_VIBRATE_TOPIC` | 配置值 | topic（必填） |
| `PI_VIBRATE_MIN_MS` | `10000` | 短任务门槛 |
| `PI_VIBRATE_CONFIRM_MS` | `180000` | 离线重试总时长 |
| `PI_VIBRATE_RETRY_MS` | `15000` | 重试间隔 |
| `BAND_NOTIFY_REPO` / `PI_VIBRATE_REPO` | 配置 `repoDir` | 仓库路径，用于自动刷新订阅页 |
| `PI_VIBRATE_DISABLE` | — | 设 `1` 临时关闭 |

## 排查

```bash
band-notify-diag
```

如果第 ① 步显示 0 条：

- 当前 pi 窗口是否 `/reload` 过？
- 扩展文件是否存在：`ls ~/.pi/agent/extensions/pi-vibrate.ts`
- 本轮运行是否短于 `PI_VIBRATE_MIN_MS`？
- 是否设了 `PI_VIBRATE_DISABLE=1`？
- 手机是否在线（`band-notify-check` 第 3.5 步）。
