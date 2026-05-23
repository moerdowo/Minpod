import Foundation
import MinpodKit

// Command-line diagnostic for the iTunesDB engine. Validates the byte-exact
// round-trip against real hardware and dumps the database header so we can
// confirm versions and checksum schemes empirically.
//
//   minpod-doctor                 # scan connected iPods
//   minpod-doctor <iTunesDB path> # analyze a database file directly

func hexDump(_ bytes: ArraySlice<UInt8>, base: Int = 0) {
    let arr = Array(bytes)
    var i = 0
    while i < arr.count {
        let row = arr[i..<min(i + 16, arr.count)]
        let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
        let ascii = row.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
        print(String(format: "  %04x  %-47s  %@", base + i, (hex as NSString).utf8String!, ascii as NSString))
        i += 16
    }
}

func analyze(_ db: ITunesDB, label: String) {
    let root = db.root
    print("  magic:           \(root.magic)")
    print("  file size:       \(db.sourceBytes.count) bytes")
    print("  mhbd headerLen:  \(root.headerLen)")
    print("  mhbd totalLen:   \(root.u32(at: 8))")
    print("  unknown1 @0x0C:  \(root.u32(at: 0x0C))")
    print("  version @0x10:   0x\(String(root.u32(at: 0x10), radix: 16))")
    print("  #children @0x14: \(root.u32(at: 0x14))")
    print("  persist id @0x18:0x\(String(root.u64(at: 0x18), radix: 16))")
    print("  track count:     \(db.tracks.count)")
    let datasets = root.children.filter { $0.magic == "mhsd" }.map { $0.u32(at: 12) }
    print("  mhsd types:      \(datasets)")
    print("  --- mhbd header hex (\(root.headerLen) bytes) ---")
    hexDump(db.sourceBytes[0..<min(root.headerLen, db.sourceBytes.count)])
    let exact = db.roundTripsExactly()
    print("  round-trip exact: \(exact ? "PASS ✅" : "FAIL ❌")")
    if !exact {
        let out = db.serialize()
        print("  serialized size: \(out.count) (source \(db.sourceBytes.count))")
        if let diff = firstDifference(out, db.sourceBytes) {
            print("  first byte diff at offset 0x\(String(diff, radix: 16))")
            let lo = max(0, diff - 8)
            print("  source:")
            hexDump(db.sourceBytes[lo..<min(lo + 32, db.sourceBytes.count)], base: lo)
            print("  ours:")
            hexDump(ArraySlice(out)[lo..<min(lo + 32, out.count)], base: lo)
        }
    }
    if db.tracks.count > 0 {
        print("  --- first up to 5 tracks ---")
        for t in db.tracks.prefix(5) {
            print("    [\(t.id)] \(t.artist) — \(t.title) (\(t.durationText))  \(t.ipodPath)")
        }
    }
}

func firstDifference(_ a: [UInt8], _ b: [UInt8]) -> Int? {
    let n = min(a.count, b.count)
    for i in 0..<n where a[i] != b[i] { return i }
    return a.count == b.count ? nil : n
}

var args = Array(CommandLine.arguments.dropFirst())

// Optional: --guid XXXX recomputes hash58 and compares to the stored checksum.
var overrideGUID: String?
if let gi = args.firstIndex(of: "--guid"), gi + 1 < args.count {
    overrideGUID = args[gi + 1]
    args.removeSubrange(gi...gi + 1)
}

func verifyHash58(_ db: ITunesDB, guid: String) {
    let stored = Array(db.sourceBytes[Hash58.offHash58..<Hash58.offHash58 + 20])
    var work = db.sourceBytes
    do {
        try Hash58.writeHash(into: &work, firewireGUID: guid)
        let computed = Array(work[Hash58.offHash58..<Hash58.offHash58 + 20])
        let match = computed == stored
        print("  hash58 (guid \(guid)): \(match ? "MATCH ✅ — checksum algorithm verified" : "MISMATCH ❌")")
        if !match {
            print("    stored:   \(stored.map { String(format: "%02x", $0) }.joined())")
            print("    computed: \(computed.map { String(format: "%02x", $0) }.joined())")
        }
    } catch {
        print("  hash58 error: \(error)")
    }
}

