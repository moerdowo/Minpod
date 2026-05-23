import Foundation

/// Little-endian cursor over a byte buffer. The iTunesDB format is entirely
/// little-endian, so every integer read advances the cursor by its width.
public final class ByteReader {
    public let data: [UInt8]
    public private(set) var offset: Int

    public init(_ data: [UInt8], offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    public convenience init(_ data: Data, offset: Int = 0) {
        self.init([UInt8](data), offset: offset)
    }

    public var count: Int { data.count }
    public var remaining: Int { data.count - offset }
    public var isAtEnd: Bool { offset >= data.count }

    public func seek(to newOffset: Int) {
        offset = newOffset
    }

    public func skip(_ n: Int) {
        offset += n
    }

    public func peekMagic() -> String? {
        guard offset + 4 <= data.count else { return nil }
        return String(bytes: data[offset..<offset + 4], encoding: .ascii)
    }

    public func readMagic() -> String {
        let s = String(bytes: data[offset..<offset + 4], encoding: .ascii) ?? "????"
        offset += 4
        return s
    }

    public func readBytes(_ n: Int) -> [UInt8] {
        let slice = Array(data[offset..<offset + n])
        offset += n
        return slice
    }

    public func readUInt8() -> UInt8 {
        let v = data[offset]
        offset += 1
        return v
    }

    public func readUInt16() -> UInt16 {
        let v = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        offset += 2
        return v
    }

    public func readUInt32() -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(data[offset + i]) << (8 * i) }
        offset += 4
        return v
    }

    public func readUInt64() -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[offset + i]) << (8 * i) }
        offset += 8
        return v
    }
}
