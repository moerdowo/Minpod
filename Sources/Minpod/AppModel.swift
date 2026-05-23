import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MinpodKit

@MainActor
final class AppModel: ObservableObject {
    @Published var device: IPodDevice?
    @Published var tracks: [Track] = []
    @Published var status: String = "No iPod connected"
    @Published var isBusy = false
    @Published var capacity: String = ""
    @Published var fractionUsed: Double = 0
    @Published var playlists: [ITunesDB.PlaylistInfo] = []

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
            updateCapacity()
        } else {
            tracks = []
            status = "No iPod connected"
            capacity = ""
            fractionUsed = 0
        }
    }

    func updateCapacity() {
        guard let dev = device,
              let vals = try? dev.mountPoint.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let free = vals.volumeAvailableCapacity, let total = vals.volumeTotalCapacity, total > 0 else {
            capacity = ""; fractionUsed = 0; return
        }
        let used = total - free
        fractionUsed = Double(used) / Double(total)
        let f = ByteCountFormatter()
        f.countStyle = .file
        capacity = "\(f.string(fromByteCount: Int64(free))) free of \(f.string(fromByteCount: Int64(total)))"
    }

    /// Auto-sync: dropped files are copied and inserted into the iPod immediately.
    func handleDrop(urls: [URL]) {
        guard let dev = device, !isBusy else { return }
        let fm = FileManager.default
        let candidates = urls.filter { url in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
            if isDir.boolValue { return true } // folders are expanded by the engine
            let ext = url.pathExtension.lowercased()
            return AudioMetadata.supportedExtensions.contains(ext) || AudioConverter.convertibleExtensions.contains(ext)
        }
        guard !candidates.isEmpty else {
            status = "No audio files or folders in drop"
            return
        }
        isBusy = true
        status = "Adding…"
        Task.detached(priority: .userInitiated) {
            do {
                let result = try await SyncEngine(device: dev).add(files: candidates)
                await MainActor.run {
                    let n = result.added.count
                    var msg = n > 0
                        ? "Added \(n) song\(n == 1 ? "" : "s") — click Eject, then they appear on the iPod"
                        : "Nothing added"
                    if !result.skipped.isEmpty { msg += " · skipped \(result.skipped.count)" }
                    self.status = msg
                    self.isBusy = false
                    self.updateCapacity()
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

    /// Remove the selected tracks from the iPod (and delete their audio files).
    func remove(ids: Set<UInt32>) {
        guard let dev = device, !ids.isEmpty, !isBusy else { return }
        isBusy = true
        status = "Removing \(ids.count) song\(ids.count == 1 ? "" : "s")…"
        Task.detached(priority: .userInitiated) {
            do {
                let n = try SyncEngine(device: dev).remove(trackIds: ids)
                await MainActor.run {
                    self.status = "Removed \(n) song\(n == 1 ? "" : "s") — click Eject to update the iPod"
                    self.isBusy = false
                    self.loadLibrary()
                }
            } catch {
                await MainActor.run {
                    self.status = "Remove failed: \(error.localizedDescription)"
                    self.isBusy = false
                }
            }
        }
    }

    /// Edit a track's metadata and rating, then write to the iPod.
    func editTrack(id: UInt32, title: String, artist: String, album: String, genre: String, rating: Int) {
        guard let dev = device, !isBusy else { return }
        isBusy = true
        status = "Saving changes…"
        Task.detached(priority: .userInitiated) {
            do {
                try SyncEngine(device: dev).editTrack(id: id, title: title, artist: artist,
                                                       album: album, genre: genre, rating: rating)
                await MainActor.run {
                    self.status = "Saved — click Eject to update the iPod"
                    self.isBusy = false
                    self.loadLibrary()
                }
            } catch {
                await MainActor.run {
                    self.status = "Edit failed: \(error.localizedDescription)"
                    self.isBusy = false
                }
            }
        }
    }

    /// Pick an image and set it as the selected track's cover.
    func chooseAndSetArtwork(id: UInt32) {
        guard let dev = device, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a cover image"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        isBusy = true
        status = "Setting artwork…"
        Task.detached(priority: .userInitiated) {
            do {
                try SyncEngine(device: dev).setArtwork(trackId: id, imageData: data)
                await MainActor.run { self.status = "Artwork set — click Eject to update the iPod"; self.isBusy = false; self.loadLibrary() }
            } catch {
                await MainActor.run { self.status = "Set artwork failed: \(error.localizedDescription)"; self.isBusy = false }
            }
        }
    }

    /// Pick a folder and export the selected tracks to it.
    func exportSelected(ids: Set<UInt32>) {
        guard let dev = device, !isBusy, !ids.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose where to export \(ids.count) song\(ids.count == 1 ? "" : "s")"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        isBusy = true
        status = "Exporting…"
        Task.detached(priority: .userInitiated) {
            do {
                let n = try SyncEngine(device: dev).export(trackIds: ids, to: dir)
                await MainActor.run { self.status = "Exported \(n) song\(n == 1 ? "" : "s") to \(dir.lastPathComponent)"; self.isBusy = false }
            } catch {
                await MainActor.run { self.status = "Export failed: \(error.localizedDescription)"; self.isBusy = false }
            }
        }
    }

    // MARK: Playlists

    private func runPlaylist(_ statusMsg: String, _ work: @escaping @Sendable (SyncEngine) throws -> Void) {
        guard let dev = device, !isBusy else { return }
        isBusy = true
        status = statusMsg
        Task.detached(priority: .userInitiated) {
            do {
                try work(SyncEngine(device: dev))
                await MainActor.run { self.isBusy = false; self.status = "Done — click Eject to update the iPod"; self.loadLibrary() }
            } catch {
                await MainActor.run { self.isBusy = false; self.status = "Playlist error: \(error.localizedDescription)" }
            }
        }
    }

    func createPlaylist(name: String, withTracks ids: [UInt32] = []) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        runPlaylist("Creating playlist…") { eng in
            let pid = try eng.createPlaylist(name: trimmed)
            if !ids.isEmpty { try eng.addToPlaylist(id: pid, trackIds: ids) }
        }
    }
    func renamePlaylist(id: UInt64, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        runPlaylist("Renaming playlist…") { try $0.renamePlaylist(id: id, name: trimmed) }
    }
    func deletePlaylist(id: UInt64) {
        runPlaylist("Deleting playlist…") { try $0.deletePlaylist(id: id) }
    }
    func addToPlaylist(id: UInt64, trackIds: [UInt32]) {
        runPlaylist("Adding to playlist…") { try $0.addToPlaylist(id: id, trackIds: trackIds) }
    }

    /// Re-encode the selected tracks to 44.1 kHz AAC (helps older iPods).
    func reencode(ids: Set<UInt32>) {
        guard let dev = device, !isBusy, !ids.isEmpty else { return }
        isBusy = true
        status = "Re-encoding \(ids.count) song\(ids.count == 1 ? "" : "s") to 44.1 kHz…"
        Task.detached(priority: .userInitiated) {
            do {
                let n = try SyncEngine(device: dev).reencode(trackIds: ids)
                await MainActor.run { self.status = "Re-encoded \(n) song\(n == 1 ? "" : "s") — click Eject"; self.isBusy = false; self.loadLibrary() }
            } catch {
                await MainActor.run { self.status = "Re-encode failed: \(error.localizedDescription)"; self.isBusy = false }
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
                let pls = db.userPlaylists
                await MainActor.run {
                    self.tracks = loaded
                    self.playlists = pls
                    self.status = "\(loaded.count) songs on \(dev.displayName)"
                    self.isBusy = false
                    self.updateCapacity()
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