// simulate-add <audiofile>: build the modified DB from the connected iPod's
// real database + this audio file, apply hash58, write to /tmp, and validate —
// all WITHOUT touching the device.
if args.first == "simulate-add", args.count >= 2 {
    let audio = URL(fileURLWithPath: args[1])
    guard let dev = IPodDetector().currentDevices().first else {
        print("No iPod connected."); exit(1)
    }
    print("Simulating add of \(audio.lastPathComponent) to \(dev.displayName)")
    Task {
        defer { exit(0) }
        do {
            let db = try ITunesDB.read(from: dev)
            let before = db.tracks.count
            let scheme = ChecksumScheme.detect(in: db)
            let meta = await AudioMetadata.read(url: audio)
            print("  metadata: \"\(meta.title)\" / \(meta.artist) / \(meta.album)  \(meta.durationMS)ms \(meta.bitrate)kbps \(meta.sampleRate)Hz \(meta.fileSize)B")
            print("  scheme: \(scheme.label)")
            try db.insertTrack(id: db.nextTrackId, dbid: UInt64.random(in: 1...UInt64.max),
                               meta: meta, ipodPath: ":iPod_Control:Music:F00:TEST.\(audio.pathExtension)")
            var bytes = db.serialize()
            try scheme.apply(to: &bytes, firewireGUID: dev.firewireGUID)
            let out = URL(fileURLWithPath: "/tmp/new_iTunesDB")
            try Data(bytes).write(to: out)
            let reparsed = try ITunesDB.parse(Data(bytes))
            print("  tracks: \(before) -> \(reparsed.tracks.count)")
            print("  mhbd total_len == file size: \(Int(reparsed.root.u32(at: 8)) == bytes.count)")
            print("  new track present: \(reparsed.tracks.contains { $0.title == meta.title })")
            print("  reparse OK, wrote \(bytes.count) bytes to /tmp/new_iTunesDB")
            verifyHash58(reparsed, guid: dev.firewireGUID ?? "")
        } catch {
            print("  ERROR: \(error)")
        }
    }
    RunLoop.main.run()
}

// add <audiofile...>: REAL write — copy files onto the connected iPod and
// insert them into its iTunesDB (backs up the original first).
// verify-files: list tracks whose referenced audio file is missing on disk,
// and show the newest tracks with their resolved paths.
if args.first == "verify-files" {
    guard let dev = IPodDetector().currentDevices().first else { print("No iPod connected."); exit(1) }
    do {
        let db = try ITunesDB.read(from: dev)
        let tracks = db.tracks
        func resolve(_ p: String) -> URL {
            let rel = p.replacingOccurrences(of: ":", with: "/")
            return dev.mountPoint.appendingPathComponent(rel)
        }
        var missing = 0
        for t in tracks {
            let url = resolve(t.ipodPath)
            if !FileManager.default.fileExists(atPath: url.path) { missing += 1 }
        }
        print("tracks: \(tracks.count), missing files: \(missing)")
        print("--- newest 5 tracks by id ---")
        for t in tracks.sorted(by: { $0.id > $1.id }).prefix(5) {
            let url = resolve(t.ipodPath)
            let exists = FileManager.default.fileExists(atPath: url.path)
            print("  [\(t.id)] \"\(t.title)\" len=\(t.lengthMS)ms size=\(t.sizeBytes)  exists=\(exists)")
            print("       path=\(t.ipodPath)")
        }
    } catch { print("ERROR: \(error)") }
    exit(0)
}

