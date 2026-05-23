import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One iPod thumbnail format, as read from the device's own ArtworkDB.
public struct ThumbFormat: Sendable {
    public let formatId: UInt32
    public let contentWidth: Int
    public let contentHeight: Int
    public let vpad: Int
    public let hpad: Int
    public let imageSize: Int    // bytes per slot in the .ithmb file
    public let ithmbFile: String // e.g. "F1060_1.ithmb"

    public var destHeight: Int { contentHeight + vpad }
    public var destWidth: Int { imageSize / (destHeight * 2) }
}

public enum Artwork {
    /// Decode embedded cover-art bytes (JPEG/PNG/…) into a CGImage.
    public static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Render `image` into one .ithmb slot: RGB565 little-endian, `destWidth ×
    /// destHeight` pixels, content scaled to contentWidth×contentHeight placed at
    /// (hpad, vpad), remaining pixels black. Returns exactly `imageSize` bytes.
    public static func rgb565Slot(_ image: CGImage, _ f: ThumbFormat) -> [UInt8]? {
        let destW = f.destWidth, destH = f.destHeight
        guard destW > 0, destH > 0 else { return nil }
        let bytesPerRow = destW * 4
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: destW, height: destH,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: destW, height: destH))
        ctx.interpolationQuality = .high
        // CG uses a bottom-left origin while the buffer (and .ithmb slot) is
        // stored top-down. Drawing the CGImage unflipped keeps it right-side up;
        // we place content `vpad` rows from the top by offsetting from the bottom.
        let y = destH - f.vpad - f.contentHeight
        ctx.draw(image, in: CGRect(x: f.hpad, y: y, width: f.contentWidth, height: f.contentHeight))

        guard let raw = ctx.data else { return nil }
        let ptr = raw.bindMemory(to: UInt8.self, capacity: destH * bytesPerRow)
        var out = [UInt8](); out.reserveCapacity(destW * destH * 2)
        for y in 0..<destH {
            let row = y * bytesPerRow
            for x in 0..<destW {
                let i = row + x * 4
                let p = (UInt16(ptr[i] >> 3) << 11) | (UInt16(ptr[i + 1] >> 2) << 5) | UInt16(ptr[i + 2] >> 3)
                out.append(UInt8(p & 0xff))
                out.append(UInt8(p >> 8))
            }
        }
        // Should already equal imageSize; guard against rounding.
        if out.count < f.imageSize { out.append(contentsOf: repeatElement(0, count: f.imageSize - out.count)) }
        else if out.count > f.imageSize { out.removeLast(out.count - f.imageSize) }
        return out
    }
}
