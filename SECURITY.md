# 安全说明

## 威胁模型

band-notify 的默认部署是：本机 ntfy 服务监听局域网，手机 App 通过 HTTP 订阅。
这带来几个必须知道的边界：

- **topic 就是口令**：知道 topic 且能访问服务端口的人，可以订阅（读通知）或发布（伪造通知）。
- **默认匿名读写**：`config/ntfy-server.yml.in` 默认没有认证；适合可信的家庭/个人热点局域网。
- **HTTP 明文**：同一局域网内的设备可以嗅探通知内容。
- **通知正文默认带项目目录名**：可能泄露客户名、项目名或仓库名。
- **日志**：DSH 插件会写 `dsh-band-notify.log`，其中可能包含项目名和推送结果；不要把未脱敏日志贴到公开 issue。

## 默认已经做的

- `install.sh` 自动生成 32 位十六进制随机 topic，不写死任何默认口令。
- `install.sh` 生成的 `config.json`、`env`、`ntfy-server.yml` 权限为 `600`；
  配置/状态/缓存目录为 `700`；systemd 单元设置 `UMask=0077`。
- 插件日志不再打印 topic 明文，只打印 `topic=set/missing`；网段变化也不打印具体 IP。
- 仓库不提交 `config.json`、`env`、`subscribe.html`、二维码或本机日志。
- 示例配置监听所有接口（`:端口` 等价于 `0.0.0.0`），且不会自动修改防火墙；
  必须自行用防火墙或网络隔离限制访问。

## 加固清单

1. **不要把端口暴露到公网**。只允许可信局域网访问；不要把 2586 端口映射到路由器外网。
2. **只放行手机 IP / 可信网段**：
   ```bash
   # 例：只允许 192.168.1.23 访问
   sudo ufw allow from 192.168.1.23 to any port 2586 proto tcp
   ```
3. **开启 ntfy 认证**（共享局域网强烈建议）。ntfy 2.x 的 `user add` 不接受
   `--config`，要用 `NTFY_CONFIG_FILE` 环境变量；顺序如下：
   ```bash
   # 1) 在 ~/.config/band-notify/ntfy-server.yml 取消注释（用文件里已生成的绝对路径）：
   #      auth-file: "/home/<you>/.config/band-notify/auth.yml"
   #      auth-default-access: "deny-all"
   # 2) 先启动一次服务，生成 auth.yml
   systemctl --user restart band-notify-ntfy

   # 3) 创建用户（密码用 NTFY_PASSWORD 传入）
   NTFY_CONFIG_FILE="$HOME/.config/band-notify/ntfy-server.yml" \
     NTFY_PASSWORD='<password>' ntfy user add your-user

   # 4) 只给这个 topic 读写权限
   NTFY_CONFIG_FILE="$HOME/.config/band-notify/ntfy-server.yml" \
     ntfy access your-user '<topic>' read-write

   # 5) 重启生效
   systemctl --user restart band-notify-ntfy
   ```
   `deny-all` 会锁死匿名访问；在手机端填好用户名/密码之前，手环不会收到通知。
   手机端订阅时填写用户名/密码（ntfy App 支持）。
4. **跨不可信网络时用 HTTPS**：在 ntfy 前放 Caddy/Nginx 反向代理，或使用可信隧道；
   不要把明文 HTTP 直接暴露到互联网。
5. **隐藏项目名**：设 `BAND_NOTIFY_INCLUDE_PROJECT=0`（hook / pi / DSH 通用）；
   DSH 也可在配置里设 `includeProjectName: false`。
6. **保护日志**：`~/.local/state/band-notify/` 下可能含项目名；贴日志前先脱敏。
7. **轮换 topic**：怀疑泄露时，重新运行 `install.sh --force` 生成新 topic，
   在手机里删掉旧订阅并重新扫码；旧缓存会在 `cache-duration` 后过期，
   要立即清除可停服务后删除 `~/.cache/band-notify/ntfy-cache.db`。
8. **校验 APK**：只从 F-Droid / GitHub Releases 下载，并核对下载页/源公布的校验值。
   F-Droid 与 GitHub Release 的签名和哈希不同，不要混用。

## 报告漏洞

请通过仓库的 **Security → Report a vulnerability**（GitHub Security Advisory）私下报告，
不要在公开 issue 里贴 topic、内网 IP、日志或可复现的利用细节。
