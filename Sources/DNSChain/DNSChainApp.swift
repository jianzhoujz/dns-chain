import SwiftUI
import AppKit
import CoreImage
import DNSChainCore

private func dnsQTypeLabel(_ qtype: UInt16) -> String {
    switch qtype {
    case 1: return "A"
    case 5: return "CNAME"
    case 28: return "AAAA"
    case 64: return "SVCB"
    case 65: return "HTTPS"
    default: return "TYPE\(qtype)"
    }
}

private let gitHubRepository = "jianzhoujz/dns-chain"
private let gitHubURL = URL(string: "https://github.com/\(gitHubRepository)")!
private let latestReleaseURL = URL(string: "https://github.com/\(gitHubRepository)/releases/latest")!

private enum LaunchOptions {
    static let opensSettingsWindow = !CommandLine.arguments.contains("--background")
}

private func menuBarOctopusImage(isRunning: Bool) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    if !isRunning {
        NSGraphicsContext.current?.cgContext.setAlpha(0.32)
    }
    let font = NSFont(name: "Apple Color Emoji", size: 15) ?? NSFont.systemFont(ofSize: 15)
    let text = NSAttributedString(string: "🐙", attributes: [.font: font])
    let textSize = text.size()
    text.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2 + 1))
    return image
}

private struct GitHubRelease {
    let tagName: String
    let htmlURL: URL
}

private struct VersionNumber: Comparable {
    let parts: [Int]

    init(_ value: String) {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }

        let core = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        parts = core.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

@main
enum DNSChainApplication {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItemController: StatusItemController?
    private var observer: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = DNSChainAppModel.shared
        installStatusItem(model: model)
        observer = NotificationCenter.default.addObserver(
            forName: .dnsChainRunningChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.statusItemController?.updateIcon(isRunning: DNSChainAppModel.shared.isRunning)
            }
        }
        if LaunchOptions.opensSettingsWindow {
            DispatchQueue.main.async {
                SettingsWindowPresenter.shared.show(model: model)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowPresenter.shared.show(model: DNSChainAppModel.shared)
        return true
    }

    func installStatusItem(model: DNSChainAppModel) {
        if statusItemController == nil {
            statusItemController = StatusItemController(model: model)
        }
        statusItemController?.updateIcon(isRunning: model.isRunning)
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private weak var model: DNSChainAppModel?

    init(model: DNSChainAppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: 22)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(openSettings(_:))
            button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            button.alignment = .center
        }
        updateIcon(isRunning: model.isRunning)
    }

    func updateIcon(isRunning: Bool) {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = menuBarOctopusImage(isRunning: isRunning)
        button.imagePosition = .imageOnly
        button.toolTip = isRunning ? "DNSChain 运行中" : "DNSChain 已停止"
    }

    @objc private func openSettings(_ sender: NSStatusBarButton) {
        guard let model else { return }
        SettingsWindowPresenter.shared.show(model: model)
    }
}

@MainActor
final class DNSChainAppModel: ObservableObject {
    static let shared = DNSChainAppModel()

    @Published var config = DNSChainConfig()
    @Published var logs: [QueryLog] = []
    @Published var isRunning = false
    @Published var statusMessage = "正在加载配置..."
    @Published var certificateState: CertificateState = .missing
    @Published var configText = ""
    @Published var launchAtLoginEnabled = false
    @Published var updateCheckInProgress = false
    @Published var isProxyRunning = false
    @Published var proxyLogs: [ProxyRequestLog] = []
    @Published var proxyStatusMessage = "代理未启动"

    private let store = ConfigStore()
    private let certificateManager = CertificateManager()
    private let loginItemManager = LoginItemManager.shared
    private var resolver: ChainResolver?
    private var server: LocalDoHServer?
    private var logRefreshTask: Task<Void, Never>?
    private let proxyLogStore = ProxyRequestLogStore(maxEntries: 1000)
    private var proxyServer: LocalHTTPProxyServer?
    private var proxyRefreshTask: Task<Void, Never>?

