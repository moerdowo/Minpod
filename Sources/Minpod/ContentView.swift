import SwiftUI
import MinpodKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isDropTargeted = false
    @State private var search = ""

    private var filteredTracks: [Track] {
        guard !search.isEmpty else { return model.tracks }
        let q = search.lowercased()
        return model.tracks.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) || $0.album.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.device == nil {
                emptyState
            } else {
                trackList
            }
            Divider()
            statusBar
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls: urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted && model.device != nil
        }
        .overlay { if isDropTargeted { dropOverlay } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "ipod")
                .font(.system(size: 22))
                .foregroundStyle(model.device == nil ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.device?.displayName ?? "Minpod")
                    .font(.headline)
                if let dev = model.device {
                    Text("\(model.tracks.count) songs · \(dev.mountPoint.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.device != nil {
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            if model.isBusy { ProgressView().controlSize(.small) }
            if model.device != nil {
                Button {
                    model.eject()
                } label: {
                    Label("Eject", systemImage: "eject.fill")
                }
                .help("Eject the iPod (required before unplugging)")
                .disabled(model.isBusy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "cable.connector")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Connect an iPod to begin")
                .font(.title3)
            Text("Plug in your iPod and enable disk use. Minpod detects it automatically, then drag audio files onto the window to add them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trackList: some View {
        Table(filteredTracks) {
            TableColumn("Title", value: \.title)
            TableColumn("Artist", value: \.artist)
            TableColumn("Album", value: \.album)
            TableColumn("Time") { Text($0.durationText).monospacedDigit() }
                .width(56)
        }
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10]))
                .foregroundStyle(.tint)
                .padding(8)
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 40))
                Text("Drop to add to \(model.device?.displayName ?? "iPod")")
                    .font(.title3.weight(.medium))
            }
            .foregroundStyle(.tint)
        }
        .background(.ultraThinMaterial.opacity(0.6))
        .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack {
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.device != nil {
                Text("Drag audio files here to sync")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