// playlists: inspect the playlist datasets and whether they reference the newest track.
if args.first == "playlists" {
    guard let dev = IPodDetector().currentDevices().first else { print("No iPod connected."); exit(1) }
    do {
        let db = try ITunesDB.read(from: dev)
        let newest = db.tracks.map { $0.id }.max() ?? 0
        print("newest track id: \(newest), track-list count: \(db.trackChunks.count)")
        guard let mhlp = db.dataset(type: 2)?.firstChild("mhlp") else { print("no mhlp"); exit(0) }
        let playlists = mhlp.children.filter { $0.magic == "mhyp" }
        print("playlists (mhyp): \(playlists.count)")
        for (i, pl) in playlists.enumerated() {
            let numItems = pl.u32(at: 0x10)
            let mhips = pl.children.filter { $0.magic == "mhip" }
            let hasNewest = mhips.contains { $0.u32(at: 0x18) == newest }
            let numMhod = pl.u32(at: 0x0C)
            print("  [\(i)] num_mhod=\(numMhod) num_items(0x10)=\(numItems) actual mhip=\(mhips.count) containsNewest=\(hasNewest)")
        }
    } catch { print("ERROR: \(error)") }
    exit(0)
}

// mpl-mhods: dump the master playlist's mhod children (types + sizes).
// masters: across ALL datasets, find every mhyp that carries type-52 sort
// indices (i.e. a library/master playlist) and report its mhip count + index
// counts — to detect master playlists we failed to update.
if args.first == "masters" {
    guard let dev = IPodDetector().currentDevices().first else { print("No iPod connected."); exit(1) }
    func le(_ a: [UInt8], _ o: Int) -> UInt32 { (o+4<=a.count) ? UInt32(a[o]) | (UInt32(a[o+1])<<8) | (UInt32(a[o+2])<<16) | (UInt32(a[o+3])<<24) : 0 }
    do {
        let db = try ITunesDB.read(from: dev)
        print("track-list count: \(db.trackChunks.count)")
        for ds in db.root.children where ds.magic == "mhsd" {
            let dsType = ds.u32(at: 12)
            guard let lh = ds.children.first else { continue }
            for (i, pl) in lh.children.enumerated() where pl.magic == "mhyp" {
                let mhips = pl.children.filter { $0.magic == "mhip" }.count
                let t52 = pl.children.filter { $0.magic == "mhod" && $0.u32(at: 12) == 52 }
                guard !t52.isEmpty else { continue } // only library/master playlists
                let idxCounts = t52.map { Int(le($0.trailing, 4)) }
                print("mhsd type=\(dsType) playlist#\(i): mhips=\(mhips) type52 indices=\(t52.count) counts=\(Set(idxCounts))")
            }
        }
    } catch { print("ERROR: \(error)") }
    exit(0)
}

// mhsd-dump: show every dataset, its list header, item count, and child magics.
if args.first == "mhsd-dump" {
    guard let dev = IPodDetector().currentDevices().first else { print("No iPod connected."); exit(1) }
    do {
        let db = try ITunesDB.read(from: dev)
        print("track-list mhit count: \(db.trackChunks.count)")
        for ds in db.root.children where ds.magic == "mhsd" {
            let type = ds.u32(at: 12)
            let listHeader = ds.children.first
            let lh = listHeader?.magic ?? "?"
            let items = listHeader?.children.count ?? 0
            print("mhsd type=\(type): listHeader=\(lh) items=\(items)")
            // tally child magics of the list header
            var tally: [String: Int] = [:]
            for c in listHeader?.children ?? [] { tally[c.magic, default: 0] += 1 }
            print("    child magics: \(tally)")
            // for album-ish items, show how many reference a track id we recognize
            if let first = listHeader?.children.first {
                print("    first item magic=\(first.magic) headerLen=\(first.headerLen) mhods=\(first.children.count) totalLen=\(first.byteLength)")
            }
        }
    } catch { print("ERROR: \(error)") }
    exit(0)
}