    init() {
        do {
            config = try store.loadOrCreateDefault()
            launchAtLoginEnabled = loginItemManager.isEnabled()
            if config.launchAtLogin != launchAtLoginEnabled {
                config.launchAtLogin = launchAtLoginEnabled
                try? store.save(config)
            }
            certificateState = certificateManager.state()
            resolver = ChainResolver(config: config)
            refreshConfigText()
            statusMessage = "已加载配置"
            Task { @MainActor in
                self.startService()
            }
        } catch {
            statusMessage = "配置加载失败：\(error.localizedDescription)"
        }
    }

    var chromeURL: String {
        "https://localhost:\(config.server.listenPort)\(config.server.dohPath)"
    }

    var proxyURL: String {
        "\(config.proxy.listenHost):\(config.proxy.listenPort)"
    }

    var configURL: URL {
        store.configURL
    }

    var enabledUpstreamCount: Int {
        config.dnsChain.filter(\.enabled).count
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var appBuildTime: String {
        Bundle.main.object(forInfoDictionaryKey: "BuildTime") as? String ?? "-"
    }

    func startService() {
        guard !isRunning else { return }
        do {
            try certificateManager.ensureGenerated()
            certificateState = certificateManager.state()
            let resolver = resolver ?? ChainResolver(config: config)
            self.resolver = resolver
            let server = LocalDoHServer(resolver: resolver, config: config.server)
            try server.start()
            self.server = server
            isRunning = true
            statusMessage = "运行中"
            NotificationCenter.default.post(name: .dnsChainRunningChanged, object: nil)
            startLogRefresh()
        } catch {
            statusMessage = "启动失败：\(String(describing: error))"
            isRunning = false
            NotificationCenter.default.post(name: .dnsChainRunningChanged, object: nil)
        }
    }

    func stopService() {
        server?.stop()
        server = nil
        isRunning = false
        statusMessage = "已停止"
        NotificationCenter.default.post(name: .dnsChainRunningChanged, object: nil)
        logRefreshTask?.cancel()
    }

    func startProxy() {
        guard !isProxyRunning else { return }
        do {
            let server = LocalHTTPProxyServer(config: config.proxy, logs: proxyLogStore)
            try server.start()
            proxyServer = server
            isProxyRunning = true
            proxyStatusMessage = "代理运行中"
            startProxyLogRefresh()
        } catch {
            isProxyRunning = false
            proxyStatusMessage = "代理启动失败：\(String(describing: error))"
        }
    }

    func stopProxy() {
        proxyServer?.stop()
        proxyServer = nil
        isProxyRunning = false
        proxyStatusMessage = "代理已停止"
        proxyRefreshTask?.cancel()
    }

    func applySystemProxy() {
        do {
            try setSystemProxy(enabled: true)
            proxyStatusMessage = "已写入系统代理"
        } catch {
            proxyStatusMessage = "写入系统代理失败：\(error.localizedDescription)"
        }
    }

    func clearSystemProxy() {
        do {
            try setSystemProxy(enabled: false)
            proxyStatusMessage = "已关闭系统代理"
        } catch {
            proxyStatusMessage = "关闭系统代理失败：\(error.localizedDescription)"
        }
    }

    func saveConfig() {
        do {
            config.launchAtLogin = launchAtLoginEnabled
            try store.save(config)
            Task {
                await resolver?.updateConfig(config)
            }
            refreshConfigText()
            statusMessage = "配置已保存"
        } catch {
            statusMessage = "保存失败：\(String(describing: error))"
        }
    }

    func reloadConfigFromDisk() {
        do {
            config = try store.loadOrCreateDefault()
            launchAtLoginEnabled = loginItemManager.isEnabled()
            resolver = ChainResolver(config: config)
            refreshConfigText()
            statusMessage = "配置已重新加载"
            if isRunning {
                stopService()
                startService()
            }
        } catch {
            statusMessage = "配置重新加载失败：\(String(describing: error))"
        }
    }

    func resetDefaultChain() {
        config.dnsChain = PresetLibrary.defaultChain
        saveConfig()
    }

    func generateCertificates() {
        do {
            try certificateManager.ensureGenerated()
            certificateState = certificateManager.state()
            statusMessage = "证书已生成"
        } catch {
            statusMessage = "证书生成失败：\(String(describing: error))"
        }
    }

    func installCertificate() {
        statusMessage = "正在安装当前用户信任证书..."
        do {
            try certificateManager.installRootCertificate()
            certificateState = certificateManager.state()
            statusMessage = "证书已安装"
        } catch {
            statusMessage = "证书安装失败：\(String(describing: error))"
        }
    }

    func uninstallCertificate() {
        statusMessage = "正在移除当前用户信任证书..."
        do {
            try certificateManager.uninstallRootCertificate()
            certificateState = certificateManager.state()
            statusMessage = "证书已移除"
        } catch {
            statusMessage = "证书移除失败：\(String(describing: error))"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItemManager.setEnabled(enabled)
            launchAtLoginEnabled = enabled
            config.launchAtLogin = enabled
            try store.save(config)
            refreshConfigText()
            statusMessage = enabled ? "已开启开机启动" : "已关闭开机启动"
        } catch {
            launchAtLoginEnabled = loginItemManager.isEnabled()
            config.launchAtLogin = launchAtLoginEnabled
            statusMessage = "开机启动设置失败：\(String(describing: error))"
        }
    }

    func openConfigInEditor() {
        do {
            try store.save(config)
            refreshConfigText()
            NSWorkspace.shared.open(configURL)
            statusMessage = "已打开配置文件"
        } catch {
            statusMessage = "打开配置失败：\(String(describing: error))"
        }
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    func copyStatus() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(statusMessage, forType: .string)
    }

    func copy(_ value: String, status: String = "已复制") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        statusMessage = status
    }

