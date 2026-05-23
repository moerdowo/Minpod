import Foundation

/// A node in the iTunesDB chunk tree.
///
/// Every chunk begins with a 4-byte ASCII magic ("mh.."), a 4-byte header
/// length, and (for most chunk types) a 4-byte total length. We deliberately
/// keep the raw `header` bytes and any `trailing` bytes verbatim so an
/// unmodified tree re-serializes byte-for-byte identically to the source file.
/// That round-trip property is how we validate the format against real hardware
/// before trusting any write.
public final class Chunk {
    public let magic: String
    /// Raw header bytes (length == declared header length). Starts with magic.
    public var header: [UInt8]
    public var children: [Chunk]
    /// Bytes after the last child up to the chunk's end (padding / leaf payload).
    public var trailing: [UInt8]
    /// Chunks whose 3rd word is a "total length" enclosing children. The
    /// list-header chunks (mhlt/mhlp/mhla) instead store a count there and own
    /// their items as direct children.
    public let hasTotalLen: Bool

    public init(magic: String, header: [UInt8], children: [Chunk], trailing: [UInt8], hasTotalLen: Bool) {
        self.magic = magic
        self.header = header
        self.children = children
        self.trailing = trailing
        self.hasTotalLen = hasTotalLen
    }

    /// Magics that are "header + count of following sibling items" rather than
    /// total-length containers. Includes ArtworkDB list headers (mhli/mhlf).
    public static let countHeaders: Set<String> = ["mhlt", "mhlp", "mhla", "mhsp", "mhli", "mhlf"]
    /// Leaf chunks that carry an opaque data payload (no sub-chunks).
    public static let leafChunks: Set<String> = ["mhod"]

    public var headerLen: Int { Int(le32(header, 4)) }

    /// Total serialized size of this chunk including all descendants.
    public var byteLength: Int {
        header.count + children.reduce(0) { $0 + $1.byteLength } + trailing.count
    }

    // MARK: Header field access (little-endian)

    public func u32(at offset: Int) -> UInt32 {
        guard offset + 4 <= header.count else { return 0 }
        return le32(header, offset)
    }

    public func setU32(at offset: Int, _ value: UInt32) {
        guard offset + 4 <= header.count else { return }
        for i in 0..<4 { header[offset + i] = UInt8((value >> (8 * i)) & 0xff) }
    }

    public func setU8(at offset: Int, _ value: UInt8) {
        guard offset < header.count else { return }
        header[offset] = value
    }

    public func setU16(at offset: Int, _ value: UInt16) {
        guard offset + 2 <= header.count else { return }
        header[offset] = UInt8(value & 0xff)
        header[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    public func setU64(at offset: Int, _ value: UInt64) {
        guard offset + 8 <= header.count else { return }
        for i in 0..<8 { header[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(i))) }
    }

    /// Recursively clone this chunk (header/trailing arrays are value types).
    public func deepCopy() -> Chunk {
        Chunk(magic: magic, header: header,
              children: children.map { $0.deepCopy() },
              trailing: trailing, hasTotalLen: hasTotalLen)
    }

    public func u16(at offset: Int) -> UInt16 {
        guard offset + 2 <= header.count else { return 0 }
        return UInt16(header[offset]) | (UInt16(header[offset + 1]) << 8)
    }

    public func u64(at offset: Int) -> UInt64 {
        guard offset + 8 <= header.count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(header[offset + i]) << (8 * i) }
        return v
    }

    public func firstChild(_ magic: String) -> Chunk? {
        children.first { $0.magic == magic }
    }

    public func descendants(_ magic: String) -> [Chunk] {
        var out: [Chunk] = []
        for c in children {
            if c.magic == magic { out.append(c) }
            out.append(contentsOf: c.descendants(magic))
        }
        return out
    }
}

@inline(__always)
func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
}
