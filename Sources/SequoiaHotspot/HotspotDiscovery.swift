import Foundation
import HotspotCore
import ObjectiveC

// Runtime objects are only inspected on the main actor. XPC callbacks merely
// transfer retained references to it; credentials are never logged or persisted.
private struct RuntimeTransfer: @unchecked Sendable {
    let first: AnyObject?
    let second: AnyObject?
}

@MainActor final class RemoteHotspotDiscovery: NSObject, HotspotDiscovery {
    var devicesChanged: (([HotspotDevice]) -> Void)?
    private var session: NSObject?
    private var devices: [String: NSObject] = [:]
    private var requests: [UUID: CheckedContinuation<Credentials, any Error>] = [:]
    private static let framework = dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW)

    func start() throws {
        guard session == nil else { return }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15,
              Self.framework != nil,
              let type = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else {
            throw HotspotFailure("当前系统不支持热点接口；此版本仅支持 macOS Sequoia 15。")
        }
        let object = type.init()
        for name in ["setDelegate:", "startBrowsing", "stopBrowsing", "enableHotspotForDevice:withCompletionHandler:"] {
            guard object.responds(to: NSSelectorFromString(name)) else {
                throw HotspotFailure("系统热点接口已变化，无法自动连接；请更新应用或手动连接热点。")
            }
        }
        session = object
        object.perform(NSSelectorFromString("setDelegate:"), with: self)
        object.perform(NSSelectorFromString("startBrowsing"))
    }

    func stop() {
        if let object = session {
            session = nil
            object.perform(NSSelectorFromString("stopBrowsing"))
            object.perform(NSSelectorFromString("setDelegate:"), with: nil)
        }
        devices = [:]
        let pending = requests.values
        requests = [:]
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }

    @objc(session:updatedFoundDevices:)
    nonisolated func session(_ session: NSObject, updatedFoundDevices objects: NSArray) {
        let transfer = RuntimeTransfer(first: session, second: objects)
        Task { @MainActor [weak self] in
            guard let self, let current = self.session, current === transfer.first,
                  let objects = transfer.second as? [NSObject] else { return }
            var payloads: [String: NSObject] = [:]
            var found: [HotspotDevice] = []
            for object in objects {
                guard object.responds(to: NSSelectorFromString("deviceIdentifier")),
                      object.responds(to: NSSelectorFromString("deviceName")),
                      let rawID = object.value(forKey: "deviceIdentifier"),
                      let name = object.value(forKey: "deviceName") as? String, !name.isEmpty else { continue }
                let id: String
                if let string = rawID as? String { id = string }
                else if let uuid = rawID as? UUID { id = uuid.uuidString }
                else { continue }
                guard !id.isEmpty, payloads[id] == nil else { continue }
                payloads[id] = object
                found.append(HotspotDevice(id: id, name: name))
            }
            self.devices = payloads
            self.devicesChanged?(found)
        }
    }

    func activate(_ device: HotspotDevice) async throws -> Credentials {
        guard let session, let payload = devices[device.id] else {
            throw HotspotFailure("热点设备已离开；请将设备移近后重试。")
        }
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                requests[requestID] = continuation
                let reply: @convention(block) (AnyObject?, AnyObject?) -> Void = { [weak self] first, second in
                    let transfer = RuntimeTransfer(first: first, second: second)
                    Task { @MainActor [weak self] in
                        guard let continuation = self?.requests.removeValue(forKey: requestID) else { return }
                        if let ssid = transfer.first as? String, !ssid.isEmpty,
                           let password = transfer.second as? String, !password.isEmpty {
                            continuation.resume(returning: Credentials(ssid: ssid, password: password))
                        } else {
                            continuation.resume(throwing: HotspotFailure("无法唤起热点；请检查同一 Apple 账户、蓝牙和蜂窝网络，然后重试。"))
                        }
                    }
                }
                typealias Activate = @convention(c) (AnyObject, Selector, AnyObject, @convention(block) (AnyObject?, AnyObject?) -> Void) -> Void
                let selector = NSSelectorFromString("enableHotspotForDevice:withCompletionHandler:")
                let activate = unsafeBitCast(session.method(for: selector), to: Activate.self)
                activate(session, selector, payload, reply)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.requests.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
            }
        }
    }
}
