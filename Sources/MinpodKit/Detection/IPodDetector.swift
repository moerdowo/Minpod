import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Watches for mounted iPod volumes and reports the current set.
public final class IPodDetector {
    public var onChange: (([IPodDevice]) -> Void)?

    public init() {}

    public func start() {
        #if canImport(AppKit)
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumesChanged),
                       name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged),
                       name: NSWorkspace.didUnmountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged),
                       name: NSWorkspace.didRenameVolumeNotification, object: nil)
        #endif
    }

    @objc private func volumesChanged() {
        onChange?(currentDevices())
    }

    public func currentDevices() -> [IPodDevice] {
        let fm = FileManager.default
        let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                        options: [.skipHiddenVolumes]) ?? []
        var devices: [IPodDevice] = []
        for url in urls {
            let control = url.appendingPathComponent("iPod_Control")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: control.path, isDirectory: &isDir), isDir.boolValue else { continue }
            devices.append(makeDevice(at: url))
        }
        return devices
    }

    private func makeDevice(at url: URL) -> IPodDevice {
        let resolvedName = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? nil
        let name = resolvedName ?? url.lastPathComponent
        let deviceDir = url.appendingPathComponent("iPod_Control/Device")
        let info = DeviceInfo.read(deviceDir: deviceDir)
        // SysInfo is frequently empty on modern iPods; fall back to the USB GUID.
        let guid = info.firewireGUID ?? FireWireGUID.lookup()
        return IPodDevice(
            mountPoint: url,
            volumeName: name,
            firewireGUID: guid,
            modelNumber: info.modelNumber,
            serialNumber: info.serialNumber,
            family: IPodModelTable.family(modelNumber: info.modelNumber, hasSysInfoExtended: info.hasSysInfoExtended)
        )
    }
}

/// Reads FirewireGUID / model / serial from SysInfo (text) and SysInfoExtended (plist).
struct DeviceInfo {
    var firewireGUID: String?
    var modelNumber: String?
    var serialNumber: String?
    var hasSysInfoExtended: Bool

    static func read(deviceDir: URL) -> DeviceInfo {
        var out = DeviceInfo(firewireGUID: nil, modelNumber: nil, serialNumber: nil, hasSysInfoExtended: false)

        // Plain-text SysInfo: "FirewireGuid: 0x000A2700..." etc.
        if let text = try? String(contentsOf: deviceDir.appendingPathComponent("SysInfo"), encoding: .utf8) {
            for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let key = parts[0].lowercased()
                let value = parts[1]
                switch key {
                case "firewireguid": out.firewireGUID = normalizeGUID(value)
                case "modelnumstr": out.modelNumber = normalizeModel(value)
                case "pszserialnumber", "serialnumber": out.serialNumber = value
                default: break
                }
            }
        }

        // XML plist SysInfoExtended overrides/fills gaps.
        let extURL = deviceDir.appendingPathComponent("SysInfoExtended")
        if let data = try? Data(contentsOf: extURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            out.hasSysInfoExtended = true
            if let g = plist["FireWireGUID"] as? String { out.firewireGUID = normalizeGUID(g) }
            if let m = plist["ModelNumber"] as? String { out.modelNumber = normalizeModel(m) }
            if let s = plist["SerialNumber"] as? String { out.serialNumber = s }
        }
        return out
    }

    private static func normalizeGUID(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("0X") { s.removeFirst(2) }
        return s
    }

    private static func normalizeModel(_ raw: String) -> String {
        // SysInfo often stores model as "xMA002xx"; strip leading 'x' padding.
        var s = raw.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("x") || s.hasPrefix("X") { s.removeFirst() }
        return s
    }
}
