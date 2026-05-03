# DNS Chain 开发计划

> 目标读者：Codex / 开发 Agent  
> 产品名：DNS Chain  
> 平台：macOS  
> 形态：菜单栏 App + 本地 DoH 网关  
> 核心理念：用户维护一个 DNS 请求链，从上到下依次尝试；当前 DNS 返回异常时，自动回落到下一个 DNS。

---

## 1. 背景与目标

Chrome 的 Secure DNS / DNS over HTTPS 设置只能配置一个 DoH 地址，不像 Firefox 那样提供较完善的 exclude / fallback 机制。DNS Chain 的目标是提供一个本地 DoH 网关，让 Chrome 只需要配置一个本地地址：

```text
https://localhost:8053/dns-query
```

实际 DNS 解析由 DNS Chain 在本机完成。

DNS Chain 不修改系统 DNS，不做系统级代理，不做广告过滤，不做复杂的国内外分流。第一版只解决一个核心问题：

```text
收到 DNS 请求
  ↓
按用户配置的 DNS Chain 从上到下请求
  ↓
如果当前 DNS 正常返回，立即返回给浏览器
  ↓
如果当前 DNS 超时、失败、返回异常结果或命中拦截特征，尝试下一个 DNS
```

---

## 2. MVP 范围

### 2.1 必须实现

1. macOS 菜单栏 App。
2. 开机启动开关。
3. 本地 HTTPS DoH Server：
   - 默认监听：`127.0.0.1:8053`
   - 默认路径：`/dns-query`
   - 对外配置地址：`https://localhost:8053/dns-query`
4. 支持 Chrome / Chromium 的 DoH 请求：
   - `POST /dns-query`
   - `Content-Type: application/dns-message`
   - `Accept: application/dns-message`
   - 可选支持：`GET /dns-query?dns=<base64url_dns_wire_message>`
5. DNS Chain 可编辑：
   - 支持拖拽排序。
   - 支持启用 / 禁用某个上游。
   - 支持删除自定义上游。
   - 支持添加系统 DNS、DoH URL、普通 DNS IP。
6. 默认 DNS 预设库。
7. 全局回落条件。
8. 拦截 IP / CNAME 识别。
9. 查询日志。
10. 本地证书生成、安装、卸载。
11. 配置持久化。

### 2.2 暂不实现

第一版不要实现：

1. 系统级 DNS Proxy / Network Extension。
2. 广告过滤。
3. Hosts 规则。
4. GeoIP / 国内外自动分流。
5. 规则集订阅。
6. ECS / EDNS Client Subnet 配置。
7. DNSSEC 验证。
8. 多 Profile。
9. 复杂代理联动。
10. Windows / Linux 版本。

---

## 3. 推荐技术栈

### 3.1 总体架构

推荐采用：

```text
SwiftUI macOS App
  ↓ 启停 / 配置 / 展示状态
Go Core Helper
  ↓ 本地 HTTPS DoH Server
  ↓ DNS Chain Resolver
  ↓ 日志与配置
```

理由：

1. SwiftUI 适合做原生菜单栏和设置界面。
2. Go 适合实现 DNS 协议、HTTPS Server、并发请求、配置热加载。
3. Go 生态中可以使用 `github.com/miekg/dns` 处理 DNS wire message。
4. 后续 Go Core 可以独立做 CLI / daemon。

### 3.2 目录结构建议

```text
dns-chain/
  README.md
  docs/
    DEVELOPMENT_PLAN.md
    CHROME_SETUP.md
    CERTIFICATE.md

  app/
    DNSChain.xcodeproj
    DNSChain/
      DNSChainApp.swift
      MenuBarView.swift
      SettingsWindow.swift
      Views/
        StatusView.swift
        ChainEditorView.swift
        UpstreamPresetView.swift
        FallbackSettingsView.swift
        CertificateView.swift
        LogView.swift
      Services/
        HelperManager.swift
        ConfigStore.swift
        LoginItemManager.swift

  core/
    go.mod
    cmd/
      dns-chain-helper/
        main.go
    internal/
      admin/
        server.go
      certs/
        ca.go
        keychain_darwin.go
      config/
        config.go
        defaults.go
        validate.go
      dohserver/
        server.go
        handler.go
      resolver/
        chain.go
        classifier.go
        upstream.go
        upstream_doh.go
        upstream_plain.go
        upstream_system_darwin.go
        cache.go
      logstore/
        logstore.go
      version/
        version.go

  scripts/
    build-helper.sh
    package-app.sh
```

