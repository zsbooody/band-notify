# DSH 接入

DSH（DeepSeek Harness）是常驻桌面进程 + Cordis 插件架构，没有 Stop 钩子；
本项目通过宿主插件订阅 `session/event` 事件。

## 安装

DSH 桌面版 profile 被 Electron 独占，`dsh plugin --profile desktop …` 会被拒；
需要手动把插件 link 进 profile：

```bash
P=~/.dsh/profiles/desktop
ln -sfn /path/to/band-notify/dsh-plugin "$P/node_modules/dsh-band-notify"
```

然后编辑 `$P/package.json`：

```json
{
  "dependencies": {
    "dsh-band-notify": "link:/path/to/band-notify/dsh-plugin"
  },
  "dsh": {
    "profile": {
      "bundles": [
        "dsh-band-notify"
      ]
    }
  }
}
```

> 把 `bundles` 里原有的条目保留，只在末尾追加 `dsh-band-notify`。
> 不要对 profile 目录跑 `pnpm install`，会重构 `node_modules`，可能影响正在运行的 DSH。

DSH 的 HMR 会监听 profile 的 `package.json` 与 `cordis.patch.yml`，改完自动重组，
不用重启 GUI（日志里会出现 `disposed` + `loaded`）。

## 配置

插件读取 `~/.config/band-notify/config.json`（`install.sh` 生成，包含随机 topic），
也可以在 profile 的 `cordis.patch.yml` 里覆盖：

```yaml
- id: dsh-band-notify
  name: dsh-band-notify
  config:
    settleMs: 5000
    cooldownMs: 20000
    includeProjectName: true
    notifyOnTurnEnd: true
    notifyOnApproval: true
    notifyOnQuestion: true
    notifyOnError: true
```

环境变量 `BAND_NOTIFY_SERVER` / `BAND_NOTIFY_TOPIC` / `BAND_NOTIFY_IFACE` /
`BAND_NOTIFY_STATE_DIR` / `BAND_NOTIFY_SUBSCRIBE_PAGE` 会覆盖 `config.json`。

完整默认值见 `dsh-plugin/index.js` 的 `DEFAULTS`：

| 键 | 默认 | 说明 |
|---|---|---|
| `server` | 配置值 / `http://127.0.0.1:2586` | ntfy 地址 |
| `topic` | 配置值 | 为空时插件禁用并写日志 |
| `settleMs` | `5000` | turn/end 后等多久确认没有新回合 |
| `cooldownMs` | `20000` | 同一会话两次提醒最小间隔 |
| `watchdogMs` | `30000` | 查手机订阅状态的间隔（0 = 不查） |
| `includeProjectName` | `true` | 通知正文是否带项目目录名 |
| `projects` | `[]` | 只提醒某些项目（按目录名） |
| `dryRun` | `false` | 只写日志不推送 |

## 触发规则

| DSH 事件 | 通知 |
|---|---|
| `turn/end` `completed` / `max-tokens` | 等 `settleMs` → 「dsh 停工等你」 |
| `turn/end` `error` | 等 min(settleMs, 2s) → 「dsh 因错误停止」 |
| `approval/asked` | 立即 → 「dsh 需要你确认」 |
| `tool/call` 且工具名在 `questionTools` | 立即 → 「dsh 在等你回答」 |
| `turn/end` `aborted` / `blocked` / `forked` / `interrupted` | 不提醒 |
| 子会话 `origin: subagent` / `teammate` 或 `delegationDepth > 0` | 不提醒 |

- `turn/start` 会取消还没发出的待发提醒。
- 重放/补发的旧 `turn/end` 会被忽略（按 `turn` 号判断）。
- 发送失败的提醒不会占用 20 秒冷却，下一次审批/提问还能提醒。

## 日志与自检

日志：`~/.local/state/band-notify/dsh-band-notify.log`

```
loaded v0.2.1 server=http://127.0.0.1:2586 topic=set ...
phone online (subscribers=1)
phone offline (subscribers=0) — 这期间的通知只进 ntfy 缓存，手环不会振
sent idle/demo-project http=200 subs=1
send failed idle/demo-project: ...
skip stale turn/end demo-project turn=1 current=2
suppress approval demo-project (cooldown 1234ms)
```

自检：

```bash
touch ~/.local/state/band-notify/dsh-band-notify.selftest
# 再触发插件重载（例如改一下 cordis.patch.yml），会发一条「dsh 手环提醒已接入」
```

- 只改 `dsh-plugin/index.js` 不会触发热重组（HMR 模块监听 `root: []`）；
  要同时改一下 `cordis.patch.yml`（哪怕加一行注释）才会重组。
- 离线逻辑自测：`node dsh-plugin/test/simulate.mjs`（假 ctx + 假 ntfy，不碰真服务）。

## 卸载

从 profile `package.json` 删掉 `dependencies."dsh-band-notify"` 和 `bundles` 里的条目，
再删除 `node_modules/dsh-band-notify` 软链。

## 注意

- 插件 `inject = []`，不依赖宿主服务，纯 `session/event` + `fetch`；加载失败不会拖垮 DSH。
- DSH 桌面版可能把自带的 `PYTHONHOME` / `PYTHONPATH` 泄漏给子进程。
  `band-notify` / `band-notify-hook` 已 unset 这两个变量；DSH 插件本身走 `fetch`，不受影响。
