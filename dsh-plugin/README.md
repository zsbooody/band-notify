# dsh-band-notify

DSH（DeepSeek Harness）宿主插件：把会话事件推给本机 ntfy，再由手机 ntfy →
手机通知同步 → 手环振动。

和其它 harness 的钩子（`band-notify-hook`、pi 扩展、zcode 闸门）共用同一个
ntfy 服务与 topic，触发源是 DSH 的 `session/event` 事件流。
完整安装说明见 [../docs/harness-dsh.md](../docs/harness-dsh.md)。

## 触发规则

| DSH 事件 | 行为 |
|---|---|
| `turn/end` kind = `completed` / `max-tokens` | 等 `settleMs`（默认 5s）→ 「dsh 停工等你」 |
| `turn/end` kind = `error` | 等 min(settleMs, 2s) → 「dsh 因错误停止」 |
| `approval/asked`（权限审批） | 立即 → 「dsh 需要你确认」 |
| `tool/call` name ∈ `questionTools`（默认 `ask_user_question`） | 立即 → 「dsh 在等你回答」 |
| `turn/end` kind = `aborted` / `blocked` / `forked` / `interrupted` | 不提醒 |
| 子会话（`origin` 为 `subagent` / `teammate`，或 `delegationDepth > 0`） | 不提醒 |

- `turn/start` 会取消还没发出的待发提醒（避免「回合结束了但马上又接着干」的误报）。
- 同一会话 `cooldownMs`（默认 20s）内只发一次；发送失败不占用冷却。
- 重放/补发的旧 `turn/end` 会按 `turn` 号忽略。
- 网络请求 `timeoutMs`（默认 2s）超时，永不抛错、不阻塞 DSH。

## 安装 / 卸载

桌面版 profile 由 Electron 独占（`dsh plugin --profile desktop` 会被拒），只能手改文件：

```bash
P=~/.dsh/profiles/desktop
ln -sfn /path/to/band-notify/dsh-plugin "$P/node_modules/dsh-band-notify"
# 1) $P/package.json 的 dependencies 里加：
#      "dsh-band-notify": "link:/path/to/band-notify/dsh-plugin"
# 2) $P/package.json 的 dsh.profile.bundles 里加 "dsh-band-notify"
# 3) $P/cordis.patch.yml 里加 - id: dsh-band-notify 的 config 段（可选）
```

DSH 的 HMR 会监听 profile 的 `package.json` 与 `cordis.patch.yml`，**改完自动重组，不用重启 GUI**。
卸载反向操作即可。

## 配置

插件读取 `~/.config/band-notify/config.json`（`install.sh` 生成，包含随机 topic），
也可以在 `~/.dsh/profiles/desktop/cordis.patch.yml` 里覆盖：

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

完整默认值见 `index.js` 的 `DEFAULTS`：`server`、`topic`、`lanInterface`、`settleMs`、
`quietMs`、`cooldownMs`、`timeoutMs`、`projects`、`includeProjectName`、`dryRun`、
`stateDir`、`logFile`、`maxLogBytes`、`questionTools`、`skipOrigins`、`selftestMarker`、
`watchdogMs`、`subscribePage`、`notifyOnTurnEnd/Error/Approval/Question`。

`topic` 为空时插件不会注册监听，只在日志里写
`disabled: no topic configured`；先运行 `install.sh` 或在 DSH 配置里显式设置 topic。

## 排查

日志：`~/.local/state/band-notify/dsh-band-notify.log`

```
loaded v0.2.1 server=http://127.0.0.1:2586 topic=set ... watchdogMs=30000
phone online (subscribers=1)          # 手机端 ntfy 在线
phone offline (subscribers=0)         # 手机端掉线：之后的消息只进 ntfy 缓存
network changed: subscribe.html 里的 IP 与本机当前 LAN IP 不一致 — 需要重新运行 band-notify-subscribe 并重新扫码
sent idle/demo-project http=200 subs=1     # 推送成功且手机在线
sent idle/demo-project http=200 subs=0 (手机不在线，只进缓存)
send failed idle/demo-project: ...        # ntfy 没起来 / 地址不对
skip stale turn/end demo-project turn=1 current=2
suppress approval demo-project (cooldown 1234ms)
```

- 手机端掉线是最常见的「没振」原因：ntfy 照样返回 200，但订阅数为 0 时消息只进缓存。
  先看日志最后一条是 `phone online` 还是 `phone offline`；`band-notify-check` 第 3.5 步也会报。
- 换过热点/网段：`band-notify-subscribe` 重新生成二维码，手机重扫。
- 自检：`touch ~/.local/state/band-notify/dsh-band-notify.selftest`，再触发插件重载。
  **只改 `index.js` 不会热重组**（HMR 模块监听 `root: []`），要同时改一下
  `cordis.patch.yml`（哪怕加一行注释）才会 `disposed` + `loaded`。
- 离线逻辑自测（不碰真 ntfy / 真 DSH）：`node test/simulate.mjs`
- 链路排查：`band-notify-diag` 第 ③ 段会打印 DSH 插件是否挂上、最近加载/推送/跳过记录。

## 注意

- 插件 `inject = []`，不依赖任何宿主服务，纯 `session/event` + `fetch`；加载失败不会拖垮 DSH。
- 只订阅根 ctx 的 `session/event`，所有会话事件都会到达；过滤在插件内做。
- `~/.dsh/profiles/desktop/node_modules/dsh-band-notify` 是指向本目录的软链；本目录改了代码，
  HMR 会热替换（日志里会看到 `disposed` + `loaded`）。不要对 profile 目录跑 `pnpm install`
  （会重构 node_modules，可能影响正在运行的 DSH）。
- 许可证：Apache-2.0。
