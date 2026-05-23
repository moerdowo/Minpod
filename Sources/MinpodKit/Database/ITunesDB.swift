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

    /// Serialize back to bytes (checksums applied separately).
    public func serialize() -> [UInt8] {
        ChunkSerializer().serialize(root)
    }

    /// True when re-serializing reproduces the source bytes exactly.
    public func roundTripsExactly() -> Bool {
        serialize() == sourceBytes
    }
}
