import Foundation

public struct HotspotDevice: Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct Credentials: Sendable {
    public let ssid: String
    public let password: String
    public init(ssid: String, password: String) { self.ssid = ssid; self.password = password }
}

@MainActor public protocol HotspotDiscovery: AnyObject {
    var devicesChanged: (([HotspotDevice]) -> Void)? { get set }
    func start() throws
    func stop()
    func activate(_ device: HotspotDevice) async throws -> Credentials
}

@MainActor public protocol HotspotJoining: AnyObject {
    func join(_ credentials: Credentials) async throws
    func cancel()
}

public struct HotspotFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

@MainActor public final class HotspotController {
    public private(set) var status = "正在读取网络状态…"
    public private(set) var browsing = false
    public private(set) var busy = false
    public private(set) var enabled = false
    public var canRetry: Bool { enabled && available == false && !busy }
    public var changed: (() -> Void)?
    private let discovery: any HotspotDiscovery
    private let joiner: any HotspotJoining
    private var available: Bool?
    private var devices: [HotspotDevice] = []
    private var attempted: Set<String> = []
    private var operation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation: UInt = 0
    private let activationTimeout: Duration
    private let joiningTimeout: Duration
    private let confirmationTimeout: Duration

    public init(discovery: any HotspotDiscovery, joiner: any HotspotJoining,
                activationTimeout: Duration = .seconds(30), joiningTimeout: Duration = .seconds(45),
                confirmationTimeout: Duration = .seconds(20)) {
        self.discovery = discovery
        self.joiner = joiner
        self.activationTimeout = activationTimeout
        self.joiningTimeout = joiningTimeout
        self.confirmationTimeout = confirmationTimeout
        discovery.devicesChanged = { [weak self] in self?.received($0) }
    }

    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        reset()
        reconcile()
    }

    public func networkAvailable(_ value: Bool) {
        guard available != value else { return }
        available = value
        reset()
        reconcile()
    }

    public func suspend() {
        available = nil
        reset()
        publish(enabled ? "系统休眠，已暂停监听" : "自动连接已暂停")
    }

    public func retry() {
        guard canRetry else { return }
        guard browsing else { reconcile(); return }
        attempted.removeAll()
        publish("正在等待热点设备…")
        tryNext()
    }

    private func publish(_ message: String) {
        status = message
        changed?()
    }

    private func reset() {
        generation &+= 1
        operation?.cancel()
        operation = nil
        deadline?.cancel()
        deadline = nil
        browsing = false
        discovery.stop()
        joiner.cancel()
        busy = false
        devices = []
        attempted = []
    }

    private func reconcile() {
        guard enabled else { publish("自动连接已暂停"); return }
        guard let available else { publish("正在读取网络状态…"); return }
        guard !available else { publish("网络可用"); return }
        do {
            browsing = true
            try discovery.start()
            if !busy { publish("网络已断开，等待同账户设备…") }
        } catch {
            browsing = false
            discovery.stop()
            publish(error.localizedDescription)
        }
    }

    private func received(_ devices: [HotspotDevice]) {
        guard browsing else { return }
        self.devices = devices
        attempted.formIntersection(Set(devices.map(\.id)))
        tryNext()
    }

    private func armDeadline(_ duration: Duration, token: UInt, message: String) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, generation == token else { return }
            fail(message, token: token)
        }
    }

    private func fail(_ message: String, token: UInt) {
        guard generation == token else { return }
        generation &+= 1
        operation?.cancel()
        operation = nil
        deadline?.cancel()
        deadline = nil
        joiner.cancel()
        busy = false
        publish(message)
        tryNext()
    }

    private func tryNext() {
        guard browsing, !busy,
              let device = devices.sorted(by: { $0.id < $1.id }).first(where: { !attempted.contains($0.id) }) else { return }
        attempted.insert(device.id)
        busy = true
        generation &+= 1
        let token = generation
        publish("正在唤起 \(device.name) 的热点…")
        armDeadline(activationTimeout, token: token,
                    message: "唤起热点超时；请确认设备在附近、蓝牙和蜂窝网络已开启，然后重试。")
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let credentials = try await discovery.activate(device)
                guard !Task.isCancelled, generation == token, browsing else { return }
                publish("正在连接 \(device.name)…")
                armDeadline(joiningTimeout, token: token,
                            message: "连接超时；请确认 Wi‑Fi 已开启，并检查设备的蜂窝网络，然后重试。")
                try await joiner.join(credentials)
                guard !Task.isCancelled, generation == token else { return }
                publish("已请求加入热点，等待系统确认网络…")
                armDeadline(confirmationTimeout, token: token,
                            message: "热点连接后网络仍不可用；请检查设备的蜂窝网络，然后重试。")
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                fail(error.localizedDescription, token: token)
            }
        }
    }
}
