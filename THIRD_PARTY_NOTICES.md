# 第三方组件与归属

本仓库自身以 Apache-2.0 发布（见 `LICENSE`）。下面是运行时涉及的外部组件；
它们不属于本仓库，也不随本仓库分发（APK 除外，且默认不提交到 Git）。

## ntfy

- 用途：本机推送服务 + 手机端通知 App。
- 许可证：Apache-2.0。
- 上游：https://github.com/binwiederhier/ntfy
- 版权：Copyright (c) Philipp C. Heckel and ntfy contributors。
- 说明：`install.sh` 需要用户自行安装 ntfy 服务端二进制；仓库不包含该二进制。

## ntfy Android App（可选）

- 用途：手机端订阅与通知。
- 许可证：Apache-2.0（与上游仓库一致）。
- 上游：https://github.com/binwiederhier/ntfy（Android 源码在同一仓库）
- 下载：F-Droid / Google Play / https://docs.ntfy.sh/subscribe/phone/；
  仓库默认不提交 APK。
- 已测试版本：ntfy 1.25.2（Android）。F-Droid 与 Google Play / GitHub 构建的
  签名和哈希不同，请以实际下载渠道公布的校验值为准；不要使用来源不明的 APK。

## qrencode（可选）

- 用途：`make-subscribe.sh` 生成订阅二维码。
- 许可证：LGPL-2.1。
- 上游：https://fukuchi.org/works/qrencode/
- 说明：仅作为外部命令调用，不链接、不打包。

## 系统依赖

`bash`、`curl`、`python3`、`systemd`、`iproute2`、`util-linux`（`ss`/`flock`）、
`jq`（可选）等由用户系统提供，各自遵循其发行版许可证。

## AI harness 与商标

本项目通过各 AI coding agent 自带的 hooks / 插件机制接入，包括但不限于
pi、Grok、Kimi、ZCode、DSH。这些产品及其商标归各自所有者所有。
本项目与它们没有隶属或背书关系，也未分发它们的代码或二进制。

## 免责声明

本项目按“现状”提供，不附带任何明示或暗示担保。把通知服务暴露到不可信网络
之前，请阅读 `docs/security.md` 并自行评估风险。
