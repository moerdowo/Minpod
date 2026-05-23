import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Applies a rounded-rectangle "border radius" to a source image and emits the
// README cover plus a full macOS .iconset.
// usage: swift round-icon.swift <sourceImage> <projectRoot>

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write(Data("usage: round-icon.swift <source> <projectRoot>\n".utf8)); exit(1) }
let srcURL = URL(fileURLWithPath: args[1])
let root = URL(fileURLWithPath: args[2])

guard let src = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let loaded = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read image: \(srcURL.path)\n".utf8)); exit(1)
}

let radiusFraction: CGFloat = 0.18 // border radius as a fraction of the side
let cropInset: CGFloat = 0.085     // crop this fraction off each edge (drops the blueprint frame/margin)

// Crop the source inward so the outer frame and margin are removed.
let image: CGImage = {
    let w = CGFloat(loaded.width), h = CGFloat(loaded.height)
    let rect = CGRect(x: (w * cropInset).rounded(), y: (h * cropInset).rounded(),
                      width: (w * (1 - 2 * cropInset)).rounded(),
                      height: (h * (1 - 2 * cropInset)).rounded())
    return loaded.cropping(to: rect) ?? loaded
}()

func rounded(_ size: Int) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let r = CGFloat(size) * radiusFraction
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()
    ctx.interpolationQuality = .high
    // Scale-to-fill (center-crop) so the square icon has no letterboxing.
    let iw = CGFloat(image.width), ih = CGFloat(image.height)
    let scale = max(CGFloat(size) / iw, CGFloat(size) / ih)
    let dw = iw * scale, dh = ih * scale
    ctx.draw(image, in: CGRect(x: (CGFloat(size) - dw) / 2, y: (CGFloat(size) - dh) / 2, width: dw, height: dh))
    return ctx.makeImage()
}

func writePNG(_ img: CGImage, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

if let cover = rounded(600) { writePNG(cover, root.appendingPathComponent("assets/cover.png")) }

let iconset = root.appendingPathComponent("build/Minpod.iconset")
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    if let img = rounded(px) { writePNG(img, iconset.appendingPathComponent("\(name).png")) }
}
print("icon assets written: assets/cover.png + build/Minpod.iconset")
