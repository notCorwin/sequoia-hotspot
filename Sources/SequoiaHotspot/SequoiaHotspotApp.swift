import AppKit
import HotspotCore
import ServiceManagement

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = HotspotController(discovery: RemoteHotspotDiscovery(), joiner: WiFiJoiner())
    private let network = NetworkObserver()
    private var statusItem: NSStatusItem!
    private let statusIcon = StatusIconView()
    private let menu = NSMenu()
    private let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggle = NSMenuItem(title: "自动连接热点", action: #selector(toggleEnabled), keyEquivalent: "")
    private let retry = NSMenuItem(title: "重试连接", action: #selector(retryConnection), keyEquivalent: "")
    private let login = NSMenuItem(title: "随登录自动启动", action: #selector(toggleLogin), keyEquivalent: "")
    private let approval = NSMenuItem(title: "在系统设置中允许开机启动…", action: #selector(openLoginSettings), keyEquivalent: "")
    private var loginFailure: String?
    private var updatingLogin = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "SequoiaHotspot.StatusItem"
        statusItem.button?.window?.title = "SequoiaHotspot.StatusItem"
        if let button = statusItem.button {
            statusIcon.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(statusIcon)
            NSLayoutConstraint.activate([
                statusIcon.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                statusIcon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                statusIcon.widthAnchor.constraint(equalToConstant: 18),
                statusIcon.heightAnchor.constraint(equalToConstant: 18),
            ])
        }
        menu.autoenablesItems = false
        menu.delegate = self
        let title = NSMenuItem(title: "Sequoia Hotspot", action: nil, keyEquivalent: "")
        title.isEnabled = false
        status.isEnabled = false
        menu.addItem(title)
        menu.addItem(status)
        menu.addItem(.separator())
        for item in [toggle, retry, login, approval] { item.target = self; menu.addItem(item) }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Sequoia Hotspot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
        controller.changed = { [weak self] in self?.render() }
        network.changed = { [weak self] in self?.controller.networkAvailable($0) }
        let enabled = UserDefaults.standard.object(forKey: "automaticConnection") as? Bool ?? true
        controller.setEnabled(enabled)
        network.start()
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        notifications.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        notifications.addObserver(self, selector: #selector(accessibilityDisplayChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        renderLogin()
    }

    func applicationWillTerminate(_ notification: Notification) {
        network.stop()
        controller.setEnabled(false)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func willSleep() { network.stop(); controller.suspend() }
    @objc private func didWake() { network.start() }
    @objc private func accessibilityDisplayChanged() { render() }
    @objc private func toggleEnabled() {
        let enabled = !controller.enabled
        UserDefaults.standard.set(enabled, forKey: "automaticConnection")
        controller.setEnabled(enabled)
    }
    @objc private func retryConnection() { controller.retry() }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func render() {
        statusIcon.update(isOffline: controller.isOffline,
                          reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        status.title = controller.status
        status.toolTip = controller.status
        statusItem.button?.toolTip = "Sequoia Hotspot\n\(controller.status)"
        statusItem.button?.setAccessibilityLabel("Sequoia Hotspot：\(controller.status)")
        toggle.state = controller.enabled ? .on : .off
        retry.isEnabled = controller.canRetry
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusIcon.setEmphasized(true)
        renderLogin()
    }

    func menuDidClose(_ menu: NSMenu) { statusIcon.setEmphasized(false) }

    private func renderLogin() {
        let state = SMAppService.mainApp.status
        login.state = state == .enabled ? .on : .off
        login.title = loginFailure != nil ? "开机启动更改失败，重试" : (state == .requiresApproval ? "随登录自动启动：等待允许" : "随登录自动启动")
        login.toolTip = loginFailure
        login.isEnabled = !updatingLogin
        approval.isHidden = state != .requiresApproval
    }

    @objc private func toggleLogin() {
        guard !updatingLogin else { return }
        loginFailure = nil
        let service = SMAppService.mainApp
        if service.status == .enabled || service.status == .requiresApproval {
            updatingLogin = true
            renderLogin()
            Task {
                do { try await service.unregister() }
                catch { loginFailure = "无法关闭开机启动；请在系统设置的登录项中检查。" }
                updatingLogin = false
                renderLogin()
            }
        } else {
            do { try service.register() }
            catch { loginFailure = "无法开启开机启动；请将应用放入“应用程序”文件夹，并检查系统设置的登录项。" }
            renderLogin()
        }
    }
}

@main struct SequoiaHotspotApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--check-interface") {
            // Headless, read-only discovery smoke check; never activates or joins.
            let discovery = RemoteHotspotDiscovery()
            var count = 0
            discovery.devicesChanged = { count = $0.count }
            do {
                try discovery.start()
                let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
                    CFRunLoopStop(CFRunLoopGetMain())
                }
                withExtendedLifetime(timer) { CFRunLoopRun() }
                discovery.stop()
                print("Sequoia hotspot interface OK; discovered devices: \(count). No activation or connection attempted.")
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
