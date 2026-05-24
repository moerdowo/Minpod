import Foundation

/// High-level wrapper around a parsed iTunesDB chunk tree.
public final class ITunesDB {
    public let root: Chunk
    /// The raw bytes this DB was parsed from (used to validate round-trips).
    public let sourceBytes: [UInt8]

    public init(root: Chunk, sourceBytes: [UInt8]) {
        self.root = root
        self.sourceBytes = sourceBytes
    }

    public static func read(from device: IPodDevice) throws -> ITunesDB {
        let data = try Data(contentsOf: device.iTunesDBURL)
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> ITunesDB {
        let bytes = [UInt8](data)
        let root = try ChunkParser(bytes).parse()
        return ITunesDB(root: root, sourceBytes: bytes)
    }

    /// The mhsd dataset of a given type (1 = tracks, 2 = playlists, 3 = podcasts).
    public func dataset(type: UInt32) -> Chunk? {
        root.children.first { $0.magic == "mhsd" && $0.u32(at: 12) == type }
    }

    /// The track-list header (mhlt) inside the type-1 dataset.
    public var trackListHeader: Chunk? {
        dataset(type: 1)?.firstChild("mhlt")
    }

    public var trackChunks: [Chunk] {
        trackListHeader?.children.filter { $0.magic == "mhit" } ?? []
    }

    public var tracks: [Track] {
        trackChunks.map(Track.from(mhit:))
    }

    /// The first master/library playlist (kept for diagnostics).
    public var masterPlaylist: Chunk? { masterPlaylists.first }

    /// Every library/master playlist in the database — identified by carrying
    /// the type-52 sort indices. This iPod keeps one in BOTH the type-2 and
    /// type-3 datasets; the browse menus read one of them, so a track must be
    /// added to all of them or it stays invisible.
    public var masterPlaylists: [Chunk] {
        var result: [Chunk] = []
        for ds in root.children where ds.magic == "mhsd" {
            guard let listHeader = ds.children.first else { continue }
            for pl in listHeader.children where pl.magic == "mhyp" {
                if pl.children.contains(where: { $0.magic == "mhod" && $0.u32(at: 12) == 52 }) {
                    result.append(pl)
                }
            }
        }
        return result
    }

    public var nextTrackId: UInt32 {
        (trackChunks.map { $0.u32(at: 16) }.max() ?? 0) + 1
    }

    /// Insert a track into the track list and every master playlist, templating
    /// from existing entries. Mutates the tree in place.
    public func insertTrack(id: UInt32, dbid: UInt64, meta: AudioMetadata, ipodPath: String,
                            artworkSize: UInt32? = nil) throws {
        guard let mhlt = trackListHeader,
              let templateTrack = mhlt.children.first(where: { $0.magic == "mhit" }) else {
            throw SyncError.noTrackTemplate
        }
        let masters = masterPlaylists
        guard !masters.isEmpty else { throw SyncError.noMasterPlaylist }

        let mhit = TrackBuilder.makeTrack(template: templateTrack, id: id, dbid: dbid,
                                          meta: meta, ipodPath: ipodPath, artworkSize: artworkSize)
        mhlt.children.append(mhit)

        for mpl in masters {
            guard let templateItem = mpl.children.first(where: { $0.magic == "mhip" }) else { continue }
            let mhip = TrackBuilder.makePlaylistItem(template: templateItem, trackId: id)
            mpl.children.append(mhip)
            mpl.setU32(at: 0x10, UInt32(mpl.children.filter { $0.magic == "mhip" }.count))
        }
    }

    /// Ensure every master playlist contains an mhip for every track in the
    /// track list (repairs playlists that were left out of sync). Returns the
    /// number of mhips added.
    @discardableResult
    public func syncMasterPlaylists() -> Int {
        let allIds = trackChunks.map { $0.u32(at: 16) }
        var added = 0
        for mpl in masterPlaylists {
            guard let templateItem = mpl.children.first(where: { $0.magic == "mhip" }) else { continue }
            var present = Set(mpl.children.filter { $0.magic == "mhip" }.map { $0.u32(at: 0x18) })
            for id in allIds where !present.contains(id) {
                let mhip = TrackBuilder.makePlaylistItem(template: templateItem, trackId: id)
                mpl.children.append(mhip)
                present.insert(id)
                added += 1
            }
            mpl.setU32(at: 0x10, UInt32(mpl.children.filter { $0.magic == "mhip" }.count))
        }
        return added
    }

    /// Remove a track from the track list and every playlist that references it.
    /// Caller should rebuildIndexes() afterwards. Returns the track's iPod path.
    @discardableResult
    public func deleteTrack(id: UInt32) -> String? {
        var path: String?
        if let mhlt = trackListHeader {
            if let mhit = mhlt.children.first(where: { $0.magic == "mhit" && $0.u32(at: 16) == id }) {
                path = Track.from(mhit: mhit).ipodPath
            }
            mhlt.children.removeAll { $0.magic == "mhit" && $0.u32(at: 16) == id }
        }
        for ds in root.children where ds.magic == "mhsd" {
            guard let listHeader = ds.children.first else { continue }
            for pl in listHeader.children where pl.magic == "mhyp" {
                let before = pl.children.count
                pl.children.removeAll { $0.magic == "mhip" && $0.u32(at: 0x18) == id }
                if pl.children.count != before {
                    pl.setU32(at: 0x10, UInt32(pl.children.filter { $0.magic == "mhip" }.count))
                }
            }
        }
        return path
    }

    // MARK: Playlists

    public struct PlaylistInfo: Sendable, Identifiable {
        public let id: UInt64
        public let name: String
        public let trackIds: [UInt32]
    }

    /// The mhlp list headers that hold playlists (datasets that contain a
    /// master/library playlist — typically type 2 and type 3).
    private var playlistLists: [Chunk] {
        var out: [Chunk] = []
        for ds in root.children where ds.magic == "mhsd" {
            guard let mhlp = ds.children.first(where: { $0.magic == "mhlp" }) else { continue }
            if mhlp.children.contains(where: { pl in
                pl.magic == "mhyp" && pl.children.contains { $0.magic == "mhod" && $0.u32(at: 12) == 52 }
            }) { out.append(mhlp) }
        }
        return out
    }

    private func isMaster(_ mhyp: Chunk) -> Bool { mhyp.u8(at: 0x14) == 1 }
    private func playlistTitle(_ mhyp: Chunk) -> String {
        for m in mhyp.children where m.magic == "mhod" && m.u32(at: 12) == 1 {
            if let s = decodeMHODString(m) { return s }
        }
        return "Untitled"
    }

    /// User (non-master) playlists, read from the first playlist dataset.
    public var userPlaylists: [PlaylistInfo] {
        guard let mhlp = playlistLists.first else { return [] }
        return mhlp.children.filter { $0.magic == "mhyp" && !isMaster($0) }.map { pl in
            PlaylistInfo(id: pl.u64(at: 0x1C), name: playlistTitle(pl),
                         trackIds: pl.children.filter { $0.magic == "mhip" }.map { $0.u32(at: 0x18) })
        }
    }

    private func setPlaylistTitle(_ mhyp: Chunk, _ name: String) {
        let titleMhod = TrackBuilder.makeStringMHOD(type: .title, name)
        if let idx = mhyp.children.firstIndex(where: { $0.magic == "mhod" && $0.u32(at: 12) == 1 }) {
            mhyp.children[idx] = titleMhod
        } else {
            mhyp.children.insert(titleMhod, at: 0)
        }
    }

    /// Create an empty user playlist (mirrored across all playlist datasets).
    @discardableResult
    public func createPlaylist(name: String) -> UInt64 {
        let pid = UInt64.random(in: 1...UInt64.max)
        let now = TrackBuilder.macTimeNow()
        for mhlp in playlistLists {
            guard let master = mhlp.children.first(where: { $0.magic == "mhyp" && isMaster($0) }) else { continue }
            let pl = master.deepCopy()
            // Keep only the title + settings mhods; drop the master-only indices.
            pl.children = pl.children.filter { $0.magic == "mhod" && ($0.u32(at: 12) == 1 || $0.u32(at: 12) == 100) }
            pl.setU8(at: 0x14, 0)                 // normal (not master)
            pl.setU32(at: 0x0C, UInt32(pl.children.count))   // num_mhod
            pl.setU32(at: 0x10, 0)                // num_items
            pl.setU32(at: 0x18, now)              // timestamp
            pl.setU64(at: 0x1C, pid)              // playlist id
            setPlaylistTitle(pl, name)
            pl.setU32(at: 0x0C, UInt32(pl.children.filter { $0.magic == "mhod" }.count))
            mhlp.children.append(pl)
        }
        return pid
    }

    public func renamePlaylist(id: UInt64, name: String) {
        forEachPlaylist(id: id) { setPlaylistTitle($0, name); $0.setU32(at: 0x0C, UInt32($0.children.filter { $0.magic == "mhod" }.count)) }
    }

    public func deletePlaylist(id: UInt64) {
        for mhlp in playlistLists {
            mhlp.children.removeAll { $0.magic == "mhyp" && !isMaster($0) && $0.u64(at: 0x1C) == id }
        }
    }

    public func addToPlaylist(id: UInt64, trackIds: [UInt32]) {
        forEachPlaylist(id: id) { mhyp in
            let template = mhyp.children.first { $0.magic == "mhip" }
                ?? masterMhip(in: mhyp)
            guard let template else { return }
            let existing = Set(mhyp.children.filter { $0.magic == "mhip" }.map { $0.u32(at: 0x18) })
            for tid in trackIds where !existing.contains(tid) {
                mhyp.children.append(TrackBuilder.makePlaylistItem(template: template, trackId: tid))
            }
            mhyp.setU32(at: 0x10, UInt32(mhyp.children.filter { $0.magic == "mhip" }.count))
        }
    }

    private func masterMhip(in mhyp: Chunk) -> Chunk? {
        for mhlp in playlistLists where mhlp.children.contains(where: { $0 === mhyp }) {
            if let master = mhlp.children.first(where: { $0.magic == "mhyp" && isMaster($0) }) {
                return master.children.first { $0.magic == "mhip" }
            }
        }
        return nil
    }

    private func forEachPlaylist(id: UInt64, _ body: (Chunk) -> Void) {
        for mhlp in playlistLists {
            for pl in mhlp.children where pl.magic == "mhyp" && !isMaster(pl) && pl.u64(at: 0x1C) == id {
                body(pl)
            }
        }
    }

    /// Fix tracks whose secondary sample-rate float (0x88) doesn't match the
    /// primary sample rate (0x3C >> 16) — the cause of mid-song stalls on
    /// tracks added with an older build. Returns the number repaired.
    @discardableResult
    public func repairSampleRates() -> Int {
        var fixed = 0
        for mhit in trackChunks {
            let rate = mhit.u32(at: 0x3C) >> 16
            guard rate > 0 else { continue }
            let wantBits = Float(rate).bitPattern
            if mhit.u32(at: 0x88) != wantBits { mhit.setU32(at: 0x88, wantBits); fixed += 1 }
        }
        return fixed
    }

    /// Fix tracks whose sample count (0xBC) doesn't match their duration — the
    /// cause of songs stopping near the end — and clear gapless trim fields.
    /// Returns the number repaired.
    @discardableResult
    public func repairSampleCounts() -> Int {
        var fixed = 0
        for mhit in trackChunks {
            let lenMS = mhit.u32(at: 0x28)
            let rate = mhit.u32(at: 0x3C) >> 16
            guard lenMS > 0, rate > 0 else { continue }
            let expected = UInt64((Double(lenMS) / 1000.0) * Double(rate))
            let current = mhit.u64(at: 0xBC)
            // Tolerate small differences (already-correct iTunes values).
            let off = current > expected ? current - expected : expected - current
            if off > 50_000 || mhit.u32(at: 0xB8) != 0 || mhit.u32(at: 0xC8) != 0 {
                mhit.setU64(at: 0xBC, expected)
                mhit.setU32(at: 0xB8, 0)   // pregap
                mhit.setU32(at: 0xC8, 0)   // postgap
                mhit.setU32(at: 0xF8, 0)   // gapless_data
                mhit.setU16(at: 0x100, 0)  // gapless_track_flag
                mhit.setU16(at: 0x102, 0)  // gapless_album_flag
                fixed += 1
            }
        }
        return fixed
    }

    /// Edit a track's string fields and/or star rating in place. Nil arguments
    /// are left unchanged. Caller should rebuildIndexes() afterwards.
    public func editTrack(id: UInt32, title: String? = nil, artist: String? = nil,
                          album: String? = nil, genre: String? = nil, rating: Int? = nil) {
        guard let mhit = trackChunks.first(where: { $0.u32(at: 16) == id }) else { return }
        func setString(_ type: MHODType, _ value: String) {
            let mhod = TrackBuilder.makeStringMHOD(type: type, value)
            if let idx = mhit.children.firstIndex(where: { $0.magic == "mhod" && $0.u32(at: 12) == type.rawValue }) {
                mhit.children[idx] = mhod
            } else {
                mhit.children.append(mhod)
            }
        }
        if let title { setString(.title, title) }
        if let artist { setString(.artist, artist) }
        if let album { setString(.album, album) }
        if let genre { setString(.genre, genre) }
        mhit.setU32(at: 0x0C, UInt32(mhit.children.filter { $0.magic == "mhod" }.count))
        if let rating { mhit.setU8(at: 0x1F, UInt8(max(0, min(5, rating)) * 20)) }
    }

    /// Regenerate the master playlist's sort/browse indices (mhod 52/53) so the
    /// iPod's Songs/Artists/Albums lists include current tracks. Must be called
    /// after inserting or removing tracks, before serialize.
    public func rebuildIndexes() {
        LibraryIndex.rebuild(self)
    }

    /// Serialize back to bytes (checksums applied separately).
    public func serialize() -> [UInt8] {
        ChunkSerializer().serialize(root)
    }

    /// True when re-serializing reproduces the source bytes exactly.
    public func roundTripsExactly() -> Bool {
        serialize() == sourceBytes
    }
}
