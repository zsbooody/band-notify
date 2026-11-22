# 安全与隐私

完整的安全策略与报告方式见仓库根的 [SECURITY.md](../SECURITY.md)。本文给出部署时的
具体操作。

## 默认假设

band-notify 默认假设你在**可信的家庭/个人热点局域网**里使用：

- ntfy 监听 `:2586`（等价于所有网卡），匿名读写；
- 手机通过 HTTP 订阅；
- topic 是唯一凭据；
- 通知正文可能包含项目目录名。

如果网络里有不可信设备（公司、宿舍、咖啡厅、共享办公），请按下面加固。

## 1. 不要暴露到公网

不要把 2586 端口映射到路由器外网，也不要用公网 IP 直接监听。
需要远程时，用 VPN 或带认证的隧道，不要把裸 ntfy 暴露出去。

## 2. 防火墙只放行手机

```bash
# 例：只允许手机 IP
sudo ufw allow from 192.168.1.23 to any port 2586 proto tcp

# 或只允许一个可信网段
sudo ufw allow from 192.168.1.0/24 to any port 2586 proto tcp
```

不要为了省事放行整个 `10.0.0.0/8` 或 `0.0.0.0/0`。

## 3. 开启 ntfy 认证

ntfy 2.x 的 `user add` 不接受 `--config`，要用 `NTFY_CONFIG_FILE` 环境变量。
正确顺序（先用 `install.sh` 生成配置）：

```bash
# 1) 在 ~/.config/band-notify/ntfy-server.yml 取消注释（用文件里已生成的绝对路径）：
#      auth-file: "/home/<you>/.config/band-notify/auth.yml"
#      auth-default-access: "deny-all"

# 2) 先启动/重启一次服务，生成 auth.yml
systemctl --user restart band-notify-ntfy

# 3) 创建用户（密码用 NTFY_PASSWORD 传入）
NTFY_CONFIG_FILE="$HOME/.config/band-notify/ntfy-server.yml" \
  NTFY_PASSWORD='<password>' ntfy user add your-user

# 4) 只给这个 topic 读写权限
NTFY_CONFIG_FILE="$HOME/.config/band-notify/ntfy-server.yml" \
  ntfy access your-user '<TOPIC>' read-write

# 5) 重启生效
systemctl --user restart band-notify-ntfy
```

`auth-default-access: deny-all` 会先锁死匿名访问；在手机 ntfy App 里填好
用户名/密码之前，手环不会收到通知。

## 4. 跨不可信网络用 HTTPS

在 ntfy 前放 Caddy/Nginx 反向代理并配置 TLS；手机订阅 `https://...`。
自签名证书在 Android 上信任链麻烦，建议用可信证书或 VPN。

## 5. 少暴露项目名

- 通用开关：`BAND_NOTIFY_INCLUDE_PROJECT=0`（`band-notify-hook`、pi 扩展、DSH 都识别）。
- DSH 插件也可在 `cordis.patch.yml`/DSH 配置里设 `includeProjectName: false`。
- 通知本身在局域网明文传输，且会在 ntfy 缓存 `cache-duration`（默认 12h）。

## 6. 保护本地文件

- `~/.config/band-notify/env`、`config.json` 权限应为 `600`（`install.sh` 会设置）。
- `~/.local/state/band-notify/` 下日志可能含项目名；贴日志前先脱敏。
- 不要把 `subscribe.html`、二维码、`config.json`、`env` 提交到 Git。
  `.gitignore` 已覆盖这些路径。

## 7. 轮换 topic

怀疑 topic 泄露时：

```bash
./install.sh --force       # 生成新 topic，旧配置会备份
band-notify-subscribe      # 重新生成订阅页
```

手机里删掉旧订阅，重新扫码。要立刻清掉旧缓存消息：

```bash
systemctl --user stop band-notify-ntfy
rm -f ~/.cache/band-notify/ntfy-cache.db
systemctl --user start band-notify-ntfy
```

## 8. APK 供应链

只从 F-Droid 或 GitHub Releases 下载 ntfy App，并核对 `apk/README.md` 里的 SHA256。
不要使用来源不明的 APK。

## 9. 报告问题

通过仓库的 Security Advisory 私下报告，不要在公开 issue 里贴 topic、内网 IP 或日志。
