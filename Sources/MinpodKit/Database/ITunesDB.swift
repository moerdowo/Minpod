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
