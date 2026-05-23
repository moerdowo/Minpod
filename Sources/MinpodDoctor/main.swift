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