// artwork-dump: parse the device ArtworkDB, validate byte-exact round-trip,
// and report the image formats (dimensions/size/offset) it actually uses.
if args.first == "artwork-dump" {
    guard let dev = IPodDetector().currentDevices().first else { print("No iPod connected."); exit(1) }
    func le16(_ a: [UInt8], _ o: Int) -> Int { (o+2<=a.count) ? Int(a[o]) | (Int(a[o+1])<<8) : 0 }
    let url = dev.controlDir.appendingPathComponent("Artwork/ArtworkDB")
    do {
        let data = try Data(contentsOf: url)
        let src = [UInt8](data)
        let root = try ChunkParser(src).parse()
        let out = ChunkSerializer().serialize(root)
        print("ArtworkDB: \(src.count) bytes, magic=\(root.magic), children=\(root.children.count)")
        print("round-trip exact: \(out == src ? "PASS ✅" : "FAIL ❌ (\(out.count) vs \(src.count))")")
        for mhsd in root.children where mhsd.magic == "mhsd" {
            let index = le16(mhsd.header, 12)
            let lh = mhsd.children.first
            print("mhsd index=\(index) listHeader=\(lh?.magic ?? "?") items=\(lh?.children.count ?? 0)")
            if let mhii = lh?.children.first(where: { $0.magic == "mhii" }) {
                var tally: [String: Int] = [:]
                for c in mhii.children { tally[c.magic, default: 0] += 1 }
                print("  first mhii: image_id=\(mhii.u32(at: 0x10)) song_id=\(String(mhii.u64(at: 0x14), radix:16)) children=\(tally)")
                for mhni in mhii.descendants("mhni") {
                    let mhodChildren = mhni.children.map { $0.magic }
                    print("    mhni format=\(mhni.u32(at: 0x10)) offset=\(mhni.u32(at: 0x14)) size=\(mhni.u32(at: 0x18)) h=\(mhni.u16(at: 0x20)) w=\(mhni.u16(at: 0x22)) hdrLen=\(mhni.headerLen) children=\(mhodChildren)")
                }
            }
            if let mhif = lh?.children.first(where: { $0.magic == "mhif" }) {
                for f in lh!.children where f.magic == "mhif" {
                    print("  mhif format=\(f.u32(at: 0x10)) image_size=\(f.u32(at: 0x14))")
                }
                _ = mhif
            }
        }
    } catch { print("ERROR: \(error)") }
    exit(0)
}

if args.first == "mpl-mhods" {
    guard let dev = IPodDetector().currentDevices().first else { print("No iPod connected."); exit(1) }
    do {
        let db = try ITunesDB.read(from: dev)
        guard let mpl = db.masterPlaylist else { print("no MPL"); exit(0) }
        let mhods = mpl.children.filter { $0.magic == "mhod" }
        print("MPL mhods: \(mhods.count), mhips: \(mpl.children.filter { $0.magic == "mhip" }.count)")
        func le(_ a: [UInt8], _ o: Int) -> UInt32 {
            (o + 4 <= a.count) ? UInt32(a[o]) | (UInt32(a[o+1])<<8) | (UInt32(a[o+2])<<16) | (UInt32(a[o+3])<<24) : 0
        }
        for m in mhods {
            let type = m.u32(at: 12)
            let sortType = le(m.trailing, 0)
            let count = le(m.trailing, 4)
            print("  mhod type=\(type) sortType=0x\(String(sortType, radix:16)) count=\(count) totalLen=\(m.byteLength)")
        }
    } catch { print("ERROR: \(error)") }
    exit(0)
}

