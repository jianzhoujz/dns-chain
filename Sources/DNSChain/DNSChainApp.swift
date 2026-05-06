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

    let font = NSFont(name: "Apple Color Emoji", size: 15) ?? NSFont.systemFont(ofSize: 15)
    let text = NSAttributedString(string: "🐙", attributes: [.font: font])
    let textSize = text.size()
    text.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2 + 1))
    image.unlockFocus()

    if !isRunning {
        return grayscaleMenuBarImage(from: image, size: size)
    }
    return image
}

private func grayscaleMenuBarImage(from image: NSImage, size: NSSize) -> NSImage {
    guard let data = image.tiffRepresentation,
          let input = CIImage(data: data),
          let filter = CIFilter(name: "CIColorControls") else {
        return image
    }
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(0, forKey: kCIInputSaturationKey)
    filter.setValue(-0.12, forKey: kCIInputBrightnessKey)
    filter.setValue(0.82, forKey: kCIInputContrastKey)

    guard let output = filter.outputImage,
          let cgImage = CIContext().createCGImage(output, from: input.extent) else {
        return image
    }
    return NSImage(cgImage: cgImage, size: size)
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
        installMainMenu()
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

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 DNSChain", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu

        NSApplication.shared.mainMenu = mainMenu
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
    @Published var systemBypassText = ""
    @Published var launchAtLoginEnabled = false
    @Published var updateCheckInProgress = false

    private let store = ConfigStore()
    private let certificateManager = CertificateManager()
    private let loginItemManager = LoginItemManager.shared
    private var resolver: ChainResolver?
    private var server: LocalDoHServer?
    private var logRefreshTask: Task<Void, Never>?

    init() {
        do {
            config = try store.loadOrCreateDefault()
            launchAtLoginEnabled = loginItemManager.isEnabled()
            certificateState = certificateManager.state()
            resolver = ChainResolver(config: config)
            refreshConfigText()
            refreshSystemBypassText()
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

    var configURL: URL {
        store.configURL
    }

    var systemBypassURL: URL {
        SystemBypassStore.defaultFileURL()
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

    func saveConfig() {
        do {
            try store.save(config)
            Task {
                await resolver?.updateConfig(config)
            }
            refreshConfigText()
            refreshSystemBypassText()
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
            refreshSystemBypassText()
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
            statusMessage = enabled ? "已开启开机启动" : "已关闭开机启动"
        } catch {
            launchAtLoginEnabled = loginItemManager.isEnabled()
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

    func openSystemBypassInEditor() {
        do {
            try ensureSystemBypassFileExists()
            refreshSystemBypassText()
            NSWorkspace.shared.open(systemBypassURL)
            statusMessage = "已打开 System Bypass 文件"
        } catch {
            statusMessage = "打开 System Bypass 失败：\(String(describing: error))"
        }
    }

    func revealSystemBypassInFinder() {
        do {
            try ensureSystemBypassFileExists()
            NSWorkspace.shared.activateFileViewerSelecting([systemBypassURL])
            statusMessage = "已显示 System Bypass 文件"
        } catch {
            statusMessage = "显示 System Bypass 失败：\(String(describing: error))"
        }
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

    private func refreshSystemBypassText() {
        systemBypassText = (try? String(contentsOf: systemBypassURL, encoding: .utf8)) ?? ""
    }

    private func ensureSystemBypassFileExists() throws {
        let directory = systemBypassURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: systemBypassURL.path) {
            try "".write(to: systemBypassURL, atomically: true, encoding: .utf8)
        }
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
                    self.refreshSystemBypassText()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
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
        window.addTitlebarAccessoryViewController(makeQuitAccessory())
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

    private func makeQuitAccessory() -> NSTitlebarAccessoryViewController {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 38, height: 28))
        let button = NSButton(image: titlebarQuitImage(), target: self, action: #selector(quitApp))
        button.isBordered = false
        button.controlSize = .regular
        button.imagePosition = .imageOnly
        button.toolTip = "退出 DNSChain (⌘Q)"
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        container.addSubview(button)

        let controller = NSTitlebarAccessoryViewController()
        controller.view = container
        controller.layoutAttribute = .right
        return controller
    }

    private func titlebarQuitImage() -> NSImage {
        let image = NSImage(systemSymbolName: "power", accessibilityDescription: "退出 DNSChain") ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 13, height: 13)
        return image
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

struct SettingsRootView: View {
    @EnvironmentObject var model: DNSChainAppModel

    var body: some View {
        TabView {
            StatusSettingsView()
                .tabItem { Label("DNS Chain", systemImage: "list.number") }
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
    @State private var showsSystemBypass = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    serviceSection
                    certificateSection
                    fallbackSection
                    configFileSection
                    systemBypassSection
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
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                    GridRow {
                        fallbackToggle("请求超时", isOn: $model.config.fallbackWhen.timeout)
                        fallbackToggle("网络错误", isOn: $model.config.fallbackWhen.networkError)
                    }
                    GridRow {
                        fallbackToggle("SERVFAIL", isOn: $model.config.fallbackWhen.servfail)
                        fallbackToggle("REFUSED", isOn: $model.config.fallbackWhen.refused)
                    }
                    GridRow {
                        fallbackToggle("返回空结果", isOn: $model.config.fallbackWhen.emptyAnswer)
                        fallbackToggle("NXDOMAIN", isOn: $model.config.fallbackWhen.nxdomain)
                    }
                    GridRow {
                        fallbackToggle("拦截 IP", isOn: $model.config.fallbackWhen.blockedIP)
                        fallbackToggle("拦截 CNAME", isOn: $model.config.fallbackWhen.blockedCNAME)
                    }
                    GridRow {
                        fallbackToggle("非法响应", isOn: $model.config.fallbackWhen.invalidResponse)
                        Color.clear.frame(width: 160, height: 1)
                    }
                }
                Text("拦截 IP/CNAME 后缀在配置 JSON 中维护；命中 system DNS 拦截的查询会写入 system-bypass.txt。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(4)
        }
    }

    private func fallbackToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .frame(width: 160, alignment: .leading)
    }

    private var appSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionHeader(title: "应用", systemImage: "app.badge")
                    Spacer()
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

    private var systemBypassSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: "System Bypass", systemImage: "forward.end")
                    Spacer()
                    Button("编辑", systemImage: "square.and.pencil") {
                        model.openSystemBypassInEditor()
                    }
                    Button("显示", systemImage: "folder") {
                        model.revealSystemBypassInFinder()
                    }
                    Button("复制", systemImage: "doc.on.doc") {
                        model.copy(model.systemBypassText, status: "已复制 System Bypass")
                    }
                }
                Text(model.systemBypassURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("一行一个域名；命中该域名或其子域名时跳过 system DNS。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button(showsSystemBypass ? "隐藏当前列表" : "查看当前列表", systemImage: showsSystemBypass ? "chevron.down" : "chevron.right") {
                    showsSystemBypass.toggle()
                }
                .buttonStyle(.plain)
                if showsSystemBypass {
                    ScrollView {
                        Text(model.systemBypassText.isEmpty ? "System Bypass 文件为空或尚未生成。" : model.systemBypassText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    .frame(maxHeight: 120)
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
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
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

struct LogSettingsView: View {
    @EnvironmentObject var model: DNSChainAppModel
    private static let tableWidth: CGFloat = 1720
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        SettingsPage(title: "日志", subtitle: "最近的 DNS 查询、尝试链、最终上游和响应状态。") {
            HStack(spacing: 12) {
                Text("\(model.logs.count) 条")
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                RCodeLegendView()
                Spacer()
                Button("复制全部日志", systemImage: "doc.on.doc") {
                    model.copyLogs()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            GeometryReader { geometry in
                let tableWidth = max(Self.tableWidth, geometry.size.width)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        logHeader
                            .frame(width: tableWidth, alignment: .leading)

                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if model.logs.isEmpty {
                                    Text("暂无查询日志")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 12)
                                        .frame(width: tableWidth, alignment: .leading)
                                } else {
                                    ForEach(Array(model.logs.enumerated()), id: \.element.id) { index, log in
                                        LogTableRow(log: log, timestamp: formatter.string(from: log.timestamp), isAlternate: index.isMultiple(of: 2))
                                            .frame(width: tableWidth, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: tableWidth, height: geometry.size.height, alignment: .topLeading)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
            )
            .frame(minHeight: 460, maxHeight: .infinity)
        }
    }

    private var logHeader: some View {
        HStack(spacing: 10) {
            LogColumnHeader("时间", width: 92)
            LogColumnHeader("域名", width: 230)
            LogColumnHeader("类型", width: 52)
            LogColumnHeader("结果", width: 78)
            LogColumnHeader("最终上游", width: 136)
            LogColumnHeader("RCODE", width: 78)
            LogColumnHeader("尝试链", width: 500)
            LogColumnHeader("答案", width: 360)
            LogColumnHeader("客户端", width: 94)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct LogTableRow: View {
    let log: QueryLog
    let timestamp: String
    let isAlternate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                LogCell(timestamp, width: 92, monospaced: true)
                LogCell(log.domain, width: 230, weight: .medium)
                LogCell(dnsQTypeLabel(log.qtype), width: 52, monospaced: true)
                LogStatusText(log.result.rawValue, color: queryResultColor(log.result), width: 78)
                LogCell(log.finalUpstream ?? "-", width: 136)
                LogStatusText(rcodeLabel(log.rcode), color: rcodeColor(log.rcode), width: 78)
                attemptChain
                    .frame(width: 500, alignment: .leading)
                    .clipped()
                LogCell(answerSummary(log.answers), width: 360)
                LogCell(log.client, width: 94, monospaced: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isAlternate ? Color(nsColor: .controlBackgroundColor).opacity(0.38) : Color.clear)

            Divider()
        }
    }

    private var attemptChain: some View {
        HStack(spacing: 6) {
            if log.attempts.isEmpty {
                Text("cache")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                ForEach(Array(log.attempts.enumerated()), id: \.offset) { index, attempt in
                    Text(compactAttemptLabel(attempt, index: index))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(attemptStatusColor(attempt.status))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(attemptStatusColor(attempt.status).opacity(0.11), in: Capsule())
                        .textSelection(.enabled)
                        .help(attemptLabel(attempt, index: index))
                }
            }
        }
    }

    private func compactAttemptLabel(_ attempt: AttemptLog, index: Int) -> String {
        "\(index + 1).\(shortUpstreamName(attempt.upstreamName)) \(shortAttemptStatus(attempt.status)) \(attempt.latencyMs)ms"
    }

    private func attemptLabel(_ attempt: AttemptLog, index: Int) -> String {
        let detail = attempt.detail.map { " \($0)" } ?? ""
        return "#\(index + 1) \(attempt.upstreamName) \(attempt.status.rawValue) \(attempt.latencyMs)ms\(detail)"
    }

    private func shortUpstreamName(_ name: String) -> String {
        guard name.count > 14 else { return name }
        return String(name.prefix(11)) + "..."
    }

    private func answerSummary(_ answers: [DNSAnswer]) -> String {
        guard !answers.isEmpty else { return "-" }
        return answers
            .prefix(3)
            .map { "\(dnsQTypeLabel($0.rawType)) \($0.value) TTL \($0.ttl)" }
            .joined(separator: " | ") + (answers.count > 3 ? " | +\(answers.count - 3)" : "")
    }
}

struct RCodeLegendView: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                RCodeLegendItem(code: "NOERROR", meaning: "正常", color: .green)
                RCodeLegendItem(code: "NXDOMAIN", meaning: "域名不存在", color: .orange)
                RCodeLegendItem(code: "SERVFAIL", meaning: "上游失败", color: .red)
                RCodeLegendItem(code: "REFUSED", meaning: "拒绝", color: .red)
                RCodeLegendItem(code: "FORMERR", meaning: "格式错误", color: .red)
                RCodeLegendItem(code: "NOTIMP", meaning: "未支持", color: .purple)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

struct RCodeLegendItem: View {
    let code: String
    let meaning: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(code)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(color)
            Text(meaning)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.1), in: Capsule())
        .help("\(code)：\(meaning)")
    }
}

struct LogColumnHeader: View {
    let title: String
    let width: CGFloat

    init(_ title: String, width: CGFloat) {
        self.title = title
        self.width = width
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }
}

struct LogCell: View {
    let text: String
    let width: CGFloat
    let monospaced: Bool
    let weight: Font.Weight?

    init(_ text: String, width: CGFloat, monospaced: Bool = false, weight: Font.Weight? = nil) {
        self.text = text
        self.width = width
        self.monospaced = monospaced
        self.weight = weight
    }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(width: width, alignment: .leading)
    }

    private var font: Font {
        if monospaced {
            return .system(.caption, design: .monospaced)
        }
        if let weight {
            return .system(.body, design: .default).weight(weight)
        }
        return .body
    }
}

struct LogStatusText: View {
    let text: String
    let color: Color
    let width: CGFloat

    init(_ text: String, color: Color, width: CGFloat) {
        self.text = text
        self.color = color
        self.width = width
    }

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .textSelection(.enabled)
            .frame(width: width, alignment: .leading)
    }
}

private func queryResultColor(_ result: QueryResult) -> Color {
    switch result {
    case .success:
        return .green
    case .fallback:
        return .orange
    case .failed:
        return .red
    case .protected:
        return .blue
    case .cached:
        return .secondary
    }
}

private func attemptStatusColor(_ status: AttemptStatus) -> Color {
    switch status {
    case .success:
        return .green
    case .timeout, .networkError, .servfail, .refused, .invalidResponse:
        return .red
    case .nxdomain, .emptyAnswer:
        return .orange
    case .blockedIP, .blockedCNAME:
        return .purple
    case .protected, .skippedSystem:
        return .blue
    }
}

private func shortAttemptStatus(_ status: AttemptStatus) -> String {
    switch status {
    case .success:
        return "ok"
    case .timeout:
        return "timeout"
    case .networkError:
        return "net"
    case .servfail:
        return "sfail"
    case .refused:
        return "refused"
    case .nxdomain:
        return "nx"
    case .emptyAnswer:
        return "empty"
    case .blockedIP:
        return "block-ip"
    case .blockedCNAME:
        return "block-cn"
    case .protected:
        return "protect"
    case .skippedSystem:
        return "skip-sys"
    case .invalidResponse:
        return "invalid"
    }
}

private func rcodeLabel(_ rcode: DNSRCode?) -> String {
    guard let rcode else { return "-" }
    switch rcode {
    case .noError:
        return "NOERROR"
    case .formErr:
        return "FORMERR"
    case .servFail:
        return "SERVFAIL"
    case .nxDomain:
        return "NXDOMAIN"
    case .notImp:
        return "NOTIMP"
    case .refused:
        return "REFUSED"
    case .other:
        return "RCODE \(rcode.rawValue)"
    }
}

private func rcodeColor(_ rcode: DNSRCode?) -> Color {
    switch rcode {
    case .noError:
        return .green
    case .formErr, .servFail, .refused, .other:
        return .red
    case .nxDomain:
        return .orange
    case .notImp:
        return .purple
    case nil:
        return .secondary
    }
}
