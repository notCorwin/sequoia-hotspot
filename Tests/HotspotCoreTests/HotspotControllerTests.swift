// Standalone checks run with the Command Line Tools; Xcode/XCTest is not required.
import Foundation
import HotspotCore

@MainActor private final class Discovery: HotspotDiscovery {
    var devicesChanged: (([HotspotDevice]) -> Void)?
    var starts = 0
    var requested: [String] = []
    var pending: [CheckedContinuation<Credentials, any Error>] = []
    var startError: HotspotFailure?
    func start() throws { starts += 1; if let startError { throw startError } }
    func stop() {}
    func activate(_ device: HotspotDevice) async throws -> Credentials {
        requested.append(device.id)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func emit(_ ids: [String]) { devicesChanged?(ids.map { .init(id: $0, name: $0) }) }
    func finish(_ result: Result<Credentials, any Error> = .success(.init(ssid: "test", password: "test"))) {
        pending.removeFirst().resume(with: result)
    }
}

@MainActor private final class Joiner: HotspotJoining {
    var powerRequests = 0
    var powerFailure: HotspotFailure?
    var joins = 0
    var failure: HotspotFailure?
    var hang = false
    var pending: [CheckedContinuation<Void, any Error>] = []
    func enableWiFi() throws {
        powerRequests += 1
        if let powerFailure { throw powerFailure }
    }
    func join(_ credentials: Credentials) async throws {
        joins += 1
        if let failure { throw failure }
        if hang { try await withCheckedThrowingContinuation { pending.append($0) } }
    }
    // Deliberately allow late completion, as real external callbacks may arrive
    // after cancellation. The controller must independently reject them.
    func cancel() {}
    func finish() { pending.removeFirst().resume() }
}

@MainActor final class HotspotControllerTests {
    @MainActor private func waitFor(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        expect(predicate(), file: file, line: line)
    }

    @MainActor func testOfflineStartupAndRecoveryOnlyBrowseWhenNeeded() async throws {
        let discovery = Discovery(), joiner = Joiner()
        let controller = HotspotController(discovery: discovery, joiner: joiner)
        controller.setEnabled(true)
        expectFalse(controller.canRetry)
        expectEqual(joiner.powerRequests, 0)
        expectEqual(discovery.starts, 0)
        controller.networkAvailable(true)
        expectEqual(discovery.starts, 0)
        expectEqual(joiner.powerRequests, 0)
        controller.networkAvailable(false)
        controller.networkAvailable(false)
        expectEqual(discovery.starts, 1)
        expectEqual(joiner.powerRequests, 1)
        discovery.emit(["phone"])
        try await waitFor { discovery.requested.count == 1 }
        discovery.finish()
        try await waitFor { joiner.joins == 1 }
        expect(controller.busy) // A successful command is not network confirmation.
        controller.networkAvailable(true)
        expectFalse(controller.browsing)
        expectFalse(controller.busy)
        expectEqual(controller.status, "网络可用")
        controller.setEnabled(false)
    }

    @MainActor func testRecoveryDiscardsLateActivationCredentials() async throws {
        let discovery = Discovery(), joiner = Joiner()
        let controller = HotspotController(discovery: discovery, joiner: joiner)
        controller.setEnabled(true)
        controller.networkAvailable(false)
        discovery.emit(["phone"])
        try await waitFor { discovery.requested.count == 1 }
        controller.networkAvailable(true)
        discovery.finish()
        // Give the cancelled activation task a chance to resume.
        try await Task.sleep(for: .milliseconds(10))
        expectEqual(joiner.joins, 0)
        expectEqual(controller.status, "网络可用")
    }

    @MainActor func testRepeatedUpdatesDoNotRetryButReappearanceDoes() async throws {
        let discovery = Discovery(), joiner = Joiner()
        let controller = HotspotController(discovery: discovery, joiner: joiner)
        controller.setEnabled(true)
        controller.networkAvailable(false)
        discovery.emit(["phone"])
        try await waitFor { discovery.requested.count == 1 }
        discovery.emit(["phone"])
        discovery.finish(.failure(HotspotFailure("activation failed")))
        try await waitFor { !controller.busy }
        discovery.emit(["phone"])
        expectFalse(controller.busy)
        expectEqual(discovery.requested.count, 1)
        discovery.emit([])
        discovery.emit(["phone"])
        try await waitFor { discovery.requested.count == 2 }
        controller.setEnabled(false)
        discovery.finish()
    }