    func copyLogs() {
        let lines = logs.map { log in
            let attempts = log.attempts.map { "\($0.upstreamName):\($0.status.rawValue):\($0.latencyMs)ms" }.joined(separator: "|")
            let answers = log.answers.map { "\($0.name):\($0.rawType):\($0.value):ttl=\($0.ttl)" }.joined(separator: "|")
            return [
                ISO8601DateFormatter().string(from: log.timestamp),
                log.domain,
                dnsQTypeLabel(log.qtype),
                log.result.rawValue,
                log.finalUpstream ?? "-",
                log.rcode?.rawValue.description ?? "-",
                attempts,
                answers
            ].joined(separator: "\t")
        }
        copy(lines.joined(separator: "\n"), status: "已复制日志")
    }

    func copyChromeURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chromeURL, forType: .string)
        statusMessage = "已复制 Chrome 地址"
    }

    func openGitHub() {
        NSWorkspace.shared.open(gitHubURL)
    }

    func checkForUpdates() {
        guard !updateCheckInProgress else { return }

        updateCheckInProgress = true
        statusMessage = "正在检查更新..."

        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = "HEAD"
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("DNSChain/\(appVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            Task { @MainActor in
                self?.finishUpdateCheck(response: response, error: error)
            }
        }.resume()
    }

    func test(_ upstream: DNSUpstreamConfig) {
        statusMessage = "正在测试 \(upstream.name)..."
        Task {
            do {
                let attempt = try await resolver?.testUpstream(upstream)
                await MainActor.run {
                    statusMessage = "\(upstream.name)：\(attempt?.status.rawValue ?? "unknown")"
                }
            } catch {
                await MainActor.run {
                    statusMessage = "\(upstream.name) 测试失败：\(String(describing: error))"
                }
            }
        }
    }

    private func refreshConfigText() {
        configText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    }

    private func finishUpdateCheck(response: URLResponse?, error: Error?) {
        updateCheckInProgress = false

        if let error {
            statusMessage = "检查更新失败：\(error.localizedDescription)"
            showMessage(title: "检查更新失败", message: error.localizedDescription)
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            statusMessage = "检查更新失败：没有收到 GitHub 的有效响应"
            showMessage(title: "检查更新失败", message: "没有收到 GitHub 的有效响应。")
            return
        }

        if httpResponse.statusCode == 404 {
            statusMessage = "暂无可用更新"
            showMessage(title: "暂无可用更新", message: "GitHub 上还没有可用的正式 Release。")
            return
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            statusMessage = "检查更新失败：HTTP \(httpResponse.statusCode)"
            showMessage(title: "检查更新失败", message: "GitHub 返回 HTTP \(httpResponse.statusCode)。")
            return
        }

        guard let release = latestRelease(from: httpResponse) else {
            statusMessage = "检查更新失败：无法识别最新版本"
            showMessage(title: "检查更新失败", message: "无法识别 GitHub 最新 Release 版本。")
            return
        }

        if VersionNumber(appVersion) < VersionNumber(release.tagName) {
            statusMessage = "发现新版本 \(release.tagName)"
            showUpdateAvailable(release)
        } else {
            statusMessage = "已是最新版本"
            showMessage(title: "已是最新版本", message: "DNSChain 当前版本为 \(appVersion)。")
        }
    }

    private func latestRelease(from response: HTTPURLResponse) -> GitHubRelease? {
        guard let finalURL = response.url else { return nil }
        let pathComponents = finalURL.pathComponents
        guard let tagIndex = pathComponents.firstIndex(of: "tag"),
              tagIndex + 1 < pathComponents.count else {
            return nil
        }

        let tagName = pathComponents[tagIndex + 1].removingPercentEncoding ?? pathComponents[tagIndex + 1]
        guard !tagName.isEmpty else { return nil }
        return GitHubRelease(tagName: tagName, htmlURL: finalURL)
    }

    private func showUpdateAvailable(_ release: GitHubRelease) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 \(release.tagName)"
        alert.informativeText = "DNSChain 当前版本为 \(appVersion)。是否打开 GitHub Releases 下载更新？"
        alert.addButton(withTitle: "打开下载页")
        alert.addButton(withTitle: "稍后")

        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")

        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func startLogRefresh() {
        logRefreshTask?.cancel()
        logRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let entries = await self.resolver?.recentLogs(limit: 100) ?? []
                await MainActor.run {
                    self.logs = entries
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func startProxyLogRefresh() {
        proxyRefreshTask?.cancel()
        proxyRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let entries = await self.proxyLogStore.recent(limit: 200)
                await MainActor.run {
                    self.proxyLogs = entries
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }

    private func setSystemProxy(enabled: Bool) throws {
        let services = try networkServices()
        guard !services.isEmpty else {
            throw NSError(domain: "DNSChainProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有找到可配置的网络服务"])
        }

        for service in services {
            if enabled {
                try runNetworksetup(["-setwebproxy", service, config.proxy.listenHost, String(config.proxy.listenPort)])
                try runNetworksetup(["-setsecurewebproxy", service, config.proxy.listenHost, String(config.proxy.listenPort)])
                try runNetworksetup(["-setwebproxystate", service, "on"])
                try runNetworksetup(["-setsecurewebproxystate", service, "on"])
            } else {
                try runNetworksetup(["-setwebproxystate", service, "off"])
                try runNetworksetup(["-setsecurewebproxystate", service, "off"])
            }
        }
    }

    private func networkServices() throws -> [String] {
        let output = try runNetworksetup(["-listallnetworkservices"])
        return output
            .split(separator: "\n")
            .dropFirst()
            .map(String.init)
            .filter { !$0.hasPrefix("*") && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    @discardableResult
    private func runNetworksetup(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DNSChainProxy", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return output
    }
}

extension Notification.Name {
    static let dnsChainRunningChanged = Notification.Name("DNSChainRunningChanged")
}

struct StatusBadge: View {
    let text: String
    let isActive: Bool

    var body: some View {
        Label(text, systemImage: isActive ? "checkmark.circle.fill" : "pause.circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(isActive ? .green : .secondary)
    }
}

@MainActor
final class SettingsWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowPresenter()

    private var window: NSWindow?

    func show(model: DNSChainAppModel) {
        if let window {
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                window.level = .normal
            }
            return
        }

        let content = SettingsRootView()
            .environmentObject(model)
            .frame(minWidth: 920, minHeight: 640)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DNSChain 设置"
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.delegate = self
        self.window = window
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            window.level = .normal
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
        }
    }
}

struct SettingsRootView: View {
    @EnvironmentObject var model: DNSChainAppModel

    var body: some View {
        TabView {
            StatusSettingsView()
                .tabItem { Label("DNS Chain", systemImage: "list.number") }
            ProxySettingsView()
                .tabItem { Label("代理", systemImage: "arrow.left.arrow.right") }
            LogSettingsView()
                .tabItem { Label("日志", systemImage: "doc.text.magnifyingglass") }
        }
        .padding(18)
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 21, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct StatusSettingsView: View {
    @EnvironmentObject var model: DNSChainAppModel
    @State private var showsConfigJSON = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    serviceSection
                    certificateSection
                    fallbackSection
                    configFileSection
                    appSection
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(width: 430)

            chainSection
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var serviceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionHeader(title: "本地 DoH", systemImage: "network")
                    Spacer()
                    StatusBadge(text: model.isRunning ? "运行中" : "已停止", isActive: model.isRunning)
                    Button(model.isRunning ? "停止" : "启动", systemImage: model.isRunning ? "pause.fill" : "play.fill") {
                        model.isRunning ? model.stopService() : model.startService()
                    }
                }
                HStack(spacing: 8) {
                    Text("地址")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .leading)
                    Text(model.chromeURL)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Button("复制", systemImage: "doc.on.doc") {
                        model.copy(model.chromeURL, status: "已复制本地地址")
                    }
                    .labelStyle(.iconOnly)
                }
                HStack(spacing: 22) {
                    Toggle("缓存", isOn: $model.config.cache.enabled)
                    Toggle("开机启动", isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                }
            }
            .padding(4)
        }
    }

    private var certificateSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionHeader(title: "证书", systemImage: "lock.shield")
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button("生成/修复", systemImage: "wrench.and.screwdriver") {
                        model.generateCertificates()
                    }
                    Button("安装信任", systemImage: "lock.shield") {
                        model.installCertificate()
                    }
                    Button("移除信任", systemImage: "trash") {
                        model.uninstallCertificate()
                    }
                    CertificateBadge(state: model.certificateState)
                }
                Text("Root CA 和 localhost 证书保存在当前用户目录；安装信任只写当前用户 Trust Settings。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(4)
        }
    }

    private var fallbackSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionHeader(title: "回落", systemImage: "arrow.triangle.branch")
                    Spacer()
                    Button("应用", systemImage: "checkmark.circle") {
                        model.saveConfig()
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    GridRow {
                        Toggle("请求超时", isOn: $model.config.fallbackWhen.timeout)
                        Toggle("网络错误", isOn: $model.config.fallbackWhen.networkError)
                        Toggle("SERVFAIL", isOn: $model.config.fallbackWhen.servfail)
                        Toggle("REFUSED", isOn: $model.config.fallbackWhen.refused)
                    }
                    GridRow {
                        Toggle("返回空结果", isOn: $model.config.fallbackWhen.emptyAnswer)
                        Toggle("NXDOMAIN", isOn: $model.config.fallbackWhen.nxdomain)
                        Toggle("命中拦截 IP", isOn: $model.config.fallbackWhen.blockedIP)
                        Toggle("命中拦截 CNAME", isOn: $model.config.fallbackWhen.blockedCNAME)
                    }
                }
                Text("拦截 IP/CNAME 后缀在下方配置 JSON 中维护。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(4)
        }
    }

    private var appSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionHeader(title: "应用", systemImage: "app.badge")
                    Spacer()
                    Button("退出", systemImage: "power") {
                        NSApplication.shared.terminate(nil)
                    }
                }
                HStack(spacing: 8) {
                    Text("版本")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                    Text(model.appVersion)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Text("构建")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                    Text(model.appBuildTime)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Button(model.updateCheckInProgress ? "正在检查更新..." : "检查更新", systemImage: "arrow.down.circle") {
                        model.checkForUpdates()
                    }
                    .disabled(model.updateCheckInProgress)
                    Button("GitHub 主页", systemImage: "link") {
                        model.openGitHub()
                    }
                }
            }
            .padding(4)
        }
    }

    private var chainSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionHeader(title: "DNS Chain", systemImage: "list.number")
                    Spacer()
                    Button("恢复默认", systemImage: "arrow.counterclockwise") {
                        model.resetDefaultChain()
                    }
                    Button("应用", systemImage: "checkmark.circle") {
                        model.saveConfig()
                    }
                }
                List {
                    ForEach($model.config.dnsChain) { $upstream in
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary)
                            Toggle("", isOn: $upstream.enabled)
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 3) {
                                Text(upstream.name)
                                    .font(.body.weight(.medium))
                                Text(detail(for: upstream))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("复制", systemImage: "doc.on.doc") {
                                model.copy(detail(for: upstream), status: "已复制上游信息")
                            }
                            .labelStyle(.iconOnly)
                            Button("测试", systemImage: "checkmark.seal") {
                                model.test(upstream)
                            }
                            .labelStyle(.iconOnly)
                        }
                        .padding(.vertical, 3)
                    }
                    .onMove { indices, newOffset in
                        model.config.dnsChain.move(fromOffsets: indices, toOffset: newOffset)
                        model.saveConfig()
                    }
                    .onDelete { offsets in
                        model.config.dnsChain.remove(atOffsets: offsets)
                        model.saveConfig()
                    }
                }
                .frame(minHeight: 480, maxHeight: .infinity)
            }
            .padding(4)
        }
        .frame(maxHeight: .infinity)
    }

    private var configFileSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: "配置文件", systemImage: "curlybraces.square")
                    Spacer()
                    Button("编辑", systemImage: "square.and.pencil") {
                        model.openConfigInEditor()
                    }
                    Button("显示", systemImage: "folder") {
                        model.revealConfigInFinder()
                    }
                    Button("复制", systemImage: "doc.on.doc") {
                        model.copy(model.configText, status: "已复制配置 JSON")
                    }
                }
                Text(model.configURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button(showsConfigJSON ? "隐藏当前 JSON" : "查看当前 JSON", systemImage: showsConfigJSON ? "chevron.down" : "chevron.right") {
                    showsConfigJSON.toggle()
                }
                .buttonStyle(.plain)
                if showsConfigJSON {
                    ScrollView {
                        Text(model.configText.isEmpty ? "配置文件为空或尚未生成。" : model.configText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    .frame(maxHeight: 150)
                }
            }
            .padding(4)
        }
    }

    private func detail(for upstream: DNSUpstreamConfig) -> String {
        switch upstream.type {
        case .system:
            return "macOS system resolver"
        case .doh:
            return upstream.url?.absoluteString ?? "DoH"
        case .plainDNS:
            return (upstream.servers ?? []).joined(separator: ", ")
        }
    }

}

struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 14, weight: .semibold))
    }
}

struct CertificateBadge: View {
    let state: CertificateState

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .textSelection(.enabled)
    }

    private var text: String {
        switch state {
        case .trusted:
            return "证书正常"
        case .present:
            return "未信任"
        case .missing:
            return "未生成"
        }
    }

    private var icon: String {
        switch state {
        case .trusted:
            return "checkmark.seal.fill"
        case .present:
            return "exclamationmark.triangle.fill"
        case .missing:
            return "questionmark.circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .trusted:
            return .green
        case .present:
            return .orange
        case .missing:
            return .secondary
        }
    }
}

struct InfoTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ChainSettingsView: View {
    @EnvironmentObject var model: DNSChainAppModel

    var body: some View {
        SettingsPage(title: "DNSChain 与配置", subtitle: "按顺序尝试启用的上游；JSON 配置可查看并用系统编辑器修改。") {
            List {
                ForEach($model.config.dnsChain) { $upstream in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                        Toggle("", isOn: $upstream.enabled)
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(upstream.name)
                                .font(.body.weight(.medium))
                            Text(detail(for: upstream))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("复制", systemImage: "doc.on.doc") {
                            model.copy(detail(for: upstream), status: "已复制上游信息")
                        }
                        .labelStyle(.iconOnly)
                        Button("测试", systemImage: "checkmark.seal") {
                            model.test(upstream)
                        }
                        .labelStyle(.iconOnly)
                    }
                    .padding(.vertical, 4)
                }
                .onMove { indices, newOffset in
                    model.config.dnsChain.move(fromOffsets: indices, toOffset: newOffset)
                    model.saveConfig()
                }
                .onDelete { offsets in
                    model.config.dnsChain.remove(atOffsets: offsets)
                    model.saveConfig()
                }
            }
            .frame(minHeight: 360)

            HStack {
                Button("恢复默认 Chain", systemImage: "arrow.counterclockwise") {
                    model.resetDefaultChain()
                }
                Button("应用 Chain 修改", systemImage: "checkmark.circle") {
                    model.saveConfig()
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("配置文件") {
                        Text(model.configURL.path)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button("复制", systemImage: "doc.on.doc") {
                            model.copy(model.configURL.path, status: "已复制配置路径")
                        }
                        .labelStyle(.iconOnly)
                    }
                    HStack {
                        Button("用系统编辑器打开", systemImage: "square.and.pencil") {
                            model.openConfigInEditor()
                        }
                        Button("在 Finder 中显示", systemImage: "folder") {
                            model.revealConfigInFinder()
                        }
                        Button("复制 JSON", systemImage: "doc.on.doc") {
                            model.copy(model.configText, status: "已复制配置 JSON")
                        }
                    }
                    DisclosureGroup("查看当前 JSON") {
                        ScrollView {
                            Text(model.configText.isEmpty ? "配置文件为空或尚未生成。" : model.configText)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                        .frame(maxHeight: 180)
                    }
                }
                .padding(6)
            }
        }
    }