// reindex: rebuild the master-playlist sort indices on the connected iPod,
// validate them structurally, then re-checksum and write. Fixes tracks that
// were added to the DB but are missing from the browse indices.
// compare-index <dbpath>: decode the title type-52 index from a database and
// print titles in that index order, to confirm the index = 0-based positions
// into the track list sorted alphabetically.
if args.first == "compare-index", args.count >= 2 {
    func le(_ a: [UInt8], _ o: Int) -> UInt32 {
        UInt32(a[o]) | (UInt32(a[o+1])<<8) | (UInt32(a[o+2])<<16) | (UInt32(a[o+3])<<24)
    }
    do {
        let db = try ITunesDB.parse(try Data(contentsOf: URL(fileURLWithPath: args[1])))
        let tracks = db.tracks
        print("tracks: \(tracks.count)")
        guard let mpl = db.masterPlaylist else { print("no MPL"); exit(1) }
        for m in mpl.children where m.magic == "mhod" && m.u32(at: 12) == 52 && le(m.trailing, 0) == 0x03 {
            let count = Int(le(m.trailing, 4))
            var positions: [Int] = []
            for i in 0..<count { positions.append(Int(le(m.trailing, 48 + i*4))) }
            let inRange = positions.allSatisfy { $0 < tracks.count }
            let isPerm = Set(positions).count == count && count == tracks.count
            print("title index: count=\(count) inRange=\(inRange) permutation=\(isPerm)")
            print("first 15 titles in index order (should be ~alphabetical):")
            for p in positions.prefix(15) where p < tracks.count {
                print("   [\(p)] \(tracks[p].title)")
            }
            break
        }
    } catch { print("ERROR: \(error)") }
    exit(0)
}

// diff-mhit <id1> <id2>: compare the full mhit header bytes of two tracks,
// highlighting offsets that differ (to spot unique fields not changed on insert).
if args.first == "diff-mhit", args.count >= 3 {
    guard let dev = IPodDetector().currentDevices().first else { print("No iPod connected."); exit(1) }
    let id1 = UInt32(args[1]) ?? 0, id2 = UInt32(args[2]) ?? 0
    do {
        let db = try ITunesDB.read(from: dev)
        let mhits = db.trackChunks
        guard let a = mhits.first(where: { $0.u32(at: 16) == id1 }),
              let b = mhits.first(where: { $0.u32(at: 16) == id2 }) else { print("track not found"); exit(1) }
        print("mhit \(id1): headerLen=\(a.headerLen) mhods=\(a.children.count)")
        print("mhit \(id2): headerLen=\(b.headerLen) mhods=\(b.children.count)")
        let n = min(a.header.count, b.header.count)
        print("differing 4-byte words (offset: id\(id1)  id\(id2)):")
        var off = 0
        while off + 4 <= n {
            let va = a.u32(at: off), vb = b.u32(at: off)
            if va != vb {
                print(String(format: "  0x%02x: %08x  %08x", off, va, vb))
            }
            off += 4
        }
        print("--- bytes IDENTICAL beyond 0x70 (potential shared unique fields) ---")
        off = 0x78
        while off + 4 <= n {
            let va = a.u32(at: off), vb = b.u32(at: off)
            if va == vb && va != 0 {
                print(String(format: "  0x%02x: %08x (same, nonzero)", off, va))
            }
            off += 4
        }
    } catch { print("ERROR: \(error)") }
    exit(0)
}

