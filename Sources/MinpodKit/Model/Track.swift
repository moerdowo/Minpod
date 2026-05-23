import Foundation

/// mhod data-object type identifiers (the string fields hung off an mhit).
public enum MHODType: UInt32 {
    case title = 1
    case location = 2
    case album = 3
    case artist = 4
    case genre = 5
    case filetype = 6
    case comment = 8
    case category = 9
    case composer = 12
    case grouping = 13
    case albumArtist = 22
    case sortArtist = 23
    case playlistIndex = 100
}

/// A semantic, display-oriented view of one mhit track entry.
public struct Track: Identifiable, Hashable, Sendable {
    public var id: UInt32          // mhit track id (unique within this DB)
    public var dbid: UInt64        // persistent unique id
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    public var lengthMS: UInt32    // duration in milliseconds
    public var sizeBytes: UInt32
    public var trackNumber: UInt32
    public var year: UInt32
    public var ipodPath: String    // colon-separated, e.g. ":iPod_Control:Music:F00:ABCD.mp3"
    public var rating: Int         // 0...5 stars
    public var playCount: UInt32

    public var durationText: String {
        let total = Int(lengthMS) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    public init(id: UInt32, dbid: UInt64, title: String, artist: String, album: String,
                genre: String, lengthMS: UInt32, sizeBytes: UInt32, trackNumber: UInt32,
                year: UInt32, ipodPath: String, rating: Int = 0, playCount: UInt32 = 0) {
        self.id = id
        self.dbid = dbid
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.lengthMS = lengthMS
        self.sizeBytes = sizeBytes
        self.trackNumber = trackNumber
        self.year = year
        self.ipodPath = ipodPath
        self.rating = rating
        self.playCount = playCount
    }
}

extension Track {
    /// Build a Track from a parsed mhit chunk. Header offsets below are stable
    /// across the iTunesDB versions used by Video/Classic/Nano devices.
    static func from(mhit: Chunk) -> Track {
        func string(_ type: MHODType) -> String {
            for mhod in mhit.children where mhod.magic == "mhod" {
                if mhod.u32(at: 12) == type.rawValue, let s = decodeMHODString(mhod) {
                    return s
                }
            }
            return ""
        }
        return Track(
            id: mhit.u32(at: 16),
            dbid: mhit.u64(at: 0x70),
            title: string(.title),
            artist: string(.artist),
            album: string(.album),
            genre: string(.genre),
            lengthMS: mhit.u32(at: 0x28),
            sizeBytes: mhit.u32(at: 0x24),
            trackNumber: mhit.u32(at: 0x2C),
            year: mhit.u32(at: 0x34),
            ipodPath: string(.location),
            rating: min(5, Int(mhit.u8(at: 0x1F)) / 20),
            playCount: mhit.u32(at: 0x50)
        )
    }
}

/// Decode the string payload of a string-type mhod. Standard iTunesDB string
/// objects (title/artist/album/location/…) are UTF-16LE; the body header is
/// position(4), byte-length(4), then two unknown words before the string.
func decodeMHODString(_ mhod: Chunk) -> String? {
    let t = mhod.trailing
    guard t.count >= 16 else { return nil }
    let len = Int(le32(t, 4))
    let start = 16
    guard len >= 0, start + len <= t.count else { return nil }
    if len == 0 { return "" }
    let raw = Array(t[start..<start + len])
    return String(bytes: raw, encoding: .utf16LittleEndian)
}
