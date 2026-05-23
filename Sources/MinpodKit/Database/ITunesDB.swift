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

    /// The master playlist (first mhyp in the type-2 dataset).
    public var masterPlaylist: Chunk? {
        dataset(type: 2)?.firstChild("mhlp")?.children.first { $0.magic == "mhyp" }
    }

    public var nextTrackId: UInt32 {
        (trackChunks.map { $0.u32(at: 16) }.max() ?? 0) + 1
    }

    /// Insert a track into the track list and the master playlist, templating
    /// from existing entries. Mutates the tree in place.
    public func insertTrack(id: UInt32, dbid: UInt64, meta: AudioMetadata, ipodPath: String) throws {
        guard let mhlt = trackListHeader,
              let templateTrack = mhlt.children.first(where: { $0.magic == "mhit" }) else {
            throw SyncError.noTrackTemplate
        }
        guard let mpl = masterPlaylist,
              let templateItem = mpl.children.first(where: { $0.magic == "mhip" }) else {
            throw SyncError.noMasterPlaylist
        }
        let mhit = TrackBuilder.makeTrack(template: templateTrack, id: id, dbid: dbid,
                                          meta: meta, ipodPath: ipodPath)
        mhlt.children.append(mhit)
        let mhip = TrackBuilder.makePlaylistItem(template: templateItem, trackId: id)
        mpl.children.append(mhip)
        mpl.setU32(at: 0x10, UInt32(mpl.children.filter { $0.magic == "mhip" }.count))
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
