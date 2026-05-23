import Foundation
import AVFoundation

/// Transcodes audio the iPod can't play (e.g. FLAC) into AAC `.m4a` using
/// AVFoundation. Best-effort: returns nil if the source can't be decoded.
public enum AudioConverter {
    /// Extensions that aren't iPod-playable but are worth trying to convert.
    public static let convertibleExtensions: Set<String> = [
        "flac", "ogg", "oga", "opus", "wma", "ape", "wv", "mka", "m4p"
    ]

    public static func toM4A(_ src: URL) async -> URL? {
        let asset = AVURLAsset(url: src)
        // Must have a decodable audio track.
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
            return nil
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("minpod-\(UUID().uuidString).m4a")
        export.outputURL = out
        export.outputFileType = .m4a

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        return export.status == .completed ? out : nil
    }
}
