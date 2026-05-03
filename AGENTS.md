# AGENTS.md — DNSChain 项目指南

本文件是 AI 协作 Agent 的项目入口。开始改代码前先读本文，再读源码。

## 项目定位

DNSChain 是一个 macOS 菜单栏应用，在本机启动 HTTPS DNS-over-HTTPS 服务：

```text
https://localhost:8053/dns-query
```

Chrome 或其它客户端把 Secure DNS 指向该地址后，应用按配置的 DNSChain 依次查询 system DNS、DoH upstream、plain DNS upstream，并根据 fallback 条件决定是否继续尝试下一个上游。

应用还提供一个本地 HTTP/HTTPS 代理入口，默认监听：

```text
127.0.0.1:8080
```

代理负责接收本地 HTTP 代理请求并原样转发；HTTPS 使用 `CONNECT` 隧道。UI 可写入/关闭 macOS 系统代理，并展示代理请求列表。

核心约束：

- 全 Swift 实现，不引入 Go helper/daemon。
- HTTP/TLS 协议层使用 SwiftNIO、NIOHTTP1、NIOSSL，不手写原始 HTTP server。
- 服务随 App 生命周期运行，退出 App 后本地 DoH 停止。
- 默认只监听 `127.0.0.1`，不要改成 `0.0.0.0`。
- 配置文件固定在 `~/.config/dns-chain/config.json`。

## 仓库结构

```text
dns-chain/
├── Package.swift
├── Sources/
│   ├── DNSChain/
│   │   └── DNSChainApp.swift
│   └── DNSChainCore/
│       ├── LocalDoHServer.swift
│       ├── LocalHTTPProxyServer.swift
│       ├── ChainResolver.swift
│       ├── DNSMessage.swift
│       ├── Config.swift
│       ├── ConfigStore.swift
│       ├── CertificateManager.swift
│       ├── DoHUpstream.swift
│       ├── PlainDNSUpstream.swift
│       ├── SystemDNS.swift
│       ├── CacheStore.swift
│       └── Logging.swift
├── Tests/
│   └── DNSChainCoreTests/
├── tools/
│   └── make_app_icon.swift
├── build.sh
├── install.sh
├── uninstall.sh
└── package-dmg.sh
```

## 关键模块

| 文件 | 职责 |
| --- | --- |
| `Sources/DNSChain/DNSChainApp.swift` | SwiftUI/AppKit 菜单栏、设置窗口、状态管理、更新检查 |
| `Sources/DNSChainCore/LocalDoHServer.swift` | SwiftNIO HTTPS DoH server；只处理 NIO 解析后的 HTTP request parts |
| `Sources/DNSChainCore/LocalHTTPProxyServer.swift` | 本地 HTTP/HTTPS 代理；HTTP 转发和 HTTPS CONNECT 隧道 |
| `Sources/DNSChainCore/ChainResolver.swift` | DNSChain、fallback、cache、query log |
| `Sources/DNSChainCore/DNSMessage.swift` | 最小 DNS wire parser/response helper |
| `Sources/DNSChainCore/Config.swift` | JSON 配置模型和默认配置 |
| `Sources/DNSChainCore/ConfigStore.swift` | `~/.config/dns-chain/config.json` 读写和旧路径迁移 |
| `Sources/DNSChainCore/CertificateManager.swift` | Root CA / localhost cert 生成、信任安装与卸载 |
| `Sources/DNSChainCore/SystemDNS.swift` | `scutil --dns` 解析和 system resolver 选择 |

## Resolver 行为边界

`ChainResolver.resolve(_:)` 的重要语义：

- cache 命中时不访问 upstream，日志 `result = cached`。
- protected suffix 只走 system DNS。
- upstream 返回可接受响应时立即返回，并记录所有已发生 attempts。
- 命中 blocked IP / blocked CNAME 且配置开启 fallback 时继续后续 upstream。
- `empty_answer` 或 `nxdomain` 如果配置要求 fallback，会继续尝试；如果所有上游都只给出合法 no-data 响应，最终返回最后一个 no-data 响应，不要合成 `SERVFAIL`。
- 只有所有 upstream 都超时、网络错误或无合法响应时，才合成 `SERVFAIL`。

日志必须保留每个 attempt。不要只记录最终 upstream，否则无法排查连续 fallback。

## DNS Wire 范围

`DNSMessage.swift` 只做项目需要的最小解析：

- Header
- 单 Question
- RCODE
- TTL
- A / AAAA / CNAME
- 其它 RR type 保留 raw type 和 hex value

浏览器响应使用 upstream 原始 bytes 透传，不重新序列化完整 DNS 包。

## 证书

证书生成使用 Swift 依赖：

- `swift-certificates`
- `swift-crypto`
- `swift-asn1`

不要引入 mkcert。安装信任通过 macOS `security` 写当前用户 Trust Settings，不写 System Keychain。

证书路径：

```text
~/Library/Application Support/DNSChain/certs/
```

## UI 约定

- 状态栏使用 `NSStatusItem(withLength: 22)`，菜单栏图标当前是 `🐙`；DoH 服务停止时图标使用低透明度灰色状态。
- 设置窗口由 `SettingsWindowPresenter` 创建 AppKit `NSWindow`，内容是 SwiftUI。
- 设置窗口 tab 为 `DNS Chain`、`代理`、`日志`。`DNS Chain` 页左侧放本地 DoH、证书、回落、配置文件和应用信息，右侧放 DNSChain 上游列表。
- 查询日志需要展示 qtype、result、final upstream、RCODE、attempts 和 answers。
- 代理日志需要展示 method、target、status、bytes up/down。
- 配置文件在 UI 中只读展示；编辑交给系统编辑器。

## 构建与测试

所有 shell 命令在 Codex 环境中要加 `rtk` 前缀。

```bash
rtk swift build
rtk swift test
rtk ./build.sh
rtk ./package-dmg.sh
```

开发运行：

```bash
rtk swift run DNSChain
```

构建脚本输出：

```text
build/DNSChain.app
dist/DNSChain-<version>.dmg
```

打包后的 bundle 名是 `DNSChain.app`；内部 `CFBundleExecutable` 当前故意使用 `Google Chrome`，不要在没确认网络环境影响前改回 `DNSChain`。

## 发布流程

1. 更新 README / AGENTS / 代码。
2. 跑测试：

   ```bash
   rtk swift test
   ```

3. 打包：

   ```bash
   rtk env APP_VERSION=<version> APP_BUILD=<version> UNIVERSAL=1 ./package-dmg.sh
   ```

4. GitHub Release：

   ```bash
   rtk git tag v<version>
   rtk git push origin main --tags
   rtk gh release create v<version> dist/DNSChain-<version>.dmg --repo jianzhoujz/dns-chain
   ```

5. 更新 Homebrew tap 的 `Casks/dns-chain.rb`，sha256 来自：

   ```bash
   rtk shasum -a 256 dist/DNSChain-<version>.dmg
   ```

## 不要做的事

- 不要把本地服务暴露到外网接口。
- 不要手写 HTTP parser。
- 不要恢复 Go helper、Admin API、跨进程 token 或 helper 生命周期管理。
- 不要把证书安装改成默认写 System Keychain。
- 不要把日志压缩成最终结果，attempt 级日志是核心排障能力。
- 不要用 `pkill -x "Google Chrome"` 停止本应用；停止脚本必须按 DNSChain bundle 路径匹配，避免误杀真正的 Chrome。
