// Standalone checks run with the Command Line Tools; Xcode/XCTest is not required.
import Foundation
import HotspotCore

@MainActor private final class Discovery: HotspotDiscovery {
    var devicesChanged: (([HotspotDevice]) -> Void)?
    var starts = 0
    var requested: [String] = []
    var pending: [CheckedContinuation<Credentials, any Error>] = []
    var startError: HotspotFailure?
    var automaticDevices: [String]?
    func start() throws {
        starts += 1
        if let startError { throw startError }
        if let automaticDevices { emit(automaticDevices) }
    }
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

    @MainActor func testOfflineIndicatorTracksNetworkWhilePausedAndResetsForSleep() {
        let controller = HotspotController(discovery: Discovery(), joiner: Joiner())
        expectFalse(controller.isOffline) // Unknown is not a confirmed disconnection.
        controller.networkAvailable(false)
        expect(controller.isOffline) // Pausing auto-connect does not hide a disconnection.
        controller.setEnabled(true)
        expect(controller.isOffline)
        controller.setEnabled(false)
        expect(controller.isOffline)
        controller.suspend()
        expectFalse(controller.isOffline)
        controller.networkAvailable(false)
        expect(controller.isOffline)
        controller.networkAvailable(true)
        expectFalse(controller.isOffline)
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

    @MainActor func testAllErrorsKeepRetryingWithFreshDiscovery() async throws {
        let discovery = Discovery(), joiner = Joiner()
        discovery.automaticDevices = ["phone"]
        let controller = HotspotController(discovery: discovery, joiner: joiner, retryInterval: .milliseconds(20))
        controller.setEnabled(true)
        controller.networkAvailable(false)
        // A persistent error must neither exhaust attempts nor require disappearance.
        for attempt in 1...4 {
            try await waitFor { discovery.requested.count == attempt }
            discovery.finish(.failure(NSError(domain: NSPOSIXErrorDomain, code: 45)))
        }
        try await waitFor { discovery.requested.count == 5 }
        expectEqual(discovery.starts, 5)
        controller.setEnabled(false)
        discovery.finish()
    }

    @MainActor func testDiscoveryAndPowerErrorsRetryUntilRecovery() async throws {
        let discovery = Discovery(), joiner = Joiner()
        let controller = HotspotController(discovery: discovery, joiner: joiner, retryInterval: .milliseconds(20))
        joiner.powerFailure = HotspotFailure("power failed")
        controller.setEnabled(true)
        controller.networkAvailable(false)
        try await waitFor { joiner.powerRequests >= 3 }
        expectEqual(discovery.starts, 0)
        discovery.startError = HotspotFailure("unsupported")
        joiner.powerFailure = nil
        try await waitFor { discovery.starts >= 3 }
        expectFalse(controller.browsing)
        discovery.startError = nil
        discovery.automaticDevices = ["phone"]
        try await waitFor { discovery.requested.count == 1 }
        discovery.finish()
        try await waitFor { joiner.joins == 1 }
        controller.networkAvailable(true)
    }

    @MainActor func testEveryConnectionFailureStageRetries() async throws {
        // Activation deadline, join failure, join deadline, network confirmation deadline.
        for stage in 0..<4 {
            let discovery = Discovery(), joiner = Joiner()
            discovery.automaticDevices = ["phone"]
            if stage == 1 { joiner.failure = HotspotFailure("join failed") }
            if stage == 2 { joiner.hang = true }
            let controller = HotspotController(discovery: discovery, joiner: joiner,
                activationTimeout: stage == 0 ? .milliseconds(20) : .seconds(1),
                joiningTimeout: .milliseconds(20), confirmationTimeout: .milliseconds(20),
                retryInterval: .milliseconds(20))
            controller.setEnabled(true)
            controller.networkAvailable(false)
            try await waitFor { discovery.requested.count == 1 }
            if stage != 0 { discovery.finish() }
            try await waitFor { discovery.requested.count == 2 }
            expectEqual(discovery.starts, 2)
            controller.setEnabled(false)
            while !discovery.pending.isEmpty { discovery.finish() }
            while !joiner.pending.isEmpty { joiner.finish() }
        }
    }

    @MainActor func testRetryWaitCannotBeBypassedAndStopsForPauseSleepOrRecovery() async throws {
        for transition in 0..<3 {
            let discovery = Discovery(), joiner = Joiner()
            let controller = HotspotController(discovery: discovery, joiner: joiner, retryInterval: .milliseconds(40))
            controller.setEnabled(true)
            controller.networkAvailable(false)
            discovery.emit(["phone"])
            try await waitFor { discovery.requested.count == 1 }
            discovery.finish(.failure(HotspotFailure("failed")))
            try await waitFor { !controller.busy }
            discovery.emit([])
            discovery.emit(["phone"])
            expectFalse(controller.busy)
            switch transition {
            case 0: controller.setEnabled(false)
            case 1: controller.suspend()
            default: controller.networkAvailable(true)
            }
            let status = controller.status
            try await Task.sleep(for: .milliseconds(70))
            expectEqual(discovery.starts, 1)
            expectEqual(discovery.requested.count, 1)
            expectEqual(controller.status, status)
            controller.setEnabled(false)
        }
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
        expect(controller.status.contains("join failed"))
        controller.retry()
        expectEqual(discovery.starts, 2)
        discovery.emit(["a", "b"])
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
        expect(controller.status.contains("unsupported"))
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
        expect(controller.status.contains("无法自动开启 Wi‑Fi"))
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
        tests.testOfflineIndicatorTracksNetworkWhilePausedAndResetsForSleep()
        try await tests.testOfflineStartupAndRecoveryOnlyBrowseWhenNeeded()
        try await tests.testRecoveryDiscardsLateActivationCredentials()
        try await tests.testAllErrorsKeepRetryingWithFreshDiscovery()
        try await tests.testDiscoveryAndPowerErrorsRetryUntilRecovery()
        try await tests.testEveryConnectionFailureStageRetries()
        try await tests.testRetryWaitCannotBeBypassedAndStopsForPauseSleepOrRecovery()
        try await tests.testFailureTriesOtherDeviceAndManualRetryStartsNewAttempt()
        try await tests.testPauseAndSleepSuppressCallbacksAndWakeRechecksNetwork()
        try await tests.testActivationTimeoutReleasesBusyStateAndIgnoresLateReply()
        try await tests.testMissingNetworkConfirmationFailsInsteadOfReportingConnected()
        try await tests.testJoiningTimeoutIgnoresLateCommandCompletion()
        try await tests.testRecoveryWhileJoiningIgnoresLateCommandCompletion()
        tests.testUnsupportedInterfaceCanBeRetriedWithoutPretendingToBrowse()
        tests.testWiFiPowerFailureStopsDiscoveryAndRetryEnablesWiFi()
        tests.testOfflineWhilePausedDoesNotEnableWiFiUntilResumed()
        print("16 hotspot behavior checks passed.")
    }
}