---

## 4. 产品模型

### 4.1 核心对象：DNS Chain

DNS Chain 是一个有序列表。

```yaml
dns_chain:
  - id: system
    name: 系统 DNS
    type: system
    enabled: true

  - id: alidns_doh
    name: 阿里云 DoH
    type: doh
    url: https://dns.alidns.com/dns-query
    enabled: true

  - id: dnspod_doh
    name: 腾讯 DNSPod DoH
    type: doh
    url: https://doh.pub/dns-query
    enabled: true

  - id: alidns_plain
    name: 阿里云 DNS
    type: plain_dns
    servers:
      - 223.5.5.5
      - 223.6.6.6
    port: 53
    enabled: true

  - id: dnspod_plain
    name: 腾讯 DNSPod DNS
    type: plain_dns
    servers:
      - 119.29.29.29
    port: 53
    enabled: true
```

解析逻辑：

```text
for upstream in dns_chain:
    if upstream.disabled:
        continue

    response, err = query(upstream, dns_request)

    if err:
        log failure
        continue

    classification = classify(response)

    if classification.normal:
        return response

    if classification.should_fallback:
        log fallback reason
        continue

    return response

return last_error_or_servfail_response
```

---

## 5. 默认预设库

### 5.1 默认进入 Chain

第一版默认 Chain：

```text
1. 系统 DNS
2. 阿里云 DoH
3. 腾讯 DNSPod DoH
4. 阿里云 DNS
5. 腾讯 DNSPod DNS
```

### 5.2 预设库

用户点击「添加 DNS」时可以从预设库添加。

```yaml
presets:
  - id: system
    name: 系统 DNS
    type: system
    description: 使用 macOS 当前系统 DNS，适合公司 DNS / VPN / 内网环境。

  - id: alidns_doh
    name: 阿里云 DoH
    type: doh
    url: https://dns.alidns.com/dns-query
    description: 国内常用 DoH 服务。

  - id: dnspod_doh
    name: 腾讯 DNSPod DoH
    type: doh
    url: https://doh.pub/dns-query
    description: 国内常用 DoH 服务。

  - id: alidns_plain
    name: 阿里云 DNS
    type: plain_dns
    servers:
      - 223.5.5.5
      - 223.6.6.6
    port: 53
    description: 国内常用普通 DNS。

  - id: dnspod_plain
    name: 腾讯 DNSPod DNS
    type: plain_dns
    servers:
      - 119.29.29.29
    port: 53
    description: 国内常用普通 DNS。

  - id: cloudflare_doh
    name: Cloudflare DoH
    type: doh
    url: https://cloudflare-dns.com/dns-query
    description: 全球主流 DoH 服务，国内网络可能不稳定。

  - id: cloudflare_plain
    name: Cloudflare DNS
    type: plain_dns
    servers:
      - 1.1.1.1
      - 1.0.0.1
    port: 53
    description: 全球主流普通 DNS，国内网络可能不稳定。

  - id: google_doh
    name: Google Public DNS DoH
    type: doh
    url: https://dns.google/dns-query
    description: 全球主流 DoH 服务，国内网络可能不可用。

  - id: google_plain
    name: Google Public DNS
    type: plain_dns
    servers:
      - 8.8.8.8
      - 8.8.4.4
    port: 53
    description: 全球主流普通 DNS，国内网络可能不可用。
```

注意：

1. Cloudflare / Google 内置在预设库中，但不要默认启用。
2. 默认不要使用国外 DNS，避免影响国内网络可用性和 CDN 调度。
3. 允许用户手动把国外 DNS 加到 Chain 末尾或任意位置。

---

## 6. 手动添加 DNS

### 6.1 支持类型

用户可添加三类 DNS：

```text
1. 系统 DNS
2. DoH 地址
3. 普通 DNS IP
```

### 6.2 DoH 手动输入

字段：

```yaml
name: 自定义名称
type: doh
url: https://example.com/dns-query
timeout_ms: 2000
```

