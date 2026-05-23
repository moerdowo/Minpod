import Foundation
import AVFoundation

/// Metadata extracted from a source audio file, used to populate a new track.
public struct AudioMetadata: Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    public var durationMS: UInt32
    public var trackNumber: UInt32
    public var trackTotal: UInt32
    public var year: UInt32
    public var bitrate: UInt32      // kbps
    public var sampleRate: UInt32   // Hz
    public var fileSize: UInt32
    public var fileExtension: String
    public var artworkData: Data?   // embedded cover image bytes (JPEG/PNG), if any

    /// Audio extensions an iPod classic / nano / video can play.
    public static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "aif", "aiff", "wav", "m4b", "alac"]

    public static func read(url: URL) async -> AudioMetadata {
        let ext = url.pathExtension.lowercased()
        let fileSize = (try? UInt32(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0)) ?? 0
        let fallbackTitle = url.deletingPathExtension().lastPathComponent

        var meta = AudioMetadata(
            title: fallbackTitle, artist: "", album: "", genre: "",
            durationMS: 0, trackNumber: 0, trackTotal: 0, year: 0,
            bitrate: 0, sampleRate: 0, fileSize: fileSize, fileExtension: ext,
            artworkData: nil
        )

        let asset = AVURLAsset(url: url)

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite && seconds > 0 { meta.durationMS = UInt32(seconds * 1000) }
        }

        if let items = try? await asset.load(.metadata) {
            for item in items {
                guard let common = item.commonKey else { continue }
                let value = try? await item.load(.stringValue)
                switch common {
                case .commonKeyTitle: if let v = value, !v.isEmpty { meta.title = v }
                case .commonKeyArtist, .commonKeyAuthor:
                    if meta.artist.isEmpty, let v = value, !v.isEmpty { meta.artist = v }
                case .commonKeyAlbumName: if let v = value, !v.isEmpty { meta.album = v }
                case .commonKeyType: if let v = value, !v.isEmpty { meta.genre = v }
                case .commonKeyArtwork:
                    if meta.artworkData == nil, let d = try? await item.load(.dataValue) { meta.artworkData = d }
                default: break
                }
            }
            await extractExtras(from: items, into: &meta)
        }

        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                meta.bitrate = UInt32(rate / 1000.0)
            }
            if let descs = try? await track.load(.formatDescriptions),
               let desc = descs.first {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                    meta.sampleRate = UInt32(asbd.mSampleRate)
                }
            }
        }

        // Derive bitrate if the container didn't report one.
        if meta.bitrate == 0, meta.durationMS > 0 {
            meta.bitrate = UInt32((Double(fileSize) * 8.0) / (Double(meta.durationMS) / 1000.0) / 1000.0)
        }
        return meta
    }

    /// Genre / track number / year live under format-specific identifiers.
    private static func extractExtras(from items: [AVMetadataItem], into meta: inout AudioMetadata) async {
        for item in items {
            guard let id = item.identifier else { continue }
            switch id {
            case .id3MetadataContentType, .iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre:
                if meta.genre.isEmpty, let v = try? await item.load(.stringValue), !v.isEmpty { meta.genre = v }
            case .id3MetadataTrackNumber, .iTunesMetadataTrackNumber:
                if let parsed = try? await parseTrack(item) { meta.trackNumber = parsed.0; if parsed.1 > 0 { meta.trackTotal = parsed.1 } }
            case .id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate:
                if meta.year == 0, let v = try? await item.load(.stringValue) {
                    meta.year = UInt32(v.prefix(4)) ?? 0
                }
            default: break
            }
        }
    }

    private static func parseTrack(_ item: AVMetadataItem) async throws -> (UInt32, UInt32) {
        if let data = try? await item.load(.dataValue), data.count >= 4 {
            // iTunes "trkn" atom: bytes 2-3 = track, 4-5 = total (big-endian)
            let track = (UInt32(data[2]) << 8) | UInt32(data[3])
            let total = data.count >= 6 ? (UInt32(data[4]) << 8) | UInt32(data[5]) : 0
            if track > 0 { return (track, total) }
        }
        if let s = try? await item.load(.stringValue) {
            let parts = s.split(separator: "/")
            let track = UInt32(parts.first ?? "") ?? 0
            let total = parts.count > 1 ? (UInt32(parts[1]) ?? 0) : 0
            return (track, total)
        }
        if let n = try? await item.load(.numberValue) { return (n.uint32Value, 0) }
        return (0, 0)
    }
}
