import Foundation

public struct SyncResult: Sendable {
    public var added: [String]          // titles successfully added
    public var skipped: [(String, String)] // (file, reason)
}

public enum SyncError: Error, CustomStringConvertible {
    case noTrackTemplate
    case noMasterPlaylist
    case databaseMissing
    case trackNotFound
    case artworkFailed

    public var description: String {
        switch self {
        case .noTrackTemplate:
            return "This iPod's library is empty. Add at least one song with iTunes/Finder first so Minpod can match its format."
        case .noMasterPlaylist:
            return "Could not find the iPod's master playlist in the database."
        case .databaseMissing:
            return "No iTunesDB found on the iPod."
        case .trackNotFound:
            return "Track not found on the iPod."
        case .artworkFailed:
            return "Couldn't read or convert the image."
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
        db.repairSampleRates()   // heal any stale secondary sample-rate fields
        db.repairSampleCounts()  // heal any stale sample counts / gapless trims
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

    /// Set (or replace) a track's cover art from raw image data.
    public func setArtwork(trackId: UInt32, imageData: Data) throws {
        let db = try ITunesDB.read(from: device)
        let scheme = ChecksumScheme.detect(in: db)
        guard scheme.isSupported else { throw ChecksumError.unsupported(scheme.label) }
        guard let mhit = db.trackChunks.first(where: { $0.u32(at: 16) == trackId }) else { throw SyncError.trackNotFound }

        let dbid = mhit.u64(at: 0x70)
        let idMap = try ArtworkWriter(device: device).addImages([(dbid, imageData)])
        guard let imageId = idMap[dbid] else { throw SyncError.artworkFailed }

        mhit.setU16(at: 0x7C, 1)            // artwork_count
        mhit.setU16(at: 0x7E, 0xFFFF)
        mhit.setU32(at: 0x80, UInt32(imageData.count))
        mhit.setU8(at: 0xA4, 1)             // has_artwork
        mhit.setU32(at: 0x160, imageId)     // mhii_link

        var bytes = db.serialize()
        try scheme.apply(to: &bytes, firewireGUID: device.firewireGUID)
        try writeDatabase(bytes)
    }

    /// Copy selected tracks off the iPod into `dir`, named "Artist - Title.ext".
    @discardableResult
    public func export(trackIds: Set<UInt32>, to dir: URL) throws -> Int {
        let db = try ITunesDB.read(from: device)
        var n = 0
        for t in db.tracks where trackIds.contains(t.id) {
            let srcURL = fileURL(forIPodPath: t.ipodPath)
            guard fm.fileExists(atPath: srcURL.path) else { continue }
            let ext = srcURL.pathExtension
            let base = Self.sanitizeFilename(t.artist.isEmpty ? t.title : "\(t.artist) - \(t.title)")
            var destURL = dir.appendingPathComponent(base).appendingPathExtension(ext)
            var i = 1
            while fm.fileExists(atPath: destURL.path) {
                destURL = dir.appendingPathComponent("\(base) (\(i))").appendingPathExtension(ext)
                i += 1
            }
            try fm.copyItem(at: srcURL, to: destURL)
            n += 1
        }
        return n
    }

    static func sanitizeFilename(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(180))
    }

    // MARK: Playlists

    private func mutate(_ body: (ITunesDB) throws -> Void) throws {
        let db = try ITunesDB.read(from: device)
        let scheme = ChecksumScheme.detect(in: db)
        guard scheme.isSupported else { throw ChecksumError.unsupported(scheme.label) }
        try body(db)
        var bytes = db.serialize()
        try scheme.apply(to: &bytes, firewireGUID: device.firewireGUID)
        try writeDatabase(bytes)
    }

    public func createPlaylist(name: String) throws -> UInt64 {
        var pid: UInt64 = 0
        try mutate { pid = $0.createPlaylist(name: name) }
        return pid
    }
    public func renamePlaylist(id: UInt64, name: String) throws { try mutate { $0.renamePlaylist(id: id, name: name) } }
    public func deletePlaylist(id: UInt64) throws { try mutate { $0.deletePlaylist(id: id) } }
    public func addToPlaylist(id: UInt64, trackIds: [UInt32]) throws { try mutate { $0.addToPlaylist(id: id, trackIds: trackIds) } }

    /// Edit a track's metadata / rating and write the database.
    public func editTrack(id: UInt32, title: String?, artist: String?, album: String?,
                          genre: String?, rating: Int?) throws {
        let db = try ITunesDB.read(from: device)
        let scheme = ChecksumScheme.detect(in: db)
        guard scheme.isSupported else { throw ChecksumError.unsupported(scheme.label) }
        db.editTrack(id: id, title: title, artist: artist, album: album, genre: genre, rating: rating)
        db.rebuildIndexes()
        var bytes = db.serialize()
        try scheme.apply(to: &bytes, firewireGUID: device.firewireGUID)
        try writeDatabase(bytes)
    }

    /// Re-encode the given tracks' on-device files to AAC at `sampleRate`
    /// (default 44.1 kHz) and update the database. Returns the number re-encoded.
    @discardableResult
    public func reencode(trackIds: Set<UInt32>, sampleRate: Int = 44100, bitrate: Int = 256000) throws -> Int {
        let db = try ITunesDB.read(from: device)
        let scheme = ChecksumScheme.detect(in: db)
        guard scheme.isSupported else { throw ChecksumError.unsupported(scheme.label) }

        var count = 0
        var oldFilesToDelete: [URL] = []
        for mhit in db.trackChunks where trackIds.contains(mhit.u32(at: 16)) {
            let oldPath = Track.from(mhit: mhit).ipodPath
            let oldURL = fileURL(forIPodPath: oldPath)
            guard fm.fileExists(atPath: oldURL.path) else { continue }

            let tmp = fm.temporaryDirectory.appendingPathComponent("minpod-\(UUID().uuidString).m4a")
            guard runAfconvert(input: oldURL, output: tmp, sampleRate: sampleRate, bitrate: bitrate),
                  fm.fileExists(atPath: tmp.path) else { continue }

            let (newURL, newIPodPath) = try destination(forExtension: "m4a")
            try fm.copyItem(at: tmp, to: newURL)
            try? fm.removeItem(at: tmp)

            let newSize = UInt32((try? fm.attributesOfItem(atPath: newURL.path)[.size] as? Int ?? 0) ?? 0)
            replaceMhod(mhit, type: .location, newIPodPath)
            replaceMhod(mhit, type: .filetype, "AAC audio file")
            mhit.setU32(at: 0x24, newSize)                                  // size
            mhit.setU32(at: 0x3C, UInt32(sampleRate) << 16)                 // sample rate
            mhit.setU32(at: 0x88, Float(sampleRate).bitPattern)             // sample rate (float)
            let lenMS = mhit.u32(at: 0x28)
            if lenMS > 0 { mhit.setU32(at: 0x38, UInt32(Double(newSize) * 8 / (Double(lenMS) / 1000) / 1000)) }

            oldFilesToDelete.append(oldURL)
            count += 1
        }
        guard count > 0 else { return 0 }

        db.rebuildIndexes()
        var bytes = db.serialize()
        try scheme.apply(to: &bytes, firewireGUID: device.firewireGUID)
        try writeDatabase(bytes)
        for url in oldFilesToDelete { try? fm.removeItem(at: url) }
        return count
    }

    private func replaceMhod(_ mhit: Chunk, type: MHODType, _ value: String) {
        let m = TrackBuilder.makeStringMHOD(type: type, value)
        if let i = mhit.children.firstIndex(where: { $0.magic == "mhod" && $0.u32(at: 12) == type.rawValue }) {
            mhit.children[i] = m
        } else {
            mhit.children.append(m)
            mhit.setU32(at: 0x0C, UInt32(mhit.children.filter { $0.magic == "mhod" }.count))
        }
    }

    private func runAfconvert(input: URL, output: URL, sampleRate: Int, bitrate: Int) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "m4af", "-d", "aac@\(sampleRate)", "-b", "\(bitrate)",
                       input.path, output.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
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