校验：

1. URL 必须是 `https://`。
2. path 可以不是 `/dns-query`，但默认建议 `/dns-query`。
3. 不支持 `http://`。
4. 保存前提供「测试连接」按钮。
5. 测试时用 `example.com A` 或 `dns.google A` 发起真实 DoH 查询。

### 6.3 普通 DNS 手动输入

字段：

```yaml
name: 自定义名称
type: plain_dns
servers:
  - 8.8.8.8
  - 8.8.4.4
port: 53
protocol: udp_tcp
timeout_ms: 1500
```

行为：

1. 默认 UDP 查询。
2. 如果 UDP 返回 TC truncated，使用 TCP 重试。
3. 如果 UDP 超时，可尝试 TCP 一次。
4. 支持 IPv4 / IPv6 DNS 服务器。

---

## 7. 回落条件

### 7.1 默认开启

```yaml
fallback_when:
  timeout: true
  network_error: true
  servfail: true
  refused: true
  empty_answer: true
  blocked_ip: true
  blocked_cname: true
  nxdomain: false
```

默认不对 `NXDOMAIN` 回落，原因：

1. 很多域名是真的不存在。
2. 公司内网域名如果被继续发给公网 DNS，会造成不必要的内部域名泄露。
3. NXDOMAIN 回落可能带来不可预测结果。

### 7.2 DNS RCODE 行为

| RCODE | 默认行为 |
|---|---|
| `NOERROR` 且有 Answer | 检查是否命中 blocked IP / CNAME；未命中则正常返回 |
| `NOERROR` 但空 Answer | 默认回落 |
| `SERVFAIL` | 默认回落 |
| `REFUSED` | 默认回落 |
| `NXDOMAIN` | 默认不回落 |
| 其他错误 | 默认回落 |

### 7.3 网络错误行为

以下情况默认回落：

1. 上游连接超时。
2. TLS 握手失败。
3. DoH HTTP 非 2xx。
4. DoH HTTP 200 但 DNS message 解码失败。
5. 普通 DNS UDP/TCP 超时。
6. 普通 DNS 返回格式错误。

---

## 8. 拦截结果识别

### 8.1 用户配置

```yaml
blocked_answers:
  ip_cidrs:
    - 10.20.30.40/32
    - 172.16.100.0/24
  cname_suffixes:
    - .block.company.internal
    - .warning.company.net
```

命中条件：

1. A / AAAA 记录的 IP 命中 `ip_cidrs`。
2. CNAME 记录的目标域名以 `cname_suffixes` 结尾。

命中后行为：

```text
标记为 blocked_answer
尝试 DNS Chain 中的下一个上游
```

### 8.2 拦截特征学习

提供「检测拦截页」功能。

输入：

```text
被公司 DNS 拦截的网站域名
```

流程：

```text
1. 使用 DNS Chain 第一项查询。
2. 使用 DNS Chain 第二项或用户选择的备用 DNS 查询。
3. 对比返回结果。
4. 如果第一项返回内网 IP / 固定 CNAME，提示用户加入拦截特征。
```

UI 示例：

```text
检测到系统 DNS 将 example.com 解析到：

10.20.30.40

备用 DNS 返回：

93.184.216.34

是否将 10.20.30.40 标记为拦截 IP？
```

---

## 9. 内网域名保护

虽然产品不做复杂规则，但建议保留一个极简安全保护：

```yaml
protected_suffixes:
  - .local
  - .lan
  - .home.arpa
  - .corp
  - .internal
```

默认行为：

```text
如果域名命中 protected_suffixes：
  只允许查询 system 类型上游。
  不回落到公网 DoH / 公网 DNS。
```

UI 文案：

```text
内网域名保护：避免将 .local、.corp、.internal 等内部域名发送到公网 DNS。
```

允许用户关闭，但默认开启。

---

## 10. 本地 DoH Server

### 10.1 监听地址

默认：

```yaml
server:
  listen_host: 127.0.0.1
  listen_port: 8053
  doh_path: /dns-query
  public_url: https://localhost:8053/dns-query
```

后续可支持：

```yaml
listen_host: "::1"
```

MVP 可以优先只监听 `127.0.0.1`，但证书仍然包含：