    private func detail(for upstream: DNSUpstreamConfig) -> String {
        switch upstream.type {
        case .system:
            return "macOS system resolver"
        case .doh:
            return upstream.url?.absoluteString ?? "DoH"
        case .plainDNS:
            return (upstream.servers ?? []).joined(separator: ", ")
        }
    }
}

struct ProxySettingsView: View {
    @EnvironmentObject var model: DNSChainAppModel
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        SettingsPage(title: "代理", subtitle: "启动一个本地 HTTP/HTTPS 代理入口，并可写入 macOS 系统代理。") {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionHeader(title: "本地代理", systemImage: "arrow.left.arrow.right")
                            Spacer()
                            StatusBadge(text: model.isProxyRunning ? "运行中" : "已停止", isActive: model.isProxyRunning)
                            Button(model.isProxyRunning ? "停止" : "启动", systemImage: model.isProxyRunning ? "pause.fill" : "play.fill") {
                                model.isProxyRunning ? model.stopProxy() : model.startProxy()
                            }
                        }
                        HStack(spacing: 8) {
                            Text("地址")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .leading)
                            Text(model.proxyURL)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Button("复制", systemImage: "doc.on.doc") {
                                model.copy(model.proxyURL, status: "已复制代理地址")
                            }
                            .labelStyle(.iconOnly)
                            Spacer()
                            Button("写入系统代理", systemImage: "network") {
                                model.applySystemProxy()
                            }
                            Button("关闭系统代理", systemImage: "network.slash") {
                                model.clearSystemProxy()
                            }
                        }
                        Text(model.proxyStatusMessage)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(4)
                }

                HStack {
                    Text("请求")
                        .font(.headline)
                    Text("\(model.proxyLogs.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                List(model.proxyLogs) { log in
                    HStack(spacing: 10) {
                        Text(formatter.string(from: log.timestamp))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 94, alignment: .leading)
                            .textSelection(.enabled)
                        Text(log.method)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 74, alignment: .leading)
                            .textSelection(.enabled)
                        Text("\(log.targetHost):\(log.targetPort)")
                            .font(.body.weight(.medium))
                            .frame(minWidth: 220, alignment: .leading)
                            .textSelection(.enabled)
                        Text(log.status.rawValue)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 90, alignment: .leading)
                            .textSelection(.enabled)
                        Text("↑\(formatBytes(log.bytesUp)) ↓\(formatBytes(log.bytesDown))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .leading)
                            .textSelection(.enabled)
                        Text(log.detail ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
                .frame(minHeight: 360)
            }
        }
    }

    private func formatBytes(_ value: Int) -> String {
        if value >= 1024 * 1024 {
            return String(format: "%.1fMB", Double(value) / 1024 / 1024)
        }
        if value >= 1024 {
            return String(format: "%.1fKB", Double(value) / 1024)
        }
        return "\(value)B"
    }
}

