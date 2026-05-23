import Foundation

/// Builds the iTunesDB chunks for a newly added track.
///
/// New mhit/mhip entries are cloned from an existing entry on the device so they
/// inherit the exact header size and media-type/flag bytes that this iPod's
/// iTunes version expects; only the fields specific to the new track are
/// overwritten.
enum TrackBuilder {
    // mhit field offsets (see MhitHeader).
    enum MHIT {
        static let numMhod = 0x0C
        static let trackId = 0x10
        static let visible = 0x14
        static let dateAdded = 0x20
        static let size = 0x24
        static let length = 0x28
        static let trackNumber = 0x2C
        static let trackTotal = 0x30
        static let year = 0x34
        static let bitrate = 0x38
        static let sampleRate32 = 0x3C  // stored as rate << 16
        static let playCount = 0x50
        static let playCount2 = 0x54
        static let lastPlayed = 0x58
        static let lastModified = 0x68
        static let bookmarkTime = 0x6C
        static let songId = 0x70        // 8-byte persistent dbid
        static let artworkCount = 0x7C  // i16
        static let artworkSize = 0x80
    }
    enum MHIP {
        static let trackId = 0x18
        static let timestamp = 0x1C
    }

    static let macEpochOffset: UInt32 = 2082844800 // seconds between 1904 and 1970

    static func macTimeNow() -> UInt32 {
        UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970) + Int64(macEpochOffset))
    }

    /// Construct a UTF-16LE string data-object (mhod).
    static func makeStringMHOD(type: MHODType, _ string: String) -> Chunk {
        let utf16 = Array(string.utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        let w = ByteWriter()
        w.appendMagic("mhod")
        w.appendUInt32(24)            // header_len
        w.appendUInt32(0)            // total_len (serializer patches)
        w.appendUInt32(type.rawValue)
        w.appendUInt32(0)            // unknown1
        w.appendUInt32(0)            // unknown2
        let header = w.bytes

        let body = ByteWriter()
        body.appendUInt32(1)                      // position
        body.appendUInt32(UInt32(utf16.count))    // string length (bytes)
        body.appendUInt32(1)                      // unknown3 (matches iTunes)
        body.appendUInt32(0)                      // unknown4
        body.append(utf16)

        return Chunk(magic: "mhod", header: header, children: [], trailing: body.bytes, hasTotalLen: true)
    }

    /// Build a new track entry by templating an existing mhit.
    static func makeTrack(template: Chunk, id: UInt32, dbid: UInt64,
                          meta: AudioMetadata, ipodPath: String) -> Chunk {
        let mhit = template.deepCopy()

        var mhods: [Chunk] = [makeStringMHOD(type: .title, meta.title)]
        if !meta.artist.isEmpty { mhods.append(makeStringMHOD(type: .artist, meta.artist)) }
        if !meta.album.isEmpty { mhods.append(makeStringMHOD(type: .album, meta.album)) }
        if !meta.genre.isEmpty { mhods.append(makeStringMHOD(type: .genre, meta.genre)) }
        mhods.append(makeStringMHOD(type: .filetype, fileTypeDescription(meta.fileExtension)))
        mhods.append(makeStringMHOD(type: .location, ipodPath))
        mhit.children = mhods

        let now = macTimeNow()
        mhit.setU32(at: MHIT.numMhod, UInt32(mhods.count))
        mhit.setU32(at: MHIT.trackId, id)
        mhit.setU32(at: MHIT.visible, 1)
        mhit.setU32(at: MHIT.dateAdded, now)
        mhit.setU32(at: MHIT.size, meta.fileSize)
        mhit.setU32(at: MHIT.length, meta.durationMS)
        mhit.setU32(at: MHIT.trackNumber, meta.trackNumber)
        mhit.setU32(at: MHIT.trackTotal, meta.trackTotal)
        mhit.setU32(at: MHIT.year, meta.year)
        mhit.setU32(at: MHIT.bitrate, meta.bitrate)
        mhit.setU32(at: MHIT.sampleRate32, meta.sampleRate << 16)
        mhit.setU32(at: MHIT.playCount, 0)
        mhit.setU32(at: MHIT.playCount2, 0)
        mhit.setU32(at: MHIT.lastPlayed, 0)
        mhit.setU32(at: MHIT.lastModified, now)
        mhit.setU32(at: MHIT.bookmarkTime, 0)
        mhit.setU64(at: MHIT.songId, dbid)
        mhit.setU16(at: MHIT.artworkCount, 0)
        mhit.setU32(at: MHIT.artworkSize, 0)
        return mhit
    }

    /// Build a master-playlist entry (mhip) referencing the new track.
    static func makePlaylistItem(template: Chunk, trackId: UInt32) -> Chunk {
        let mhip = template.deepCopy()
        mhip.setU32(at: MHIP.trackId, trackId)
        mhip.setU32(at: MHIP.timestamp, macTimeNow())
        return mhip
    }

    private static func fileTypeDescription(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "MPEG audio file"
        case "m4a", "aac", "alac": return "AAC audio file"
        case "m4b": return "AAC audio book file"
        case "wav": return "WAV audio file"
        case "aif", "aiff": return "AIFF audio file"
        default: return "\(ext.uppercased()) audio file"
        }
    }
}
