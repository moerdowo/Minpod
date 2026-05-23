import Foundation

public struct SyncResult: Sendable {
    public var added: [String]          // titles successfully added
    public var skipped: [(String, String)] // (file, reason)
}

public enum SyncError: Error, CustomStringConvertible {
    case noTrackTemplate
    case noMasterPlaylist
    case databaseMissing

    public var description: String {
        switch self {
        case .noTrackTemplate:
            return "This iPod's library is empty. Add at least one song with iTunes/Finder first so Minpod can match its format."
        case .noMasterPlaylist:
            return "Could not find the iPod's master playlist in the database."
        case .databaseMissing:
            return "No iTunesDB found on the iPod."
        }
    }
}

/// Copies audio files onto the iPod and inserts them into the iTunesDB.
public struct SyncEngine {
    let device: IPodDevice
    let fm = FileManager.default

    public init(device: IPodDevice) {
        self.device = device
    }

    /// Add the given audio files. Reads the current DB fresh, mutates it, applies
    /// the checksum, and writes atomically after backing up the original.
    public func add(files: [URL]) async throws -> SyncResult {
        guard fm.fileExists(atPath: device.iTunesDBURL.path) else { throw SyncError.databaseMissing }

        let db = try ITunesDB.read(from: device)
        let scheme = ChecksumScheme.detect(in: db)
        guard scheme.isSupported else { throw ChecksumError.unsupported(scheme.label) }

        var nextId = db.nextTrackId
        var added: [String] = []
        var skipped: [(String, String)] = []
        var copiedFiles: [URL] = [] // for rollback on failure

        for file in files {
            let ext = file.pathExtension.lowercased()
            guard AudioMetadata.supportedExtensions.contains(ext) else {
                skipped.append((file.lastPathComponent, "unsupported format .\(ext)"))
                continue
            }
            do {
                let meta = await AudioMetadata.read(url: file)
                let (destURL, ipodPath) = try destination(forExtension: ext)
                try fm.copyItem(at: file, to: destURL)
                copiedFiles.append(destURL)

                let dbid = UInt64.random(in: 1...UInt64.max)
                try db.insertTrack(id: nextId, dbid: dbid, meta: meta, ipodPath: ipodPath)
                nextId += 1
                added.append(meta.title)
            } catch {
                skipped.append((file.lastPathComponent, error.localizedDescription))
            }
        }

        guard !added.isEmpty else { return SyncResult(added: added, skipped: skipped) }

        db.syncMasterPlaylists() // heal any master playlist left out of sync
        db.rebuildIndexes()
        var bytes = db.serialize()
        do {
            try scheme.apply(to: &bytes, firewireGUID: device.firewireGUID)
            try writeDatabase(bytes)
        } catch {
            // Roll back copied audio so we don't leave orphans referenced by no DB.
            for url in copiedFiles { try? fm.removeItem(at: url) }
            throw error
        }
        return SyncResult(added: added, skipped: skipped)
    }

    // MARK: helpers

    /// Pick a Music/Fxx folder and a free 4-letter filename; return the file URL
    /// and the colon-separated iPod path stored in the database.
    func destination(forExtension ext: String) throws -> (URL, String) {
        let folder = try musicFolder()
        for _ in 0..<64 {
            let name = randomName() + "." + ext
            let url = device.musicDir.appendingPathComponent(folder).appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) {
                let ipodPath = ":iPod_Control:Music:\(folder):\(name)"
                return (url, ipodPath)
            }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    private func musicFolder() throws -> String {
        let existing = (try? fm.contentsOfDirectory(atPath: device.musicDir.path)) ?? []
        let fFolders = existing.filter { $0.hasPrefix("F") && $0.count == 3 }
        if let pick = fFolders.randomElement() { return pick }
        let folder = "F00"
        try fm.createDirectory(at: device.musicDir.appendingPathComponent(folder),
                               withIntermediateDirectories: true)
        return folder
    }

    private func randomName() -> String {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        return String((0..<4).map { _ in letters.randomElement()! })
    }

    /// Back up the existing iTunesDB once, then atomically replace it.
    func writeDatabase(_ bytes: [UInt8]) throws {
        let dbURL = device.iTunesDBURL
        let backup = device.iTunesDir.appendingPathComponent("iTunesDB.minpod-backup")
        if !fm.fileExists(atPath: backup.path), fm.fileExists(atPath: dbURL.path) {
            try? fm.copyItem(at: dbURL, to: backup)
        }
        let tmp = device.iTunesDir.appendingPathComponent("iTunesDB.minpod-tmp")
        try? fm.removeItem(at: tmp)
        try Data(bytes).write(to: tmp, options: .atomic)
        _ = try fm.replaceItemAt(dbURL, withItemAt: tmp)
    }
}