```text
DNS:localhost
IP:127.0.0.1
IP:::1
```

### 10.2 支持请求格式

必须支持：

```http
POST /dns-query
Content-Type: application/dns-message
Accept: application/dns-message
```

建议支持：

```http
GET /dns-query?dns=<base64url_dns_wire_message>
Accept: application/dns-message
```

响应：

```http
HTTP/1.1 200 OK
Content-Type: application/dns-message

<dns wire format>
```

如果请求不是合法 DNS message：

```http
HTTP/1.1 400 Bad Request
```

### 10.3 Chrome 配置

设置界面提供一键复制：

```text
https://localhost:8053/dns-query
```

可选提供说明：

```text
Chrome → 设置 → 隐私和安全 → 安全 → 使用安全 DNS → 自定义 → 粘贴本地地址
```

---

## 11. 证书管理

### 11.1 原则

1. 不要打包预生成的 Root CA。
2. 每台机器首次启动时生成唯一 Root CA。
3. 用该 Root CA 签发 localhost 服务证书。
4. 将 Root CA 安装到 macOS System Keychain 并设为信任。
5. 提供卸载证书功能。

### 11.2 文件位置

```text
~/Library/Application Support/DNS Chain/certs/
  root-ca.pem
  root-ca.key
  localhost.crt
  localhost.key
```

权限：

```text
root-ca.key: 0600
localhost.key: 0600
root-ca.pem: 0644
localhost.crt: 0644
```

### 11.3 Root CA

生成参数建议：

```text
Algorithm: ECDSA P-256 或 RSA 2048/3072
Common Name: DNS Chain Local Root CA
Key Usage: Cert Sign, CRL Sign
Is CA: true
Validity: 10 years
```

### 11.4 localhost 服务证书

必须包含 SAN：

```text
DNS:localhost
IP:127.0.0.1
IP:::1
```

参数建议：

```text
Common Name: localhost
Extended Key Usage: Server Auth
Validity: 397 days or less
```

### 11.5 安装 Root CA

Go helper 可以调用 macOS `security` 命令：

```bash
sudo security add-trusted-cert \
  -d \
  -r trustRoot \
  -k /Library/Keychains/System.keychain \
  "/path/to/root-ca.pem"
```

注意：

1. 需要用户授权 / 输入管理员密码。
2. UI 要清楚说明用途：只为让 Chrome 信任本机 `https://localhost:8053/dns-query`。
3. 不要静默安装。

### 11.6 卸载 Root CA

```bash
sudo security delete-certificate \
  -c "DNS Chain Local Root CA" \
  /Library/Keychains/System.keychain
```

UI 提供按钮：

```text
移除本地证书
```

---

## 12. 系统 DNS 上游

### 12.1 macOS System DNS 的实现要求

不要简单依赖 `/etc/resolv.conf`。macOS 上 VPN / 公司网络可能存在 scoped resolver 或 per-domain resolver。

MVP 实现建议：

1. 通过 `scutil --dns` 获取当前系统 DNS 配置。
2. 解析 resolver 列表。
3. 根据查询域名选择最匹配的 resolver：
   - domain-specific resolver 优先。
   - scoped resolver 其次。
   - default resolver 最后。
4. 使用 `github.com/miekg/dns` 对选中的 nameserver 发普通 DNS 查询。
5. 如果 nameserver 没端口，默认 53。
6. UDP 优先，TC 时 TCP 重试。

### 12.2 简化实现

如果第一版时间不够：

1. 先解析 `scutil --dns` 中 default resolver 的 nameserver。
2. 后续再增强 split DNS / scoped resolver 支持。

但必须在代码注释和 TODO 里标明限制。

---

## 13. 缓存

MVP 建议实现简单 TTL 缓存。

### 13.1 Cache Key

```text
qname + qtype + qclass
```

注意 qname 统一转小写并标准化尾部 dot。

### 13.2 Cache Value

```yaml
response_wire: bytes
expires_at: timestamp
upstream_id: string
```

### 13.3 TTL

1. 使用 DNS Answer 中的最小 TTL。
2. 最大 TTL 可设置为 300 秒。
3. 最小 TTL 可设置为 5 秒。
4. 默认不缓存 SERVFAIL。
5. NXDOMAIN 可选缓存，默认短缓存 30 秒。