    @MainActor func testFailureTriesOtherDeviceAndManualRetryStartsNewAttempt() async throws {
        let discovery = Discovery(), joiner = Joiner()
        joiner.failure = HotspotFailure("join failed")
        let controller = HotspotController(discovery: discovery, joiner: joiner)
        controller.setEnabled(true)
        controller.networkAvailable(false)
        discovery.emit(["b", "a"])
        try await waitFor { discovery.requested == ["a"] }
        discovery.finish()
        try await waitFor { discovery.requested == ["a", "b"] }
        discovery.finish()
        try await waitFor { !controller.busy }
        expectEqual(controller.status, "join failed")
        controller.retry()
        try await waitFor { discovery.requested == ["a", "b", "a"] }
        controller.setEnabled(false)
        discovery.finish()
    }

    @MainActor func testPauseAndSleepSuppressCallbacksAndWakeRechecksNetwork() async throws {
        let discovery = Discovery(), joiner = Joiner()
        let controller = HotspotController(discovery: discovery, joiner: joiner)
        controller.setEnabled(true)
        controller.networkAvailable(false)
        controller.suspend()
        discovery.emit(["phone"])
        expectFalse(controller.browsing)
        expect(discovery.requested.isEmpty)
        controller.networkAvailable(false)
        expectEqual(discovery.starts, 2)
        controller.setEnabled(false)
        discovery.emit(["phone"])
        expectFalse(controller.browsing)
        expect(discovery.requested.isEmpty)
        controller.networkAvailable(true)
        expectEqual(controller.status, "自动连接已暂停")
    }

    @MainActor func testActivationTimeoutReleasesBusyStateAndIgnoresLateReply() async throws {
        let discovery = Discovery(), joiner = Joiner()
        let controller = HotspotController(discovery: discovery, joiner: joiner, activationTimeout: .milliseconds(20))
        controller.setEnabled(true)
        controller.networkAvailable(false)
        discovery.emit(["phone"])
        try await waitFor { discovery.requested.count == 1 }
        try await waitFor { !controller.busy }
        expect(controller.status.contains("超时"))
        discovery.finish()
        try await Task.sleep(for: .milliseconds(10))
        expectEqual(joiner.joins, 0)
        controller.setEnabled(false)
    }

    @MainActor func testMissingNetworkConfirmationFailsInsteadOfReportingConnected() async throws {
        let discovery = Discovery(), joiner = Joiner()
        let controller = HotspotController(discovery: discovery, joiner: joiner, confirmationTimeout: .milliseconds(20))
        controller.setEnabled(true)
        controller.networkAvailable(false)
        discovery.emit(["phone"])
        try await waitFor { discovery.requested.count == 1 }
        discovery.finish()
        try await waitFor { joiner.joins == 1 && !controller.busy }
        expect(controller.status.contains("仍不可用"))
        controller.setEnabled(false)
    }

    @MainActor func testJoiningTimeoutIgnoresLateCommandCompletion() async throws {
        let discovery = Discovery(), joiner = Joiner()
        joiner.hang = true
        let controller = HotspotController(discovery: discovery, joiner: joiner, joiningTimeout: .milliseconds(20))
        controller.setEnabled(true)
        controller.networkAvailable(false)
        discovery.emit(["phone"])
        try await waitFor { discovery.requested.count == 1 }
        discovery.finish()
        try await waitFor { joiner.joins == 1 && !controller.busy }
        expect(controller.status.contains("连接超时"))
        expect(controller.canRetry)
        let failure = controller.status
        joiner.finish()
        try await Task.sleep(for: .milliseconds(10))
        expectEqual(controller.status, failure)
        controller.setEnabled(false)
    }

