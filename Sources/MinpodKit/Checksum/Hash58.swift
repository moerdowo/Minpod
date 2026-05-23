import Foundation
import CryptoKit

/// iTunesDB "hash58" checksum, required by iPod classic (all gens) and
/// nano 3G/4G. Reimplemented from libgpod's BSD-licensed itdb_hash58.c.
///
/// It is an HMAC-SHA1 over the whole database (with a few header fields zeroed),
/// keyed by a value derived from the device's FireWire GUID through two AES
/// S-box lookups.
public enum Hash58 {
    // MhbdHeader field offsets that participate in the checksum.
    public static let offDBID = 0x18          // 8 bytes — zeroed during hashing
    public static let offHashingScheme = 0x30 // 2 bytes — set to 1
    public static let offUnk32 = 0x32         // 20 bytes — zeroed during hashing
    public static let offHash58 = 0x58        // 20 bytes — result lands here

    static func sha1(_ bytes: [UInt8]) -> [UInt8] {
        var h = Insecure.SHA1()
        h.update(data: Data(bytes))
        return Array(h.finalize())
    }

    private static func gcd(_ a0: Int, _ b0: Int) -> Int {
        var a = a0, b = b0
        while true {
            a = a % b; if a == 0 { return b }
            b = b % a; if b == 0 { return a }
        }
    }

    private static func lcm(_ a: Int, _ b: Int) -> Int {
        if a == 0 || b == 0 { return 1 }
        return (a * b) / gcd(a, b)
    }

    /// Build the 64-byte HMAC key block from the 8-byte FireWire GUID.
    static func generateKey(_ fw: [UInt8]) -> [UInt8] {
        var y = [UInt8](repeating: 0, count: 16)
        for i in 0..<4 {
            let a = Int(fw[i * 2])
            let b = Int(fw[i * 2 + 1])
            let curLcm = lcm(a, b)
            let hi = Int((curLcm >> 8) & 0xff)
            let lo = Int(curLcm & 0xff)
            y[i * 4]     = hash58Table1[hi]
            y[i * 4 + 1] = hash58Table2[hi]
            y[i * 4 + 2] = hash58Table1[lo]
            y[i * 4 + 3] = hash58Table2[lo]
        }
        var key = [UInt8](repeating: 0, count: 64)
        let digest = sha1(hash58Fixed + y) // 20 bytes
        for i in 0..<digest.count { key[i] = digest[i] }
        return key
    }

    /// HMAC-SHA1(K, itdb) using the derived 64-byte key block.
    static func computeHash(firewireGUID fw: [UInt8], itdb: [UInt8]) -> [UInt8] {
        var key = generateKey(fw)
        for i in 0..<64 { key[i] ^= 0x36 }
        let inner = sha1(key + itdb)
        for i in 0..<64 { key[i] ^= (0x36 ^ 0x5c) }
        return sha1(key + inner)
    }

    /// Parse a 16-hex-char FireWire GUID string ("000A270013714700") into 8 bytes.
    public static func guidBytes(_ guid: String) -> [UInt8]? {
        let hex = guid.trimmingCharacters(in: .whitespaces)
        guard hex.count == 16 else { return nil }
        var out: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }

    /// Compute and write the hash58 into a serialized iTunesDB buffer in place.
    /// Zeroes db_id/unk_0x32/hash58 only for the calculation, then restores the
    /// preserved db_id/unk_0x32 (matching iTunes/libgpod behavior).
    public static func writeHash(into bytes: inout [UInt8], firewireGUID guid: String) throws {
        guard bytes.count >= 0x6c else { throw ChecksumError.tooSmall }
        guard let fw = guidBytes(guid) else { throw ChecksumError.badGUID(guid) }

        let backupDBID = Array(bytes[offDBID..<offDBID + 8])
        let backupUnk32 = Array(bytes[offUnk32..<offUnk32 + 20])

        for i in offDBID..<offDBID + 8 { bytes[i] = 0 }
        for i in offUnk32..<offUnk32 + 20 { bytes[i] = 0 }
        for i in offHash58..<offHash58 + 20 { bytes[i] = 0 }
        bytes[offHashingScheme] = 0x01
        bytes[offHashingScheme + 1] = 0x00

        let hash = computeHash(firewireGUID: fw, itdb: bytes)

        for i in 0..<8 { bytes[offDBID + i] = backupDBID[i] }
        for i in 0..<20 { bytes[offUnk32 + i] = backupUnk32[i] }
        for i in 0..<20 { bytes[offHash58 + i] = hash[i] }
    }
}

public enum ChecksumError: Error, CustomStringConvertible {
    case tooSmall
    case badGUID(String)
    case missingGUID

    public var description: String {
        switch self {
        case .tooSmall: return "iTunesDB too small to hold a checksum"
        case .badGUID(let g): return "Invalid FireWire GUID: \(g)"
        case .missingGUID: return "Device FireWire GUID is unknown; cannot compute checksum"
        }
    }
}