---

## 14. 日志

### 14.1 日志字段

每次查询记录：

```yaml
timestamp: 2026-05-03T14:00:00+09:00
request_id: uuid
domain: example.com
qtype: A
client: 127.0.0.1
result: success | fallback | failed | protected
final_upstream: alidns_doh
attempts:
  - upstream: system
    status: blocked_ip
    latency_ms: 42
    detail: 10.20.30.40
  - upstream: alidns_doh
    status: success
    latency_ms: 87
rcode: NOERROR
answers:
  - type: A
    value: 93.184.216.34
```

### 14.2 存储

MVP 可以使用 SQLite 或 JSONL。

建议：

```text
~/Library/Application Support/DNS Chain/logs/query-log.sqlite
```

为了简化，第一版也可用内存环形日志：

```text
最多保存最近 1000 条
App 重启后清空
```

但如果要方便调试，建议 SQLite。

### 14.3 隐私设置

默认：

```text
只在本机保存日志
不上传
可一键清空
可关闭日志
```

---

## 15. 配置文件

建议使用 JSON 或 YAML。为了 SwiftUI 和 Go 互操作简单，优先 JSON。

路径：

```text
~/Library/Application Support/DNS Chain/config.json
```

示例：

```json
{
  "server": {
    "listen_host": "127.0.0.1",
    "listen_port": 8053,
    "doh_path": "/dns-query"
  },
  "dns_chain": [
    {
      "id": "system",
      "name": "系统 DNS",
      "type": "system",
      "enabled": true
    },
    {
      "id": "alidns_doh",
      "name": "阿里云 DoH",
      "type": "doh",
      "url": "https://dns.alidns.com/dns-query",
      "enabled": true,
      "timeout_ms": 2000
    },
    {
      "id": "dnspod_doh",
      "name": "腾讯 DNSPod DoH",
      "type": "doh",
      "url": "https://doh.pub/dns-query",
      "enabled": true,
      "timeout_ms": 2000
    },
    {
      "id": "alidns_plain",
      "name": "阿里云 DNS",
      "type": "plain_dns",
      "servers": ["223.5.5.5", "223.6.6.6"],
      "port": 53,
      "enabled": true,
      "timeout_ms": 1500
    },
    {
      "id": "dnspod_plain",
      "name": "腾讯 DNSPod DNS",
      "type": "plain_dns",
      "servers": ["119.29.29.29"],
      "port": 53,
      "enabled": true,
      "timeout_ms": 1500
    }
  ],
  "fallback_when": {
    "timeout": true,
    "network_error": true,
    "servfail": true,
    "refused": true,
    "empty_answer": true,
    "blocked_ip": true,
    "blocked_cname": true,
    "nxdomain": false
  },
  "blocked_answers": {
    "ip_cidrs": [],
    "cname_suffixes": []
  },
  "protected_suffixes": [
    ".local",
    ".lan",
    ".home.arpa",
    ".corp",
    ".internal"
  ],
  "cache": {
    "enabled": true,
    "max_ttl_seconds": 300,
    "min_ttl_seconds": 5,
    "negative_ttl_seconds": 30
  },
  "logging": {
    "enabled": true,
    "max_entries": 1000
  }
}
```

---

## 16. 本地 Admin API

SwiftUI App 需要查询 Go helper 状态、读取日志、触发重载配置。

建议 Go helper 提供仅本机可访问的 Admin API：

```text
http://127.0.0.1:8054
```

安全要求：

1. 只监听 `127.0.0.1`。
2. 启动时生成随机 token。
3. token 通过启动参数或本地权限文件传给 SwiftUI App。
4. 所有 Admin API 请求必须带 token。

### 16.1 API 示例

```http
GET /health
Authorization: Bearer <token>
```

响应：

```json
{
  "status": "running",
  "version": "0.1.0",
  "doh_server": "https://localhost:8053/dns-query",
  "uptime_seconds": 1234
}
```

```http
POST /reload
Authorization: Bearer <token>
```

```http
GET /logs?limit=100
Authorization: Bearer <token>
```

