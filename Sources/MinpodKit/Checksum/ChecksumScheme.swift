import Foundation

/// iTunesDB checksum scheme. The authoritative value for a given device is the
/// `hashing_scheme` field its own iTunes-written database already carries
/// (mhbd offset 0x30), so we read it rather than guessing from the model.
public enum ChecksumScheme: UInt16 {
    case none = 0
    case hash58 = 1
    case hash72 = 2
    case hashAB = 3

    public static let mhbdOffset = 0x30

    public static func detect(in db: ITunesDB) -> ChecksumScheme {
        ChecksumScheme(rawValue: db.root.u16(at: mhbdOffset)) ?? .none
    }

    public var isSupported: Bool {
        self == .none || self == .hash58
    }

    public var label: String {
        switch self {
        case .none: return "none"
        case .hash58: return "hash58"
        case .hash72: return "hash72"
        case .hashAB: return "hashAB"
        }
    }

    /// Apply the correct checksum to a serialized iTunesDB buffer in place.
    public func apply(to bytes: inout [UInt8], firewireGUID: String?) throws {
        switch self {
        case .none:
            return
        case .hash58:
            guard let guid = firewireGUID else { throw ChecksumError.missingGUID }
            try Hash58.writeHash(into: &bytes, firewireGUID: guid)
        case .hash72, .hashAB:
            throw ChecksumError.unsupported(label)
        }
    }
}
