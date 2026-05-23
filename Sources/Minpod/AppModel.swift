import SwiftUI
import MinpodKit

@MainActor
final class AppModel: ObservableObject {
    @Published var device: IPodDevice?
    @Published var tracks: [Track] = []
    @Published var status: String = "No iPod connected"
    @Published var isBusy = false

    private let detector = IPodDetector()

    init() {
        detector.onChange = { [weak self] devices in
            Task { @MainActor in self?.handleDevices(devices) }
        }
        detector.start()
        handleDevices(detector.currentDevices())
    }

    private func handleDevices(_ devices: [IPodDevice]) {
        let previous = device
        device = devices.first
        if let dev = device {
            if previous?.mountPoint != dev.mountPoint {
                status = "Connected: \(dev.displayName)"
                loadLibrary()
            }
        } else {
            tracks = []
            status = "No iPod connected"
        }
    }

    func loadLibrary() {
        guard let dev = device else { return }
        isBusy = true
        status = "Reading library…"
        Task.detached(priority: .userInitiated) {
            do {
                let db = try ITunesDB.read(from: dev)
                let loaded = db.tracks
                await MainActor.run {
                    self.tracks = loaded
                    self.status = "\(loaded.count) songs on \(dev.displayName)"
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.status = "Failed to read library: \(error.localizedDescription)"
                    self.isBusy = false
                }
            }
        }
    }
}
