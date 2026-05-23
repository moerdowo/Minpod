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
        var tempFiles: [URL] = []   // converted files to clean up
        var artItems: [(dbid: UInt64, imageData: Data)] = []
        defer { for t in tempFiles { try? fm.removeItem(at: t) } }

        // Drops may include folders; flatten to individual audio files.
        let inputs = Self.expandToAudioFiles(files)
        // For duplicate detection (title + artist, case-insensitive).
        var seenKeys = Set(db.tracks.map { Self.dupKey($0.title, $0.artist) })

        for input in inputs {
            var src = input
            var ext = input.pathExtension.lowercased()
            // Convert formats the iPod can't play (e.g. FLAC) to AAC.
            if !AudioMetadata.supportedExtensions.contains(ext) {
                if let converted = await AudioConverter.toM4A(input) {
                    src = converted; ext = "m4a"; tempFiles.append(converted)
                } else {
                    skipped.append((input.lastPathComponent, "unsupported format .\(ext)"))
                    continue
                }
            }
            do {
                var meta = await AudioMetadata.read(url: src)
                // For converted files the fallback title is the temp filename;
                // use the original file's name instead (tags, if any, survive).
                if src != input {
                    let tempBase = src.deletingPathExtension().lastPathComponent
                    if meta.title == tempBase { meta.title = input.deletingPathExtension().lastPathComponent }
                }
                let key = Self.dupKey(meta.title, meta.artist)
                if seenKeys.contains(key) {
                    skipped.append((input.lastPathComponent, "already on iPod"))
                    continue
                }
                let (destURL, ipodPath) = try destination(forExtension: ext)
                try fm.copyItem(at: src, to: destURL)
                copiedFiles.append(destURL)

                let dbid = UInt64.random(in: 1...UInt64.max)
                let artSize = meta.artworkData.map { UInt32($0.count) }
                try db.insertTrack(id: nextId, dbid: dbid, meta: meta, ipodPath: ipodPath, artworkSize: artSize)
                if let art = meta.artworkData { artItems.append((dbid, art)) }
                seenKeys.insert(key)
                nextId += 1
                added.append(meta.title)
            } catch {
                skipped.append((input.lastPathComponent, error.localizedDescription))
            }
        }

        guard !added.isEmpty else { return SyncResult(added: added, skipped: skipped) }

        // Write album art (best-effort: failure shouldn't block the music sync).
        if !artItems.isEmpty {
            do {
                let writer = ArtworkWriter(device: device)
                try writer.addImages(artItems)
                // Link every track to the image whose song_id matches its dbid
                // (mhii_link at 0x160 — what the iPod classic uses to resolve art).
                try writer.repairLinks(in: db)
            } catch { skipped.append(("album art", error.localizedDescription)) }
        }

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

    /// Remove tracks from the iPod: drop them from the database and every
    /// playlist, rebuild indices, write atomically, then delete the audio files
    /// that no track references any more. Returns the number removed.
    @discardableResult
    public func remove(trackIds: Set<UInt32>) throws -> Int {
        guard !trackIds.isEmpty, fm.fileExists(atPath: device.iTunesDBURL.path) else { return 0 }
        let db = try ITunesDB.read(from: device)
        let scheme = ChecksumScheme.detect(in: db)
        guard scheme.isSupported else { throw ChecksumError.unsupported(scheme.label) }

        var removedPaths: [String] = []
        for id in trackIds {
            if let path = db.deleteTrack(id: id) { removedPaths.append(path) }
        }
        db.rebuildIndexes()

        var bytes = db.serialize()
        try scheme.apply(to: &bytes, firewireGUID: device.firewireGUID)
        try writeDatabase(bytes)

        // Delete audio files no remaining track points at.
        let stillReferenced = Set(db.tracks.map { $0.ipodPath })
        for path in removedPaths where !stillReferenced.contains(path) {
            try? fm.removeItem(at: fileURL(forIPodPath: path))
        }
        return trackIds.count
    }

    /// Flatten dropped folders into individual audio files (supported or
    /// convertible), recursively.
    static func expandToAudioFiles(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        let exts = AudioMetadata.supportedExtensions.union(AudioConverter.convertibleExtensions)
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                      options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if exts.contains(f.pathExtension.lowercased()) { out.append(f) }
                }
            } else {
                out.append(url)
            }
        }
        return out.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func dupKey(_ title: String, _ artist: String) -> String {
        (title.lowercased() + "\u{1}" + artist.lowercased())
    }

    /// Map a colon-separated iPod path (":iPod_Control:Music:F00:ABCD.mp3") to a URL.
    func fileURL(forIPodPath path: String) -> URL {
        var url = device.mountPoint
        for part in path.split(separator: ":") { url.appendPathComponent(String(part)) }
        return url
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