```http
POST /test-upstream
Authorization: Bearer <token>
Content-Type: application/json

{
  "upstream": {
    "type": "doh",
    "url": "https://dns.alidns.com/dns-query"
  },
  "domain": "example.com",
  "qtype": "A"
}
```

---

## 17. SwiftUI UI 设计

### 17.1 菜单栏

菜单栏图标点击后展示：

```text
DNS Chain
状态：运行中
本地地址：https://localhost:8053/dns-query
今日请求：1280
今日回落：37

[复制 Chrome 配置地址]
[打开设置]
[暂停服务]
[退出]
```

### 17.2 设置窗口

分为 5 个 Tab：

```text
1. 状态
2. DNS Chain
3. 回落条件
4. 证书
5. 日志
```

### 17.3 DNS Chain 页面

功能：

1. 展示当前 Chain。
2. 拖拽排序。
3. 启用 / 禁用。
4. 添加 DNS。
5. 删除自定义项。
6. 测试上游。
7. 恢复默认。

UI 示例：

```text
DNS Chain

☰ 1. 系统 DNS                         已启用    [测试]
☰ 2. 阿里云 DoH                       已启用    [测试]
☰ 3. 腾讯 DNSPod DoH                  已启用    [测试]
☰ 4. 阿里云 DNS                       已启用    [测试]
☰ 5. 腾讯 DNSPod DNS                  已启用    [测试]

[+ 添加 DNS]   [恢复默认]
```

### 17.4 回落条件页面

```text
当当前 DNS 出现以下情况时，尝试下一个 DNS：

[x] 请求超时
[x] 网络错误
[x] SERVFAIL
[x] REFUSED
[x] 返回空结果
[x] 命中拦截 IP / CNAME
[ ] NXDOMAIN

内网域名保护：
[x] 避免将 .local、.corp、.internal 等域名发送到公网 DNS

拦截 IP：
[10.20.30.40/32] [-]
[+ 添加]

拦截 CNAME 后缀：
[.block.company.internal] [-]
[+ 添加]

[检测拦截页]
```

### 17.5 证书页面

```text
本地证书状态：已安装 / 未安装 / 已过期
Root CA：DNS Chain Local Root CA
服务证书：localhost

[安装/修复证书]
[移除证书]
[重新生成证书]
```

### 17.6 日志页面

```text
搜索域名：[____________]

时间        域名              结果       最终 DNS       耗时
12:01:22    google.com        fallback   阿里云 DoH     92ms
12:01:25    internal.corp     protected  系统 DNS       15ms
12:01:27    example.com       success    系统 DNS       24ms
```

点击某条日志展示 attempts 详情。

---

## 18. Go Core 实现细节

### 18.1 依赖建议

```bash
go get github.com/miekg/dns
go get github.com/google/uuid
```

尽量少引入依赖。

### 18.2 核心接口

```go
type Upstream interface {
    ID() string
    Name() string
    Query(ctx context.Context, req *dns.Msg) (*dns.Msg, AttemptMeta, error)
}

type AttemptMeta struct {
    UpstreamID string
    Latency    time.Duration
    Status     string
    Detail     string
}

type Classifier interface {
    Classify(resp *dns.Msg) Classification
}

type Classification struct {
    Status         string
    ShouldFallback bool
    Detail         string
}
```

### 18.3 Chain Resolver

```go
func (r *ChainResolver) Resolve(ctx context.Context, req *dns.Msg) (*dns.Msg, QueryLog, error) {
    // 1. normalize question
    // 2. check protected suffix
    // 3. cache lookup
    // 4. iterate enabled upstreams
    // 5. classify response
    // 6. cache final healthy response
    // 7. return DNS response
}
```

### 18.4 DoH Upstream

DoH 上游请求：

```http
POST <url>
Content-Type: application/dns-message
Accept: application/dns-message
Body: DNS wire message
```

行为：

1. 默认使用 POST。
2. 使用 Go `net/http` client。
3. 超时可配置，默认 2 秒。
4. HTTP 非 2xx 视为 network_error。
5. Content-Type 不严格要求，但返回体必须能解码为 DNS message。
6. 不要在 DoH 请求里复用用户浏览器代理设置，MVP 先直连。

### 18.5 Plain DNS Upstream

行为：

