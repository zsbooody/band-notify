# ZCode 接入

ZCode 的 `Stop` 钩子**不等于**「一切任务结束」。工作流、后台派遣、子会话都可能触发
多次 Stop。直接用裸钩子会连震；本项目用一个「闸门 + 等待器」把提醒收敛成一次。

## 配置

`~/.zcode/cli/config.json`（用户级；工作区级钩子会被标记为待审核）：

```json
{
  "hooks": {
    "enabled": true,
    "events": {
      "Stop": [
        { "hooks": [ { "type": "command", "command": "/home/<you>/.local/bin/zcode-notify-gate", "timeout": 30, "async": true } ] }
      ],
      "PermissionRequest": [
        { "hooks": [ { "type": "command", "command": "/home/<you>/.local/bin/band-notify-hook zcode PermissionRequest", "timeout": 5 } ] }
      ]
    }
  }
}
```

- `hooks.enabled` 必须为 `true`，否则整段不生效。
- `async: true`：闸门在后台跑，不阻塞 agent。
- `PermissionRequest` 不走闸门：要你点确认时必须立刻震。
- 改完配置建议重启一次 ZCode，避免运行中的 App 用旧配置覆盖文件。

## 判定逻辑

闸门每次 Stop 扫 ZCode 运行时日志，统计「在飞单元」：

| 单元 | 开始 → 结束 |
|---|---|
| turn | `turn.started` → `turn.completed` / `turn.failed` |
| 后台任务 | `background_task.tracking.started` → `.terminal*` |
| 工具调用 | `tool.call.started` → `.completed` / `.failed` |

- 有在飞单元 → 挂 `zcode-settle-wait`，本次不推。
- 没有在飞 → 等 `firstDelay`（默认 5s）复核；期间出现新工作就交给等待器，否则推一条。
- 等待器：**无在飞单元** 且最近 `quietSeconds`（默认 15s）没有工作类事件 → 推一条。
- 日志要整份增量读，不能只 tail：长任务的 `started` 事件会被 tail 窗口挤掉。
- 收尾事件不能当成「续跑」：`logstate.is_resume_event()` 只认起头事件；
  `background_task.tracking.terminal.*`、`subagent.completed` 等一律不算。

## 配置项

配置来自 `~/.config/band-notify/config.json`，环境变量可覆盖：

| 变量 | 默认 | 说明 |
|---|---|---|
| `ZCODE_NOTIFY_LOG_DIR` | 配置 `zcodeLogDir` | 日志目录（自测可换） |
| `ZCODE_NOTIFY_FIRST_DELAY` | `5` | Stop 后快路径复核秒数 |
| `ZCODE_NOTIFY_QUIET_SECONDS` | `15` | 安静判定窗口 |
| `ZCODE_NOTIFY_MAX_WAIT` | `5400` | 等待器最长等待（1.5h） |
| `ZCODE_NOTIFY_COOLDOWN` | `60` | 两条提醒最小间隔 |
| `ZCODE_NOTIFY_DRY_RUN=1` | — | 只记日志不推送 |
| `ZCODE_NOTIFY_GATE_DISABLE=1` | — | 停用闸门（退回裸钩子） |

日志：

- `~/.local/state/band-notify/zcode-gate.log`：`seen` / `push` / `defer` / `skip`
- `~/.local/state/band-notify/zcode-settle.log`：`waiting` / `settled` / `pushed` / `exit`

## 自测

不会真震：

```bash
# 1) 空日志目录 = 无在飞工作，应记 settled + push(skipped: dry-run)
echo '{}' | \
  BAND_NOTIFY_CONFIG_DIR=/tmp/replay-config BAND_NOTIFY_STATE_DIR=/tmp/replay-state \
  ZCODE_NOTIFY_LOG_DIR=/tmp/empty ZCODE_NOTIFY_DRY_RUN=1 \
  ZCODE_NOTIFY_MAX_WAIT=8 zcode-settle-wait

# 2) 复现“当时”的状态：把日志截到某一刻
band-notify-replay /tmp/zc-replay 2026-01-01T10:20:30Z
echo '{"session_id":"sess_demo"}' | \
  BAND_NOTIFY_CONFIG_DIR=/tmp/replay-config BAND_NOTIFY_STATE_DIR=/tmp/replay-state \
  ZCODE_NOTIFY_LOG_DIR=/tmp/zc-replay \
  ZCODE_NOTIFY_DRY_RUN=1 ZCODE_NOTIFY_MAX_WAIT=8 \
  ZCODE_NOTIFY_TURN_STALE=86400 ZCODE_NOTIFY_TOOL_STALE=86400 \
  zcode-settle-wait
```

用 `BAND_NOTIFY_CONFIG_DIR`/`BAND_NOTIFY_STATE_DIR` 指向临时目录，避免读到真实
配置或写真实状态目录；`ZCODE_NOTIFY_DRY_RUN=1` 时等待器不要求 ZCode 正在运行。

- 无头 CLI 不能做端到端验证：`async: true` 的钩子会在 CLI 收尾时被连带杀掉。
  端到端要在 GUI 里真跑一次；确认钩子跑没跑看 `zcode-gate.log` 的 `seen` 行。
- ZCode 升级后内部事件名可能变化；如判定异常，先看 `lib/zcode-notify/logstate.py`
  的 `_feed()` 与 `units()`，再对照 ZCode 日志。
