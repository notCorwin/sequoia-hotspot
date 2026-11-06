import Foundation
import Network

@MainActor final class NetworkObserver {
    var changed: ((Bool) -> Void)?
    private var monitor: NWPathMonitor?
    private var generation: UInt = 0

    func start() {
        stop()
        let token = generation
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.changed?(available)
            }
        }
        monitor.start(queue: DispatchQueue(label: "local.sequoia-hotspot.network", qos: .utility))
    }

    func stop() {
        generation &+= 1
        monitor?.cancel()
        monitor = nil
    }
}
