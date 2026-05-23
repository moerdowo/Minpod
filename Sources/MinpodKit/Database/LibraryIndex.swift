import Foundation

/// Regenerates the master playlist's "library playlist index" objects.
///
/// iPod classic / nano 3G+ do not sort the library live — they render the
/// Songs/Artists/Albums/Genres/Composers browse lists from precomputed sort
/// indices stored as mhod type 52 (sorted track-position arrays) and type 53
/// (alphabet "jump tables") hung off the master playlist. A newly added track
/// is invisible until it appears in these indices, so they must be rebuilt
/// after any change to the track list. Format/collation follow libgpod.
enum LibraryIndex {
    enum SortType: UInt32 {
        case title = 0x03
        case album = 0x04
        case artist = 0x05
        case genre = 0x07
        case composer = 0x12
    }

    struct IndexTrack {
        let index: Int          // position in the mhit track list (0-based)
        let title: String
        let artist: String
        let album: String
        let genre: String
        let composer: String
        let trackNumber: UInt32
        let discNumber: UInt32

        init(index: Int, mhit: Chunk) {
            self.index = index
            func str(_ type: MHODType) -> String {
                for m in mhit.children where m.magic == "mhod" && m.u32(at: 12) == type.rawValue {
                    if let s = decodeMHODString(m) { return s }
                }
                return ""
            }
            title = str(.title)
            artist = str(.artist)
            album = str(.album)
            genre = str(.genre)
            composer = str(.composer)
            trackNumber = mhit.u32(at: 0x2C)
            discNumber = mhit.u32(at: 0x5C)
        }
    }

    static func rebuild(_ db: ITunesDB) {
        guard let mhlt = db.trackListHeader, let mpl = db.masterPlaylist else { return }
        let mhits = mhlt.children.filter { $0.magic == "mhit" }
        let tracks = mhits.enumerated().map { IndexTrack(index: $0.offset, mhit: $0.element) }

        for mhod in mpl.children where mhod.magic == "mhod" {
            let mhodType = mhod.u32(at: 12)
            let sortRaw = le32(mhod.trailing, 0)
            if mhodType == 52 {
                mhod.trailing = makeIndexBody(sortRaw: sortRaw, ordered: sorted(tracks, by: sortRaw))
            } else if mhodType == 53 {
                mhod.trailing = makeJumpTableBody(sortRaw: sortRaw, ordered: sorted(tracks, by: sortRaw))
            }
        }
    }

    // MARK: sorting

    private static func cmp(_ a: String, _ b: String) -> Int {
        switch a.localizedCaseInsensitiveCompare(b) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    private static func sorted(_ tracks: [IndexTrack], by sortRaw: UInt32) -> [IndexTrack] {
        let type = SortType(rawValue: sortRaw)
        return tracks.sorted { a, b in
            var r = 0
            switch type {
            case .album:
                r = cmp(a.album, b.album)
                if r == 0 { r = Int(a.discNumber) - Int(b.discNumber) }
                if r == 0 { r = Int(a.trackNumber) - Int(b.trackNumber) }
                if r == 0 { r = cmp(a.title, b.title) }
            case .artist:
                r = cmp(a.artist, b.artist)
                if r == 0 { r = cmp(a.album, b.album) }
                if r == 0 { r = Int(a.discNumber) - Int(b.discNumber) }
                if r == 0 { r = Int(a.trackNumber) - Int(b.trackNumber) }
                if r == 0 { r = cmp(a.title, b.title) }
            case .genre:
                r = cmp(a.genre, b.genre)
                if r == 0 { r = cmp(a.artist, b.artist) }
                if r == 0 { r = cmp(a.album, b.album) }
                if r == 0 { r = Int(a.discNumber) - Int(b.discNumber) }
                if r == 0 { r = Int(a.trackNumber) - Int(b.trackNumber) }
                if r == 0 { r = cmp(a.title, b.title) }
            case .composer:
                r = cmp(a.composer, b.composer)
                if r == 0 { r = cmp(a.album, b.album) }
                if r == 0 { r = Int(a.discNumber) - Int(b.discNumber) }
                if r == 0 { r = Int(a.trackNumber) - Int(b.trackNumber) }
                if r == 0 { r = cmp(a.title, b.title) }
            default: // title and unknown/TV sort types — order by title
                r = cmp(a.title, b.title)
            }
            if r == 0 { r = a.index - b.index } // stable, deterministic
            return r < 0
        }
    }

    /// The field whose first letter drives the jump table for a sort type.
    private static func letterField(_ t: IndexTrack, _ sortRaw: UInt32) -> String {
        switch SortType(rawValue: sortRaw) {
        case .album: return t.album
        case .artist: return t.artist
        case .genre: return t.genre
        case .composer: return t.composer
        default: return t.title
        }
    }

    // MARK: serialization

    private static func makeIndexBody(sortRaw: UInt32, ordered: [IndexTrack]) -> [UInt8] {
        let w = ByteWriter()
        w.appendUInt32(sortRaw)
        w.appendUInt32(UInt32(ordered.count))
        for _ in 0..<10 { w.appendUInt32(0) }
        for t in ordered { w.appendUInt32(UInt32(t.index)) }
        return w.bytes
    }

    private static func makeJumpTableBody(sortRaw: UInt32, ordered: [IndexTrack]) -> [UInt8] {
        // Group consecutive tracks by first-letter of the relevant field.
        var entries: [(letter: UInt16, start: UInt32, count: UInt32)] = []
        for (i, t) in ordered.enumerated() {
            let letter = jumpLetter(letterField(t, sortRaw))
            if var last = entries.last, last.letter == letter {
                last.count += 1
                entries[entries.count - 1] = last
            } else {
                entries.append((letter, UInt32(i), 1))
            }
        }
        let w = ByteWriter()
        w.appendUInt32(sortRaw)
        w.appendUInt32(UInt32(entries.count))
        w.appendUInt32(0)
        w.appendUInt32(0)
        for e in entries {
            w.appendUInt16(e.letter)
            w.appendUInt16(0)
            w.appendUInt32(e.start)
            w.appendUInt32(e.count)
        }
        return w.bytes
    }

    /// First alphanumeric character: uppercase UTF-16 unit for letters, '0' for
    /// digits or strings with no alphanumerics (matches libgpod's jump_table_letter).
    private static func jumpLetter(_ s: String) -> UInt16 {
        for ch in s.unicodeScalars {
            if CharacterSet.letters.contains(ch) {
                let upper = String(ch).uppercased()
                return Array(upper.utf16).first ?? 0x30
            }
            if CharacterSet.decimalDigits.contains(ch) {
                return 0x30 // '0'
            }
        }
        return 0x30
    }
}
