import Foundation

/// A mounted iPod volume and its on-disk layout.
public struct IPodDevice: Identifiable, Hashable, Sendable {
    public let mountPoint: URL
    public let volumeName: String
    public let firewireGUID: String?    // hex string, e.g. "000A2700123456AB"
    public let modelNumber: String?     // e.g. "MA002" / "MB029"
    public let serialNumber: String?
    public let family: IPodFamily

    public var id: String { mountPoint.path }

    public var controlDir: URL { mountPoint.appendingPathComponent("iPod_Control") }
    public var iTunesDir: URL { controlDir.appendingPathComponent("iTunes") }
    public var iTunesDBURL: URL { iTunesDir.appendingPathComponent("iTunesDB") }
    public var musicDir: URL { controlDir.appendingPathComponent("Music") }
    public var deviceDir: URL { controlDir.appendingPathComponent("Device") }
    public var sysInfoURL: URL { deviceDir.appendingPathComponent("SysInfo") }
    public var sysInfoExtendedURL: URL { deviceDir.appendingPathComponent("SysInfoExtended") }

    public var displayName: String {
        if !volumeName.isEmpty { return volumeName }
        return family.label
    }

    public init(mountPoint: URL, volumeName: String, firewireGUID: String?,
                modelNumber: String?, serialNumber: String?, family: IPodFamily) {
        self.mountPoint = mountPoint
        self.volumeName = volumeName
        self.firewireGUID = firewireGUID
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.family = family
    }
}

/// Coarse model family — drives which checksum scheme the iTunesDB needs.
public enum IPodFamily: String, Sendable {
    case video        // 5G / 5.5G — no checksum
    case nanoOld      // Nano 1G/2G — no checksum
    case classic6     // Classic 6G, Nano 3G — hash58
    case classic7     // Classic 7G, Nano 4G+ — hash72
    case unknown

    public var label: String {
        switch self {
        case .video: return "iPod (Video)"
        case .nanoOld: return "iPod nano"
        case .classic6: return "iPod classic"
        case .classic7: return "iPod classic"
        case .unknown: return "iPod"
        }
    }
}
