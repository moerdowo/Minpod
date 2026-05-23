import Foundation

/// Maps Apple model numbers to a coarse family. This is a best-effort hint; the
/// authoritative checksum scheme is confirmed by inspecting the device's own
/// iTunesDB header (see ChecksumScheme.detect).
enum IPodModelTable {
    // hash58 devices (late 2007): iPod classic 6G, iPod nano 3G.
    static let hash58Models: Set<String> = [
        "MB029", "MB147", "MB145", "MB565", // classic 6G 80/160GB
        "MA978", "MB261", "MB257", "MB249", "MB453", // nano 3G
    ]
    // hash72 devices (2008+): iPod classic 6.5G/7G, nano 4G/5G.
    static let hash72Models: Set<String> = [
        "MB562", "MB565", "MC293", "MC297", // classic 120/160GB
        "MB598", "MB732", "MB739", "MB903", // nano 4G
        "MC027", "MC031", "MC034", "MC037", "MC040", "MC046", "MC050", // nano 5G
    ]

    static func family(modelNumber: String?, hasSysInfoExtended: Bool) -> IPodFamily {
        if let m = modelNumber {
            if hash58Models.contains(m) { return .classic6 }
            if hash72Models.contains(m) { return .classic7 }
        }
        // Devices that ship a SysInfoExtended generally need a checksum; treat as
        // classic7 (most conservative) until the DB header says otherwise.
        return hasSysInfoExtended ? .classic7 : .unknown
    }
}