struct LogSettingsView: View {
    @EnvironmentObject var model: DNSChainAppModel
    @State private var expandedLogIDs: Set<UUID> = []
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        SettingsPage(title: "日志", subtitle: "最近的 DNS 查询、最终上游和响应状态。") {
            HStack {
                Button("复制全部日志", systemImage: "doc.on.doc") {
                    model.copyLogs()
                }
                Text("\(model.logs.count) 条")
                    .foregroundStyle(.secondary)
            }

            List {
                ForEach(model.logs) { log in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            toggle(log.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: expandedLogIDs.contains(log.id) ? "chevron.down" : "chevron.right")
                                    .foregroundStyle(.secondary)
                                Text(formatter.string(from: log.timestamp))
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(width: 95, alignment: .leading)
                                Text(log.domain)
                                    .font(.body.weight(.medium))
                                    .textSelection(.enabled)
                                    .frame(minWidth: 180, alignment: .leading)
                                Text(dnsQTypeLabel(log.qtype))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(width: 58, alignment: .leading)
                                Text(log.result.rawValue)
                                    .textSelection(.enabled)
                                    .frame(width: 72, alignment: .leading)
                                Text(log.finalUpstream ?? "-")
                                    .textSelection(.enabled)
                                    .frame(width: 110, alignment: .leading)
                                Text("RCODE \(log.rcode?.rawValue.description ?? "-")")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Spacer()
                                Text("\(log.attempts.count) 次尝试")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)

                        if expandedLogIDs.contains(log.id) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(log.attempts.enumerated()), id: \.offset) { index, attempt in
                                    HStack(spacing: 10) {
                                        Text("#\(index + 1)")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 28, alignment: .leading)
                                        Text(attempt.upstreamName)
                                            .textSelection(.enabled)
                                            .frame(width: 140, alignment: .leading)
                                        Text(attempt.status.rawValue)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(width: 110, alignment: .leading)
                                        Text("\(attempt.latencyMs)ms")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                            .frame(width: 70, alignment: .leading)
                                        Text(attempt.detail ?? "")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                        Spacer()
                                    }
                                    .padding(.leading, 24)
                                }
                                if log.attempts.isEmpty {
                                    Text("缓存命中或无上游尝试记录")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 24)
                                }
                                if !log.answers.isEmpty {
                                    Divider()
                                        .padding(.leading, 24)
                                    Text("答案")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 24)
                                    ForEach(Array(log.answers.enumerated()), id: \.offset) { _, answer in
                                        HStack(spacing: 10) {
                                            Text(dnsQTypeLabel(answer.rawType))
                                                .font(.system(.caption, design: .monospaced))
                                                .frame(width: 58, alignment: .leading)
                                            Text(answer.value)
                                                .textSelection(.enabled)
                                                .frame(width: 180, alignment: .leading)
                                            Text("TTL \(answer.ttl)")
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                            Text(answer.name)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                            Spacer()
                                        }
                                        .padding(.leading, 24)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if expandedLogIDs.contains(id) {
            expandedLogIDs.remove(id)
        } else {
            expandedLogIDs.insert(id)
        }
    }
}
