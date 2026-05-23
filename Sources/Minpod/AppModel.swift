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

    /// Auto-sync: dropped files are copied and inserted into the iPod immediately.
    func handleDrop(urls: [URL]) {
        guard let dev = device, !isBusy else { return }
        let audio = urls.filter { AudioMetadata.supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else {
            status = "No supported audio files in drop"
            return
        }
        isBusy = true
        status = "Adding \(audio.count) file\(audio.count == 1 ? "" : "s")…"
        Task.detached(priority: .userInitiated) {
            do {
                let result = try await SyncEngine(device: dev).add(files: audio)
                await MainActor.run {
                    let n = result.added.count
                    var msg = n > 0
                        ? "Added \(n) song\(n == 1 ? "" : "s") — click Eject, then they appear on the iPod"
                        : "Nothing added"
                    if !result.skipped.isEmpty { msg += " · skipped \(result.skipped.count)" }
                    self.status = msg
                    self.isBusy = false
                    self.loadLibrary()
                }
            } catch {
                await MainActor.run {
                    self.status = "Sync failed: \(error.localizedDescription)"
                    self.isBusy = false
                }
            }
        }
    }

    func eject() {
        guard let dev = device, !isBusy else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: dev.mountPoint)
            status = "Ejected \(dev.displayName) — safe to unplug"
            device = nil
            tracks = []
        } catch {
            status = "Eject failed: \(error.localizedDescription)"
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
