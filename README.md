# DNSChain

![macOS](https://img.shields.io/badge/macOS-14.0%2B-black)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![Release](https://img.shields.io/github/v/release/jianzhoujz/dns-chain)

DNSChain 是一个 macOS 菜单栏应用，在本机启动一个 DNS-over-HTTPS 服务，并按配置的 DNSChain 逐级查询、回落和记录日志。

它适合把 Chrome Secure DNS 指向本机：

```text
https://localhost:8053/dns-query
```

> AI 协作 Agent / 贡献者请先看 [AGENTS.md](AGENTS.md)。那里记录了项目结构、关键设计约束、构建发布流程和不能随意改动的行为边界。

## 功能

- macOS 菜单栏应用，无 Dock 图标，启动后默认启动本地 DoH 服务。
- 本地 HTTPS DoH Server 基于 SwiftNIO、NIOHTTP1 和 NIOSSL。
- 支持 `POST /dns-query`，MVP Content-Type 为 `application/dns-message`。
- DNSChain Resolver 支持 system DNS、DoH upstream、plain DNS upstream。
- 支持 timeout、network error、SERVFAIL、REFUSED、empty answer、blocked IP、blocked CNAME 的回落。
- 默认保护内网后缀，如 `.local`、`.lan`、`.home.arpa`、`.corp`、`.internal`。
- 内存 TTL 缓存和最近 1000 条查询日志。
- 日志展示每次查询的 qtype、最终状态、每个 fallback attempt 和 DNS answer。
- 本地 HTTP/HTTPS 代理入口，支持写入/关闭 macOS 系统代理，并展示代理请求列表。
- 用 Swift 生成本机 Root CA 和 localhost 证书；信任安装/卸载通过 macOS `security` 命令完成。
- 配置文件固定在 `~/.config/dns-chain/config.json`，界面可查看、复制、在 Finder 中显示，并可用系统编辑器打开。
- 支持开机启动。
- 支持检查 GitHub Releases 更新。

## 安装

推荐使用 Homebrew：

```bash
brew tap jianzhoujz/tap
brew install --cask dns-chain
```

更新：

```bash
brew update
brew upgrade --cask dns-chain
```

卸载：

```bash
brew uninstall --cask dns-chain
```

也可以从 [GitHub Releases](https://github.com/jianzhoujz/dns-chain/releases) 下载：

```text
DNSChain-版本号.dmg
```

打开 DMG 后，将 `DNSChain.app` 拖到 `Applications`。

## 首次启动

当前应用使用 ad-hoc 签名，没有 Apple Developer ID 签名。首次启动时，macOS 可能提示无法验证开发者或阻止打开。

可以在：

```text
系统设置 -> 隐私与安全性
```

选择“仍要打开”。如果仍然无法打开，可移除 quarantine 标记：

```bash
xattr -dr com.apple.quarantine "/Applications/DNSChain.app"
```

## 证书

本地 DoH 服务使用 `https://localhost:8053/dns-query`，因此需要本机信任 DNSChain 生成的 Root CA。

在菜单栏打开设置后：

1. 进入“DNS Chain”
2. 点击“生成/修复”
3. 点击“安装信任”
4. 按系统授权提示确认

证书文件位于：

```text
~/Library/Application Support/DNSChain/certs/
```

安装信任只写入当前用户 Trust Settings，不写入 System Keychain。

## 配置

配置文件：

```text
~/.config/dns-chain/config.json
```

默认 DNSChain：

1. 系统 DNS
2. 阿里云 DoH
3. 腾讯 DNSPod DoH
4. 阿里云 plain DNS
5. 腾讯 DNSPod plain DNS

如果系统 DNS 对某些域名返回拦截结果，可以在配置里维护：

```json
{
  "blocked_answers": {
    "cname_suffixes": [".oneagent-filter.alibaba-inc.com"],
    "ip_cidrs": []
  }
}
```

命中 blocked CNAME 或 blocked IP 后，resolver 会继续尝试后续 upstream。

## 本地代理

“代理”页可以启动一个本地 HTTP/HTTPS 代理入口：

```text
127.0.0.1:8080
```

代理支持普通 HTTP 请求转发和 HTTPS `CONNECT` 隧道，并在界面中显示请求方法、目标地址、状态和上下行字节数。需要让系统流量统一走这个入口时，可以点击“写入系统代理”；恢复时点击“关闭系统代理”。

## Chrome 配置

打开 Chrome：

```text
Settings -> Privacy and security -> Security -> Use secure DNS
```

选择自定义 provider：

```text
https://localhost:8053/dns-query
```

## 开发

构建和测试：

```bash
swift build
swift test
```

开发运行：

```bash
swift run DNSChain
```

构建 `.app`：

```bash
./build.sh
open "build/DNSChain.app"
```

安装到 `/Applications`：

```bash
./install.sh
```

生成 DMG：

```bash
./package-dmg.sh
```

发布构建可指定版本：

```bash
APP_VERSION=0.1.1 APP_BUILD=0.1.1 ./package-dmg.sh
```

## 系统要求

- macOS 14.0 Sonoma 或更高版本
- Apple Silicon 和 Intel Mac 均支持 SwiftPM 构建；发布包以当前发布脚本构建结果为准

## English

DNSChain is a macOS menu bar app that runs a local DNS-over-HTTPS endpoint and resolves queries through a configurable DNS chain with fallback, cache, certificates, and query logs.

Chrome Secure DNS URL:

```text
https://localhost:8053/dns-query
```

### Features

- Menu bar app with no Dock icon.
- Local HTTPS DoH server implemented with SwiftNIO, NIOHTTP1, and NIOSSL.
- Swift resolver for system DNS, DoH upstreams, and plain DNS upstreams.
- Fallback on timeout, network errors, selected RCODEs, empty answers, blocked IPs, and blocked CNAMEs.
- Protected internal suffixes such as `.local`, `.lan`, `.home.arpa`, `.corp`, and `.internal`.
- In-memory TTL cache and recent query logs.
- Per-query attempt details, including qtype, fallback attempts, final upstream, RCODE, and answers.
- Local HTTP/HTTPS proxy endpoint with system proxy apply/clear controls and request logs.
- Local Root CA and localhost certificate generation in Swift.
- Config file at `~/.config/dns-chain/config.json`.
- Launch at login and GitHub release update checks.

### Install

```bash
brew tap jianzhoujz/tap
brew install --cask dns-chain
```

Manual downloads are available from [GitHub Releases](https://github.com/jianzhoujz/dns-chain/releases).

### First Launch

The app is currently ad-hoc signed. macOS may block the first launch. Use System Settings -> Privacy & Security -> Open Anyway, or remove quarantine:

```bash
xattr -dr com.apple.quarantine "/Applications/DNSChain.app"
```

### Development

```bash
swift build
swift test
./build.sh
./package-dmg.sh
```

## Feedback

Please file issues at [GitHub Issues](https://github.com/jianzhoujz/dns-chain/issues).
