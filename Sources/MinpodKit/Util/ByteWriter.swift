import Foundation

/// Little-endian byte buffer builder for serializing the iTunesDB.
public final class ByteWriter {
    public private(set) var bytes: [UInt8]

    public init(capacity: Int = 0) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public var count: Int { bytes.count }

    public func appendMagic(_ s: String) {
        let ascii = Array(s.utf8)
        precondition(ascii.count == 4, "magic must be 4 bytes: \(s)")
        bytes.append(contentsOf: ascii)
    }

    public func append(_ raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    public func appendUInt8(_ v: UInt8) {
        bytes.append(v)
    }

    public func appendUInt16(_ v: UInt16) {
        bytes.append(UInt8(v & 0xff))
        bytes.append(UInt8((v >> 8) & 0xff))
    }

    public func appendUInt32(_ v: UInt32) {
        for i in 0..<4 { bytes.append(UInt8((v >> (8 * i)) & 0xff)) }
    }

    public func appendUInt64(_ v: UInt64) {
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
    }

    /// Pad with zero bytes until the buffer length is a multiple of `alignment`.
    public func padTo(multipleOf alignment: Int) {
        while bytes.count % alignment != 0 { bytes.append(0) }
    }

    /// Append `n` zero bytes.
    public func appendZeros(_ n: Int) {
        guard n > 0 else { return }
        bytes.append(contentsOf: repeatElement(0, count: n))
    }

    /// Overwrite a little-endian UInt32 at an absolute offset (for backpatching
    /// length fields once the full size of a chunk is known).
    public func patchUInt32(at offset: Int, value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xff) }
    }

    public func patchBytes(at offset: Int, _ raw: [UInt8]) {
        for (i, b) in raw.enumerated() { bytes[offset + i] = b }
    }

    public var data: Data { Data(bytes) }
}