1. 使用 UDP 查询。
2. 如果响应 TC=1，用 TCP 重试。
3. 如果 UDP 超时，可 TCP 重试一次。
4. 超时默认 1500ms。
5. 支持多个 servers，按顺序尝试。

### 18.6 System DNS Upstream

行为：

1. 解析 `scutil --dns`。
2. 获取 nameserver。
3. 使用 Plain DNS 逻辑查询这些 nameserver。
4. 记录最终使用的 system nameserver。

---

## 19. 开机启动

SwiftUI App 使用 macOS Login Item 能力。

目标：

```text
设置页中提供「开机启动」开关。
```

行为：

1. 用户开启后，App 在登录时自动启动。
2. App 启动时自动拉起 Go helper。
3. App 退出时停止 helper，除非后续设计为后台 daemon。

MVP 可以让 helper 只随 App 生命周期运行。

---

## 20. Helper 生命周期

### 20.1 启动

SwiftUI App 启动时：

```text
1. 检查配置文件。
2. 如果不存在，写入默认配置。
3. 检查证书。
4. 如果证书可用，启动 Go helper。
5. 如果证书不可用，提示用户安装证书。
```

### 20.2 停止

App 退出时：

```text
向 helper 发送 shutdown 请求。
如果失败，kill 进程。
```

### 20.3 配置变更

当用户修改 DNS Chain：

```text
1. SwiftUI 写 config.json。
2. 调用 helper /reload。
3. helper 验证配置。
4. 成功后切换新配置。
5. 失败则返回错误，UI 回滚或提示。
```

---

## 21. 错误处理

### 21.1 本地端口被占用

如果 `8053` 被占用：

1. UI 提示用户。
2. 允许用户修改端口。
3. 重新生成展示给 Chrome 的地址。

### 21.2 证书未信任

如果 HTTPS Server 启动了但证书未信任：

1. UI 显示「证书未信任」。
2. 提供修复按钮。
3. 修复后重新启动 helper。

### 21.3 Chain 全部失败

如果所有上游都失败：

1. 返回 DNS `SERVFAIL`。
2. 日志记录全部 attempts。
3. 菜单栏状态显示异常计数。

---

## 22. 测试计划

### 22.1 单元测试

必须测试：

1. 配置解析与校验。
2. DNS Chain 顺序。
3. fallback 条件。
4. RCODE 分类。
5. blocked IP CIDR 匹配。
6. blocked CNAME 后缀匹配。
7. protected suffix 匹配。
8. TTL 缓存。
9. DoH GET / POST 请求解析。
10. `scutil --dns` 输出解析。

### 22.2 集成测试

实现 mock upstream：

1. mock normal DNS。
2. mock timeout。
3. mock SERVFAIL。
4. mock REFUSED。
5. mock blocked IP。
6. mock empty answer。
7. mock DoH upstream。

测试场景：

```text
System DNS 正常 → 不访问第二个上游
System DNS 超时 → fallback 到 Ali DoH
System DNS 返回 blocked IP → fallback 到 Ali DoH
System DNS 返回 NXDOMAIN → 默认不 fallback
protected suffix 查询失败 → 不 fallback 到公网 DNS
```

### 22.3 手工验收

1. 启动 App。
2. 安装证书。
3. Chrome 配置 `https://localhost:8053/dns-query`。
4. 访问普通网站。
5. 日志里看到 DNS 请求。
6. 将第一项上游设为不可用，确认自动 fallback。
7. 添加一个自定义 DoH，确认可用。
8. 添加一个自定义普通 DNS，确认可用。
9. 修改 Chain 排序，确认生效。
10. 开启开机启动，重启登录后确认 App 自动启动。

---

## 23. 验收标准

### 23.1 功能验收

MVP 完成的标准：

1. Chrome 可以通过本地 DoH 地址解析域名。
2. DNS Chain 从上到下执行。
3. 当前上游正常时不会继续请求后续上游。
4. 当前上游异常时自动 fallback。
5. 用户可以添加 DoH URL。
6. 用户可以添加普通 DNS IP。
7. 用户可以启用 / 禁用 / 删除 / 排序上游。
8. 默认预设正确。
9. blocked IP / CNAME 生效。
10. 查询日志可查看。
11. 证书可安装和卸载。
12. 开机启动可开启和关闭。