    @MainActor func testRecoveryWhileJoiningIgnoresLateCommandCompletion() async throws {
        let discovery = Discovery(), joiner = Joiner()
        joiner.hang = true
        let controller = HotspotController(discovery: discovery, joiner: joiner)
        controller.setEnabled(true)
        controller.networkAvailable(false)
        discovery.emit(["phone"])
        try await waitFor { discovery.requested.count == 1 }
        discovery.finish()
        try await waitFor { joiner.joins == 1 }
        controller.networkAvailable(true)
        expectFalse(controller.busy)
        expectFalse(controller.canRetry)
        joiner.finish()
        try await Task.sleep(for: .milliseconds(10))
        expectEqual(controller.status, "网络可用")
        expectFalse(controller.browsing)
    }

    @MainActor func testUnsupportedInterfaceCanBeRetriedWithoutPretendingToBrowse() {
        let discovery = Discovery(), joiner = Joiner()
        discovery.startError = HotspotFailure("unsupported")
        let controller = HotspotController(discovery: discovery, joiner: joiner)
        controller.setEnabled(true)
        controller.networkAvailable(false)
        expectFalse(controller.browsing)
        expectEqual(controller.status, "unsupported")
        discovery.startError = nil
        controller.retry()
        expect(controller.browsing)
        controller.setEnabled(false)
    }

    @MainActor func testWiFiPowerFailureStopsDiscoveryAndRetryEnablesWiFi() {
        let discovery = Discovery(), joiner = Joiner()
        let controller = HotspotController(discovery: discovery, joiner: joiner)
        joiner.powerFailure = HotspotFailure("无法自动开启 Wi‑Fi")
        controller.setEnabled(true)
        controller.networkAvailable(false)
        expectEqual(joiner.powerRequests, 1)
        expectEqual(discovery.starts, 0)
        expectFalse(controller.browsing)
        expect(controller.canRetry)
        expectEqual(controller.status, "无法自动开启 Wi‑Fi")
        joiner.powerFailure = nil
        controller.retry()
        expectEqual(joiner.powerRequests, 2)
        expectEqual(discovery.starts, 1)
        expect(controller.browsing)
        controller.setEnabled(false)
    }

    @MainActor func testOfflineWhilePausedDoesNotEnableWiFiUntilResumed() {
        let discovery = Discovery(), joiner = Joiner()
        let controller = HotspotController(discovery: discovery, joiner: joiner)
        controller.networkAvailable(false)
        expectEqual(joiner.powerRequests, 0)
        expectEqual(discovery.starts, 0)
        controller.setEnabled(true)
        expectEqual(joiner.powerRequests, 1)
        expectEqual(discovery.starts, 1)
        controller.setEnabled(false)
        expectEqual(joiner.powerRequests, 1)
    }
}

private func expect(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !condition { fatalError("Expectation failed", file: (file), line: line) }
}
private func expectFalse(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
    expect(!condition, file: file, line: line)
}
private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    expect(actual == expected, file: file, line: line)
}

@main struct HotspotCoreChecks {
    @MainActor static func main() async throws {
        let tests = HotspotControllerTests()
        try await tests.testOfflineStartupAndRecoveryOnlyBrowseWhenNeeded()
        try await tests.testRecoveryDiscardsLateActivationCredentials()
        try await tests.testRepeatedUpdatesDoNotRetryButReappearanceDoes()
        try await tests.testFailureTriesOtherDeviceAndManualRetryStartsNewAttempt()
        try await tests.testPauseAndSleepSuppressCallbacksAndWakeRechecksNetwork()
        try await tests.testActivationTimeoutReleasesBusyStateAndIgnoresLateReply()
        try await tests.testMissingNetworkConfirmationFailsInsteadOfReportingConnected()
        try await tests.testJoiningTimeoutIgnoresLateCommandCompletion()
        try await tests.testRecoveryWhileJoiningIgnoresLateCommandCompletion()
        tests.testUnsupportedInterfaceCanBeRetriedWithoutPretendingToBrowse()
        tests.testWiFiPowerFailureStopsDiscoveryAndRetryEnablesWiFi()
        tests.testOfflineWhilePausedDoesNotEnableWiFiUntilResumed()
        print("12 hotspot behavior checks passed.")
    }
}
