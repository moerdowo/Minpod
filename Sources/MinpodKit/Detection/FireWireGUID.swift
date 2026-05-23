import Foundation
import IOKit

/// Reads an iPod's FireWire GUID from the USB registry. On modern iPods the
/// on-disk SysInfo file is often empty, but the 64-bit GUID is exposed as the
/// device's USB serial number (e.g. "000A270013714700").
enum FireWireGUID {
    static func lookup() -> String? {
        for className in ["IOUSBHostDevice", "IOUSBDevice"] {
            if let guid = scan(serviceClass: className) { return guid }
        }
        return nil
    }

    private static func scan(serviceClass: String) -> String? {
        guard let matching = IOServiceMatching(serviceClass) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            let product = property(service, "USB Product Name")
            let vendor = property(service, "USB Vendor Name")
            let serial = property(service, "USB Serial Number")
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)

            guard let serial, isGUID(serial) else { continue }
            let isApple = (vendor?.localizedCaseInsensitiveContains("apple") ?? false)
            let isIPod = (product?.localizedCaseInsensitiveContains("ipod") ?? false)
            if isApple || isIPod { return serial.uppercased() }
        }
        return nil
    }

    private static func property(_ service: io_object_t, _ key: String) -> String? {
        guard let ref = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return ref.takeRetainedValue() as? String
    }

    /// 16 hexadecimal characters.
    private static func isGUID(_ s: String) -> Bool {
        s.count == 16 && s.allSatisfy { $0.isHexDigit }
    }
}
