import Foundation
import CoreGraphics

/// Writes album art into the iPod's ArtworkDB + .ithmb thumbnail files.
///
/// The ArtworkDB is a chunk tree (mhfd → mhsd → mhli → mhii → mhod → mhni →
/// mhod). For each new cover we clone an existing mhii (so the nested format
/// structure and filenames are exactly what this iPod expects), append the
/// converted RGB565 pixels to each .ithmb file, point the cloned mhni entries
/// at the new offsets, and link the image to the track via mhii.song_id (the
/// track's persistent dbid).
public struct ArtworkWriter {
    let device: IPodDevice
    let fm = FileManager.default

    public init(device: IPodDevice) { self.device = device }

    var artworkDir: URL { device.controlDir.appendingPathComponent("Artwork") }
    var artworkDBURL: URL { artworkDir.appendingPathComponent("ArtworkDB") }

    public var isAvailable: Bool { fm.fileExists(atPath: artworkDBURL.path) }

    // mhii / mhni / mhfd field offsets
    private enum O {
        static let mhfdNextId = 0x1C
        static let mhiiImageId = 0x10
        static let mhiiSongId = 0x14
        static let mhiiOrigImgSize = 0x30
        static let mhniFormat = 0x10
        static let mhniOffset = 0x14
        static let mhniSize = 0x18
        static let mhniVpad = 0x1C
        static let mhniHpad = 0x1E
        static let mhniHeight = 0x20
        static let mhniWidth = 0x22
    }

    /// Add cover art for each (track dbid, encoded image bytes). Returns the
    /// dbids that successfully got art.
    @discardableResult
    public func addImages(_ rawItems: [(dbid: UInt64, imageData: Data)]) throws -> [UInt64] {
        guard isAvailable, !rawItems.isEmpty else { return [] }
        let items: [(dbid: UInt64, image: CGImage, origSize: Int)] = rawItems.compactMap {
            guard let img = Artwork.decode($0.imageData) else { return nil }
            return ($0.dbid, img, $0.imageData.count)
        }
        guard !items.isEmpty else { return [] }
        let root = try ChunkParser([UInt8](Data(contentsOf: artworkDBURL))).parse()

        guard let imageList = root.children
                .first(where: { $0.magic == "mhsd" && $0.u16(at: 0x0C) == 1 })?
                .children.first(where: { $0.magic == "mhli" }),
              let template = imageList.children.first(where: { $0.magic == "mhii" }) else {
            return [] // no existing image to template from
        }

        // Read the thumbnail formats from the template's mhni entries.
        let formats = thumbnailFormats(of: template)
        guard !formats.isEmpty else { return [] }

        // Track append offset per .ithmb file (start at current file size).
        var offsets: [UInt32: UInt32] = [:]
        var handles: [UInt32: FileHandle] = [:]
        defer { for h in handles.values { try? h.close() } }
        for f in formats {
            let url = artworkDir.appendingPathComponent(f.ithmbFile)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            offsets[f.formatId] = UInt32(size ?? 0)
            handles[f.formatId] = try FileHandle(forWritingTo: url)
            try handles[f.formatId]?.seekToEnd()
        }

        var nextId = root.u32(at: O.mhfdNextId)
        var done: [UInt64] = []

        for item in items {
            let mhii = template.deepCopy()
            mhii.setU32(at: O.mhiiImageId, nextId)
            mhii.setU64(at: O.mhiiSongId, item.dbid)
            mhii.setU32(at: O.mhiiOrigImgSize, UInt32(item.origSize))

            for mhod in mhii.children where mhod.magic == "mhod" {
                guard mhod.trailing.count >= 0x24,
                      mhod.trailing[0] == 0x6d, mhod.trailing[1] == 0x68,
                      mhod.trailing[2] == 0x6e, mhod.trailing[3] == 0x69 else { continue } // "mhni"
                let formatId = le32(mhod.trailing, O.mhniFormat)
                guard let f = formats.first(where: { $0.formatId == formatId }),
                      let slot = Artwork.rgb565Slot(item.image, f) else { continue }
                let off = offsets[formatId] ?? 0
                try handles[formatId]?.write(contentsOf: Data(slot))
                offsets[formatId] = off + UInt32(f.imageSize)
                // patch ithmb_offset (mhni @0x14) inside this mhod's trailing
                for i in 0..<4 { mhod.trailing[O.mhniOffset + i] = UInt8((off >> (8 * UInt32(i))) & 0xff) }
            }

            imageList.children.append(mhii)
            nextId += 1
            done.append(item.dbid)
        }

        root.setU32(at: O.mhfdNextId, nextId)

        let bytes = ChunkSerializer().serialize(root)
        let backup = artworkDir.appendingPathComponent("ArtworkDB.minpod-backup")
        if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: artworkDBURL, to: backup) }
        let tmp = artworkDir.appendingPathComponent("ArtworkDB.minpod-tmp")
        try? fm.removeItem(at: tmp)
        try Data(bytes).write(to: tmp)
        _ = try fm.replaceItemAt(artworkDBURL, withItemAt: tmp)
        return done
    }

    private func thumbnailFormats(of mhii: Chunk) -> [ThumbFormat] {
        var out: [ThumbFormat] = []
        for mhod in mhii.children where mhod.magic == "mhod" {
            let t = mhod.trailing
            guard t.count >= 0x24, t[0] == 0x6d, t[1] == 0x68, t[2] == 0x6e, t[3] == 0x69 else { continue }
            let formatId = le32(t, O.mhniFormat)
            func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(t[o]) | (UInt16(t[o + 1]) << 8))) }
            out.append(ThumbFormat(
                formatId: formatId,
                contentWidth: i16(O.mhniWidth),
                contentHeight: i16(O.mhniHeight),
                vpad: i16(O.mhniVpad),
                hpad: i16(O.mhniHpad),
                imageSize: Int(le32(t, O.mhniSize)),
                ithmbFile: "F\(formatId)_1.ithmb"
            ))
        }
        return out
    }
}