### 23.2 稳定性验收

1. 连续运行 24 小时不崩溃。
2. 每秒 50 次 DNS 查询下无明显卡顿。
3. 上游超时时不会阻塞整个服务超过配置 timeout。
4. 配置热加载失败不会导致当前服务不可用。

---

## 24. 开发阶段拆分

### Phase 0：Repo 初始化

目标：

1. 创建 SwiftUI macOS App。
2. 创建 Go helper。
3. SwiftUI 能启动 / 停止 helper。
4. helper 提供 `/health` Admin API。

交付：

```text
菜单栏 App 能显示 helper running / stopped。
```

### Phase 1：本地 DoH Server

目标：

1. Go helper 启动 HTTPS Server。
2. 支持 `/dns-query` POST。
3. 暂时使用单个固定上游，例如阿里 DoH。
4. Chrome 能配置本地地址并解析域名。

交付：

```text
Chrome → https://localhost:8053/dns-query → AliDNS DoH → 返回 DNS 结果
```

### Phase 2：证书管理

目标：

1. 生成 Root CA。
2. 生成 localhost cert。
3. 安装 Root CA 到 System Keychain。
4. UI 显示证书状态。
5. 支持卸载。

交付：

```text
用户无需手动 openssl，App 可引导完成本地证书信任。
```

### Phase 3：DNS Chain

目标：

1. 实现配置文件。
2. 实现 system / doh / plain_dns 三类 upstream。
3. 实现 Chain Resolver。
4. 实现默认预设。

交付：

```text
按默认 Chain 依次解析，异常时回落。
```

### Phase 4：UI Chain 编辑

目标：

1. Chain 列表展示。
2. 拖拽排序。
3. 添加预设。
4. 手动添加 DoH。
5. 手动添加普通 DNS。
6. 启用 / 禁用 / 删除。
7. 测试上游。

交付：

```text
用户可以在 UI 中管理 DNS Chain。
```

### Phase 5：回落条件与拦截识别

目标：

1. 实现 fallback_when。
2. 实现 blocked IP / CNAME。
3. 实现 protected suffix。
4. 实现检测拦截页功能。

交付：

```text
公司 DNS 返回拦截 IP 时，自动回落到下一个 DNS。
```

### Phase 6：日志与稳定性

目标：

1. 实现查询日志。
2. UI 展示日志。
3. 错误提示。
4. 性能优化。
5. 缓存。

交付：

```text
用户可以看到每个域名的解析路径和 fallback 原因。
```

### Phase 7：打包与发布

目标：

1. 打包 App。
2. 签名。
3. Notarization。
4. README。
5. Chrome 配置文档。
6. 卸载文档。

---

## 25. 给 Codex 的实现要求

开发时请遵循：

1. 先做可运行闭环，再优化 UI。
2. 所有网络 timeout 必须可配置，不能无限等待。
3. 所有本地服务只监听 `127.0.0.1`，不要监听 `0.0.0.0`。
4. 不要打包任何 Root CA 私钥。
5. 证书必须每台机器本地生成。
6. 默认不启用国外 DNS。
7. 默认不对 NXDOMAIN fallback。
8. 默认开启内网域名保护。
9. 所有配置变更必须可回滚。
10. 日志默认只保存在本机。
11. 不要上传遥测。
12. 不要修改系统 DNS。
13. 不要安装 Network Extension。

---

## 26. 参考资料

- RFC 8484: DNS Queries over HTTPS  
  https://www.rfc-editor.org/rfc/rfc8484.html

- Chromium DNS over HTTPS documentation  
  https://www.chromium.org/developers/dns-over-https/

- Google Public DNS DoH  
  https://developers.google.com/speed/public-dns/docs/doh

- Cloudflare DNS over HTTPS  
  https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/

- Alibaba Cloud DNS over HTTPS  
  https://www.alibabacloud.com/help/en/dns/httpdns-dns-over-https-doh

- DNSPod Public DNS Access Guide  
  https://docs.dnspod.com/public-dns/public-dns-guide/

- Apple SwiftUI MenuBarExtra  
  https://developer.apple.com/documentation/SwiftUI/MenuBarExtra

- Apple SMAppService  
  https://developer.apple.com/documentation/servicemanagement/smappservice
