import Foundation

/// Serializes a Chunk tree back to iTunesDB bytes, recomputing the length and
/// count fields from the actual emitted layout. For an unmodified tree this
/// reproduces the source bytes exactly; after edits it produces a consistent
/// file with correct sizes/counts.
public struct ChunkSerializer {
    public init() {}

    public func serialize(_ root: Chunk) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(root.byteLength)
        emit(root, into: &out)
        return out
    }

    private func emit(_ chunk: Chunk, into out: inout [UInt8]) {
        let start = out.count
        out.append(contentsOf: chunk.header)
        for child in chunk.children { emit(child, into: &out) }
        out.append(contentsOf: chunk.trailing)
        let total = out.count - start

        if chunk.hasTotalLen {
            patch32(&out, at: start + 8, UInt32(total))
        } else {
            // list header: word at offset 8 is the item count
            patch32(&out, at: start + 8, UInt32(chunk.children.count))
        }
    }

    @inline(__always)
    private func patch32(_ out: inout [UInt8], at offset: Int, _ value: UInt32) {
        guard offset + 4 <= out.count else { return }
        for i in 0..<4 { out[offset + i] = UInt8((value >> (8 * i)) & 0xff) }
    }
}
