import Foundation

public enum ChunkParseError: Error, CustomStringConvertible {
    case truncated
    case badMagic(String)

    public var description: String {
        switch self {
        case .truncated: return "iTunesDB ended unexpectedly (truncated)"
        case .badMagic(let m): return "Unexpected chunk magic: \(m)"
        }
    }
}

/// Recursive-descent parser that turns raw iTunesDB bytes into a Chunk tree.
public struct ChunkParser {
    let bytes: [UInt8]

    public init(_ data: Data) { self.bytes = [UInt8](data) }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public func parse() throws -> Chunk {
        var pos = 0
        let root = try parseChunk(&pos)
        return root
    }

    @inline(__always)
    private func looksLikeChunk(at pos: Int) -> Bool {
        pos + 4 <= bytes.count && bytes[pos] == 0x6d /* m */ && bytes[pos + 1] == 0x68 /* h */
    }

    private func parseChunk(_ pos: inout Int) throws -> Chunk {
        guard pos + 12 <= bytes.count else { throw ChunkParseError.truncated }
        let magic = String(bytes: bytes[pos..<pos + 4], encoding: .ascii) ?? "????"
        let headerLen = Int(le32(bytes, pos + 4))
        guard headerLen >= 8, pos + headerLen <= bytes.count else { throw ChunkParseError.truncated }
        let header = Array(bytes[pos..<pos + headerLen])

        // List headers: "magic, headerLen, count" — the count items follow as
        // this chunk's children, sized by their own total lengths.
        if Chunk.countHeaders.contains(magic) {
            let count = Int(le32(bytes, pos + 8))
            var childPos = pos + headerLen
            var children: [Chunk] = []
            children.reserveCapacity(count)
            for _ in 0..<count {
                guard looksLikeChunk(at: childPos) else { break }
                children.append(try parseChunk(&childPos))
            }
            pos = childPos
            return Chunk(magic: magic, header: header, children: children, trailing: [], hasTotalLen: false)
        }

        // Everything else carries a total length at offset 8.
        let totalLen = Int(le32(bytes, pos + 8))
        guard totalLen >= headerLen, pos + totalLen <= bytes.count else { throw ChunkParseError.truncated }
        let end = pos + totalLen

        if Chunk.leafChunks.contains(magic) {
            let trailing = Array(bytes[pos + headerLen..<end])
            pos = end
            return Chunk(magic: magic, header: header, children: [], trailing: trailing, hasTotalLen: true)
        }

        var childPos = pos + headerLen
        var children: [Chunk] = []
        while childPos < end && looksLikeChunk(at: childPos) {
            let before = childPos
            children.append(try parseChunk(&childPos))
            if childPos <= before { break } // guard against zero-progress
        }
        let trailing = Array(bytes[childPos..<end])
        pos = end
        return Chunk(magic: magic, header: header, children: children, trailing: trailing, hasTotalLen: true)
    }
}
