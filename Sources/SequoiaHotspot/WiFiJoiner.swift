import Darwin
import CoreWLAN
import Foundation
import HotspotCore

@MainActor final class WiFiJoiner: HotspotJoining {
    private var process: Process?
    private var pending: CheckedContinuation<Void, any Error>?
    private var requestID: UUID?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminationDeadline: Task<Void, Never>?


    func cancel() {
        let continuation = pending
        pending = nil
        continuation?.resume(throwing: CancellationError())
        guard let task = process, task.isRunning else { return }
        task.terminate()
        // terminate() is asynchronous. Retain the process until its exit callback
        // so another device cannot launch a competing networksetup operation.
        guard terminationDeadline == nil else { return }
        terminationDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, process === task, task.isRunning else { return }
            kill(task.processIdentifier, SIGKILL)
        }
    }

    private func waitForPreviousExit() async {
        guard process != nil else { return }
        await withCheckedContinuation { exitWaiters.append($0) }
    }

    private func didExit() {
        terminationDeadline?.cancel()
        terminationDeadline = nil
        process = nil
        requestID = nil
        let waiters = exitWaiters
        exitWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func join(_ credentials: Credentials) async throws {
        await waitForPreviousExit()
        try Task.checkCancellation()
        guard let interface = CWWiFiClient.shared().interface(), let name = interface.interfaceName else {
            throw HotspotFailure("找不到 Wi‑Fi 接口；请确认此 Mac 支持 Wi‑Fi。")
        }
        guard interface.powerOn() else {
            throw HotspotFailure("Wi‑Fi 已关闭；请开启 Wi‑Fi，然后点击重试。")
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task = Process()
                let output = Pipe()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                // No shell. networksetup may store credentials in the system keychain;
                // its arguments are visible to local process inspection while running.
                task.arguments = ["-setairportnetwork", name, credentials.ssid, credentials.password]
                task.standardOutput = output
                task.standardError = output
                task.standardInput = FileHandle.nullDevice
                task.terminationHandler = { [weak self] task in
                    // networksetup can exit 0 while printing a failure. Never expose
                    // its output: it could contain credential or network information.
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8)
                    let succeeded = task.terminationStatus == 0 && text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == id else { return }
                        let completion = self.pending
                        self.pending = nil
                        self.didExit()
                        if succeeded { completion?.resume() }
                        else { completion?.resume(throwing: HotspotFailure("加入热点失败；请确认设备在附近、Wi‑Fi 和蜂窝网络已开启，然后重试。")) }
                    }
                }
                pending = continuation
                requestID = id
                process = task
                do { try task.run() }
                catch {
                    pending = nil
                    didExit()
                    continuation.resume(throwing: HotspotFailure("无法启动系统 Wi‑Fi 连接工具；请检查系统安装。"))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.requestID == id else { return }
                self?.cancel()
            }
        }
    }
}