// repair-dbid: fix tracks whose secondary persistent-id copy (0xA8) doesn't
// match the primary (0x70) — the cause of cloned tracks being deduped away.
// rename <trackid> <newtitle>: change an EXISTING track's title. Diagnostic to
// confirm whether the iPod re-reads our modified iTunesDB at all.
if args.first == "rename", args.count >= 3 {
    guard let dev = IPodDetector().currentDevices().first else { print("No iPod connected."); exit(1) }
    let id = UInt32(args[1]) ?? 0
    let newTitle = args[2]
    do {
        let db = try ITunesDB.read(from: dev)
        guard let mhit = db.trackChunks.first(where: { $0.u32(at: 16) == id }) else { print("track \(id) not found"); exit(1) }
        guard let titleMhod = mhit.children.first(where: { $0.magic == "mhod" && $0.u32(at: 12) == 1 }) else { print("no title mhod"); exit(1) }
        let utf16 = Array(newTitle.utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        var body: [UInt8] = []
        func u32(_ v: UInt32) { for i in 0..<4 { body.append(UInt8((v >> (8*UInt32(i))) & 0xff)) } }
        u32(1); u32(UInt32(utf16.count)); u32(1); u32(0); body.append(contentsOf: utf16)
        titleMhod.trailing = body
        db.rebuildIndexes()
        let scheme = ChecksumScheme.detect(in: db)
        var bytes = db.serialize()
        try scheme.apply(to: &bytes, firewireGUID: dev.firewireGUID)
        try Data(bytes).write(to: dev.iTunesDBURL)
        print("renamed track \(id) -> \"\(newTitle)\", wrote \(bytes.count) bytes")
        verifyHash58(try ITunesDB.read(from: dev), guid: dev.firewireGUID ?? "")
    } catch { print("ERROR: \(error)") }
    exit(0)
}

// dup-track <srcid> <newtitle>: append an EXACT clone of an existing track
// (same file/size/length/fields), changing only id, dbid and title. Isolates
// whether appended entries display at all vs. a field we set on real adds.
if args.first == "dup-track", args.count >= 3 {
    guard let dev = IPodDetector().currentDevices().first else { print("No iPod connected."); exit(1) }
    let srcId = UInt32(args[1]) ?? 0
    let newTitle = args[2]
    do {
        let db = try ITunesDB.read(from: dev)
        guard let mhlt = db.trackListHeader, let src = db.trackChunks.first(where: { $0.u32(at: 16) == srcId }) else { print("src not found"); exit(1) }
        guard let mpl = db.masterPlaylist, let tmplIp = mpl.children.first(where: { $0.magic == "mhip" }) else { print("no MPL"); exit(1) }
        let dup = src.deepCopy()
        let newId = db.nextTrackId
        let srcDbid = src.u64(at: 0x70)
        let newDbid = UInt64.random(in: 1...UInt64.max)
        var off = 0
        while off + 8 <= dup.header.count { if dup.u64(at: off) == srcDbid { dup.setU64(at: off, newDbid) }; off += 4 }
        dup.setU32(at: 0x10, newId)
        if let tm = dup.children.first(where: { $0.magic == "mhod" && $0.u32(at: 12) == 1 }) {
            let utf16 = Array(newTitle.utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
            var body: [UInt8] = []
            func u32(_ v: UInt32) { for i in 0..<4 { body.append(UInt8((v >> (8*UInt32(i))) & 0xff)) } }
            u32(1); u32(UInt32(utf16.count)); u32(1); u32(0); body.append(contentsOf: utf16)
            tm.trailing = body
        }
        mhlt.children.append(dup)
        let ip = tmplIp.deepCopy()
        ip.setU32(at: 0x18, newId)
        mpl.children.append(ip)
        mpl.setU32(at: 0x10, UInt32(mpl.children.filter { $0.magic == "mhip" }.count))
        db.rebuildIndexes()
        let scheme = ChecksumScheme.detect(in: db)
        var bytes = db.serialize()
        try scheme.apply(to: &bytes, firewireGUID: dev.firewireGUID)
        try Data(bytes).write(to: dev.iTunesDBURL)
        print("duplicated track \(srcId) as id \(newId) titled \"\(newTitle)\", wrote \(bytes.count) bytes")
        verifyHash58(try ITunesDB.read(from: dev), guid: dev.firewireGUID ?? "")
    } catch { print("ERROR: \(error)") }
    exit(0)
}

if args.first == "repair-dbid" {
    guard let dev = IPodDetector().currentDevices().first else { print("No iPod connected."); exit(1) }
    do {
        let db = try ITunesDB.read(from: dev)
        let scheme = ChecksumScheme.detect(in: db)
        var fixed = 0
        for mhit in db.trackChunks {
            let primary = mhit.u64(at: 0x70)
            if mhit.u64(at: 0xA8) != primary {
                mhit.setU64(at: 0xA8, primary)
                fixed += 1
            }
        }
        print("tracks=\(db.trackChunks.count) scheme=\(scheme.label) fixed dbid mismatches=\(fixed)")
        guard fixed > 0 else { print("nothing to fix"); exit(0) }
        var bytes = db.serialize()
        try scheme.apply(to: &bytes, firewireGUID: dev.firewireGUID)
        try Data(bytes).write(to: dev.iTunesDBURL)
        print("wrote \(bytes.count) bytes")
        let after = try ITunesDB.read(from: dev)
        verifyHash58(after, guid: dev.firewireGUID ?? "")
    } catch { print("ERROR: \(error)") }
    exit(0)
}

// sync-masters: add missing tracks to every master playlist, rebuild all
// indices, re-checksum and write. Repairs tracks added to only one master.
if args.first == "sync-masters" {
    guard let dev = IPodDetector().currentDevices().first else { print("No iPod connected."); exit(1) }
    func le(_ a: [UInt8], _ o: Int) -> UInt32 { (o+4<=a.count) ? UInt32(a[o]) | (UInt32(a[o+1])<<8) | (UInt32(a[o+2])<<16) | (UInt32(a[o+3])<<24) : 0 }
    do {
        let db = try ITunesDB.read(from: dev)
        let scheme = ChecksumScheme.detect(in: db)
        let added = db.syncMasterPlaylists()
        db.rebuildIndexes()
        print("tracks=\(db.trackChunks.count) scheme=\(scheme.label) mhips added=\(added)")
        for mpl in db.masterPlaylists {
            let mhips = mpl.children.filter { $0.magic == "mhip" }.count
            let counts = Set(mpl.children.filter { $0.magic == "mhod" && $0.u32(at: 12) == 52 }.map { Int(le($0.trailing, 4)) })
            print("  master playlist: mhips=\(mhips) index counts=\(counts)")
        }
        var bytes = db.serialize()
        try scheme.apply(to: &bytes, firewireGUID: dev.firewireGUID)
        try Data(bytes).write(to: dev.iTunesDBURL)
        print("wrote \(bytes.count) bytes")
        verifyHash58(try ITunesDB.read(from: dev), guid: dev.firewireGUID ?? "")
    } catch { print("ERROR: \(error)") }
    exit(0)
}

// delete-track <id>: remove a track from the DB (not the audio file).
if args.first == "delete-track", args.count >= 2 {
    guard let dev = IPodDetector().currentDevices().first else { print("No iPod connected."); exit(1) }
    let id = UInt32(args[1]) ?? 0
    do {
        let db = try ITunesDB.read(from: dev)
        let scheme = ChecksumScheme.detect(in: db)
        let path = db.deleteTrack(id: id)
        db.rebuildIndexes()
        var bytes = db.serialize()
        try scheme.apply(to: &bytes, firewireGUID: dev.firewireGUID)
        try Data(bytes).write(to: dev.iTunesDBURL)
        print("deleted track \(id) (path \(path ?? "?")); tracks now \(db.trackChunks.count); wrote \(bytes.count) bytes")
        verifyHash58(try ITunesDB.read(from: dev), guid: dev.firewireGUID ?? "")
    } catch { print("ERROR: \(error)") }
    exit(0)
}

if args.first == "reindex" {
    guard let dev = IPodDetector().currentDevices().first else { print("No iPod connected."); exit(1) }
    func le(_ a: [UInt8], _ o: Int) -> UInt32 {
        UInt32(a[o]) | (UInt32(a[o+1])<<8) | (UInt32(a[o+2])<<16) | (UInt32(a[o+3])<<24)
    }
    do {
        let db = try ITunesDB.read(from: dev)
        let n = db.trackChunks.count
        let scheme = ChecksumScheme.detect(in: db)
        print("tracks=\(n) scheme=\(scheme.label)")
        db.rebuildIndexes()

        // Validate: every type-52 must be a permutation of 0..<n; every type-53
        // must cover all n entries with contiguous starts.
        guard let mpl = db.masterPlaylist else { print("no MPL"); exit(1) }
        var ok = true
        for m in mpl.children where m.magic == "mhod" {
            let t = m.u32(at: 12); let sortRaw = le(m.trailing, 0); let count = Int(le(m.trailing, 4))
            if t == 52 {
                var seen = Set<UInt32>()
                let base = 48
                for i in 0..<count { seen.insert(le(m.trailing, base + i*4)) }
                let perm = (count == n) && (seen.count == n) && (seen.allSatisfy { $0 < UInt32(n) })
                if !perm { ok = false; print("  BAD type52 sort=0x\(String(sortRaw,radix:16)) count=\(count) unique=\(seen.count)") }
            } else if t == 53 {
                var total: UInt32 = 0; var pos: UInt32 = 0; var contiguous = true
                let base = 16
                for i in 0..<count {
                    let start = le(m.trailing, base + i*12 + 4)
                    let c = le(m.trailing, base + i*12 + 8)
                    if start != pos { contiguous = false }
                    pos += c; total += c
                }
                if total != UInt32(n) || !contiguous { ok = false; print("  BAD type53 sort=0x\(String(sortRaw,radix:16)) total=\(total) contiguous=\(contiguous)") }
            }
        }
        guard ok else { print("VALIDATION FAILED — not writing"); exit(1) }
        print("validation OK — all indices are complete permutations")

        var bytes = db.serialize()
        try scheme.apply(to: &bytes, firewireGUID: dev.firewireGUID)
        // backup current then write
        let dbURL = dev.iTunesDBURL
        let bak = dev.iTunesDir.appendingPathComponent("iTunesDB.prereindex-backup")
        if !FileManager.default.fileExists(atPath: bak.path) { try? FileManager.default.copyItem(at: dbURL, to: bak) }
        try Data(bytes).write(to: dbURL)
        print("wrote \(bytes.count) bytes. Reading back…")
        let after = try ITunesDB.read(from: dev)
        verifyHash58(after, guid: dev.firewireGUID ?? "")
    } catch { print("ERROR: \(error)") }
    exit(0)
}

if args.first == "add", args.count >= 2 {
    let files = args.dropFirst().map { URL(fileURLWithPath: $0) }
    guard let dev = IPodDetector().currentDevices().first else {
        print("No iPod connected."); exit(1)
    }
    print("Writing \(files.count) file(s) to \(dev.displayName) @ \(dev.mountPoint.path)")
    Task {
        defer { exit(0) }
        do {
            let result = try await SyncEngine(device: dev).add(files: files)
            print("  added: \(result.added)")
            if !result.skipped.isEmpty { print("  skipped: \(result.skipped)") }
            // Re-read to confirm the on-disk DB is valid and contains the track.
            let db = try ITunesDB.read(from: dev)
            print("  on-device track count now: \(db.tracks.count)")
            verifyHash58(db, guid: dev.firewireGUID ?? "")
        } catch {
            print("  ERROR: \(error)")
        }
    }
    RunLoop.main.run()
}

if let path = args.first {
    let url = URL(fileURLWithPath: path)
    do {
        let db = try ITunesDB.parse(try Data(contentsOf: url))
        print("FILE: \(path)")
        analyze(db, label: path)
        if let g = overrideGUID { verifyHash58(db, guid: g) }
    } catch {
        print("ERROR reading \(path): \(error)")
        exit(1)
    }
} else {
    let devices = IPodDetector().currentDevices()
    if devices.isEmpty {
        print("No iPod detected. Connect an iPod and enable disk use, then re-run.")
        exit(0)
    }
    for dev in devices {
        print("════════════════════════════════════════════")
        print("iPod: \(dev.displayName)  @ \(dev.mountPoint.path)")
        print("  model:   \(dev.modelNumber ?? "?")")
        print("  serial:  \(dev.serialNumber ?? "?")")
        print("  fwGUID:  \(dev.firewireGUID ?? "?")")
        print("  family:  \(dev.family)")
        print("  iTunesDB:\(dev.iTunesDBURL.path)")
        do {
            let db = try ITunesDB.read(from: dev)
            analyze(db, label: dev.displayName)
            if let g = overrideGUID ?? dev.firewireGUID { verifyHash58(db, guid: g) }
        } catch {
            print("  ERROR reading iTunesDB: \(error)")
        }
    }
}
