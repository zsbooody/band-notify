# Grok 接入

Grok 的 hooks 在**会话启动时加载**；新写的 hook 文件对已经打开的会话不生效，
需要重开会话或在 `/hooks` 界面重载。

## 配置

`~/.grok/hooks/band-notify.json`：

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

把 `/home/<you>` 换成你的家目录；也可以写成 `$HOME/.local/bin/...` 如果 Grok 的
command 会经过 shell 展开（不同版本可能不同，建议先用绝对路径验证）。

## 事件映射

| Grok 事件 | 通知 |
|---|---|
| `Stop` | 「grok 停工等你」priority 5 |
| `StopFailure` | 「grok 因错误停止」priority 5 |
| `Notification` + `permission_prompt` | 「grok 需要你确认」priority 5 |

## 验证

```bash
grok inspect | grep -A4 Hooks      # 应显示 Hooks (3)
```

界面：`/hooks`（或扩展弹层 → Hooks 标签）→ 重载。

## 排查

- hook 只写 stdout 会污染协议；`band-notify-hook` 永不写 stdout，只写日志：
  `~/.local/state/band-notify/hook/band-notify-hook.log`
- 如果 `~/.grok/pager.toml` 里设了 `disable_plugins = true`，hooks 界面会被隐藏。
- 20 秒去重：同一 harness + 消息 20 秒内只震一次，防止 Stop 与 Notification 双触发。
