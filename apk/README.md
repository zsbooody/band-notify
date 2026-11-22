# ntfy Android APK

本仓库**默认不提交 APK**（`.gitignore` 已忽略 `apk/*.apk`）。请从官方渠道下载：

- F-Droid：https://f-droid.org/packages/io.heckel.ntfy/
- Google Play（需要 GMS）：搜索 `ntfy`
- 官方安装说明：https://docs.ntfy.sh/subscribe/phone/

已测试版本：`ntfy 1.25.2`（Android）。

F-Droid 与 Google Play / GitHub 构建的 APK **签名和哈希不同**，不要混用校验值。
请以你实际下载渠道页面公布的 SHA256/签名信息为准；下载后自行校验：

```bash
sha256sum ntfy-*.apk
```

许可证：ntfy Android App 与上游仓库一致，为 Apache-2.0。
详见仓库根的 `THIRD_PARTY_NOTICES.md`。

> 自建服务器不走 Firebase/FCM，所以国行无 GMS 的 Android 手机也能即时收到通知。
> 只有官方域名 `ntfy.sh` 的 Play 版才依赖 FCM。
