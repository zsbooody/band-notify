# 排查：手环不震

先跑只读排查：

```bash
band-notify-diag
```

它会分三层告诉你是「agent 没发」「手机没连」还是「hook 没就位」。

## 第 1 层：agent 有没有把消息发出来

```bash
# 看服务端最近 30 分钟有没有本项目的消息
curl -fsS "http://127.0.0.1:2586/<TOPIC>/json?poll=1&since=30m" | grep -F "<项目名>"
```

没有消息，按 harness 检查：

- **pi**：扩展只在启动时加载；当前窗口 `/reload`。单轮短于 `PI_VIBRATE_MIN_MS`
  （默认 10 秒）不提醒；`PI_VIBRATE_DISABLE=1` 会全部关闭。
- **Grok / Kimi**：hooks 只在会话启动时加载；改完重开会话或重载。
- **ZCode**：看 `~/.local/state/band-notify/zcode-gate.log` 有没有 `seen` 行。
  没有 `seen` 说明钩子没跑到；有 `defer` 说明还有在飞工作，等 `zcode-settle.log` 的 `pushed`。
- **DSH**：看 `~/.local/state/band-notify/dsh-band-notify.log` 最近一次是 `loaded` 还是
  `disabled: no topic configured`；插件没挂上时 `band-notify-diag` 第 ③ 步会提示。

## 第 2 层：手机 ntfy 有没有连着

```bash
curl -fsS http://127.0.0.1:2586/metrics | grep ntfy_subscribers_total
```

- `1` 或更大：在线。
- `0`：App 掉线。通知只会进 ntfy 缓存，手环不会振。处理：
  - 打开一次手机 ntfy App，让它重连；
  - Android 省电策略设为「无限制」、允许自启动/后台运行、最近任务里上锁；
  - 检查 App 是否被系统冻结/清理。

如果 `curl` 本身失败：ntfy 服务没起、端口不对，或 `enable-metrics` 关了。

```bash
systemctl --user status band-notify-ntfy
journalctl --user -u band-notify-ntfy -n 50 --no-pager
```

## 第 3 层：订阅地址还对不对

手机热点换新会话时，`/24` 网段可能变化，手机里保存的订阅地址就失效了：

```bash
band-notify-subscribe   # 按当前 IP 重新生成订阅页
```

然后手机打开 `~/.local/state/band-notify/subscribe.html` 重新扫码；
建议先删掉手机里指向旧地址的订阅。

`band-notify-check` 第 3.6 步会直接告诉你订阅页里的 IP 是不是当前 IP。

## 手机收到通知，但手环不震

这是手机/手环设置问题，不是链路问题：

1. 手机健康 App（如华为运动健康）→ 设备 → 消息通知：
   - 总开关打开；
   - 列表里勾选 ntfy（列表里没有就先让 ntfy 产生一条通知再回来看）；
   - 提醒模式设为「多设备提醒」（默认「单设备提醒」时，手机亮屏使用中手环故意不提醒）。
2. 手环：关闭勿扰/睡眠模式；振动强度不是「无」；戴在手上；不要放在充电座上。
3. 手机通知权限：允许通知总开关、ntfy 话题没有被静音、通知类别逐条允许、
   关闭「不重要通知折叠」、勿扰/专注模式关闭。

## 手机也没收到

- 手机浏览器打开 `http://<LAN_IP>:<PORT>` 看是否连得通（同 WiFi、防火墙放行）。
- ntfy App 里 topic 是否正确、是否勾了「Use another server」并填了服务器地址。
- 手机省电策略/后台限制是否杀掉 App。
- 服务器是否在监听：`ss -tln | grep <PORT>`。
- 防火墙是否放行：见 `docs/security.md`。

## ZCode 提醒太多/太少

- 太多：确认 `Stop` 走的是 `zcode-notify-gate`，不是裸 `band-notify-hook`；
  看 `zcode-gate.log` 里是 `push` 还是 `defer`。
- 太少：看 `zcode-settle.log` 是否一直在 `waiting`（有在飞单元未收尾），
  或 `zcode-gate.log` 是否 `skip(session resumed)`。
- 用 `band-notify-replay` 把历史日志截到某一刻，设 `ZCODE_NOTIFY_DRY_RUN=1` 复现判定，
  不会真震。详见 `docs/harness-zcode.md`。

## DSH 插件改了没反应

- 只改 `index.js` 不会触发 HMR；同时改一下 `cordis.patch.yml`（哪怕加注释）。
- 看日志里有没有 `disposed` + `loaded`。
- 插件没挂上：检查 profile 的 `package.json` dependencies/bundles，以及
  `node_modules/dsh-band-notify` 软链。详见 `docs/harness-dsh.md`。

## 日志位置

| 文件 | 内容 |
|---|---|
| `~/.local/state/band-notify/dsh-band-notify.log` | DSH 插件加载/推送/跳过 |
| `~/.local/state/band-notify/zcode-gate.log` | ZCode Stop 闸门判定 |
| `~/.local/state/band-notify/zcode-settle.log` | ZCode 等待器判定 |
| `~/.local/state/band-notify/hook/band-notify-hook.log` | 通用钩子发送失败/跳过 |
| `band-notify-check` | 服务、端口、订阅者、订阅页、发送/回读 |
