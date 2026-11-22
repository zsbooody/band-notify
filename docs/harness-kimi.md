# Kimi 接入

Kimi 使用 `~/.kimi-code/config.toml` 的 `[[hooks]]`。hook 通过 stdin 收 JSON
（snake_case：`hook_event_name`、`session_id`、`cwd`），由 shell 执行。

## 配置

```toml
[[hooks]]
event = "Stop"
command = "/home/<you>/.local/bin/band-notify-hook kimi Stop"
timeout = 5

[[hooks]]
event = "StopFailure"
command = "/home/<you>/.local/bin/band-notify-hook kimi StopFailure"
timeout = 5

[[hooks]]
event = "PermissionRequest"
command = "/home/<you>/.local/bin/band-notify-hook kimi PermissionRequest"
timeout = 5
```

把 `/home/<you>` 换成你的家目录。

## 事件映射

| Kimi 事件 | 通知 |
|---|---|
| `Stop` | 「kimi 停工等你」priority 5 |
| `StopFailure` | 「kimi 因错误停止」priority 5 |
| `PermissionRequest` | 「kimi 需要你确认」priority 5 |

## 注意

- Kimi 的登录流程可能会重写 `config.toml`；如果 `[[hooks]]` 段消失，重新贴回即可。
- 可用事件很多（`PreToolUse`、`PostToolUse`、`Notification` 等），但本项目只建议接
  `Stop` / `StopFailure` / `PermissionRequest`，避免每个工具调用都震。
- 日志：`~/.local/state/band-notify/hook/band-notify-hook.log`
