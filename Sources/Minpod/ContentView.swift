import SwiftUI
import MinpodKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isDropTargeted = false
    @State private var search = ""
    @State private var selection = Set<Track.ID>()
    @State private var confirmRemove = false
    @State private var editingTrack: Track?

    private var selectedTrack: Track? {
        selection.count == 1 ? model.tracks.first { $0.id == selection.first } : nil
    }

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
                if model.device != nil {
                    Text("\(model.tracks.count) songs\(model.capacity.isEmpty ? "" : " · \(model.capacity)")")
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
                    editingTrack = selectedTrack
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .help("Edit the selected song's info")
                .disabled(model.isBusy || selectedTrack == nil)

                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .help("Remove the selected song(s) from the iPod")
                .disabled(model.isBusy || selection.isEmpty)

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
        Table(filteredTracks, selection: $selection) {
            TableColumn("Title", value: \.title)
            TableColumn("Artist", value: \.artist)
            TableColumn("Album", value: \.album)
            TableColumn("★") { t in
                Text(t.rating > 0 ? String(repeating: "★", count: t.rating) : "")
                    .foregroundStyle(.yellow)
            }.width(60)
            TableColumn("Plays") { Text($0.playCount > 0 ? "\($0.playCount)" : "").monospacedDigit() }
                .width(44)
            TableColumn("Time") { Text($0.durationText).monospacedDigit() }
                .width(52)
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            if ids.count == 1, let t = model.tracks.first(where: { $0.id == ids.first }) {
                Button("Edit…") { editingTrack = t }
            }
            if !ids.isEmpty {
                Button("Remove \(ids.count) Song\(ids.count == 1 ? "" : "s") from iPod", role: .destructive) {
                    selection = ids
                    confirmRemove = true
                }
            }
        }
        .onDeleteCommand { if !selection.isEmpty { confirmRemove = true } }
        .sheet(item: $editingTrack) { track in
            EditTrackSheet(track: track) { title, artist, album, genre, rating in
                model.editTrack(id: track.id, title: title, artist: artist, album: album, genre: genre, rating: rating)
            }
        }
        .confirmationDialog(removePrompt, isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                model.remove(ids: selection)
                selection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The song\(selection.count == 1 ? "" : "s") and \(selection.count == 1 ? "its" : "their") file\(selection.count == 1 ? "" : "s") will be deleted from the iPod.")
        }
    }

    private var removePrompt: String {
        "Remove \(selection.count) song\(selection.count == 1 ? "" : "s")?"
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

/// Sheet for editing a track's metadata and rating.
struct EditTrackSheet: View {
    let track: Track
    let onSave: (_ title: String, _ artist: String, _ album: String, _ genre: String, _ rating: Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var genre: String
    @State private var rating: Int

    init(track: Track, onSave: @escaping (String, String, String, String, Int) -> Void) {
        self.track = track
        self.onSave = onSave
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
        _genre = State(initialValue: track.genre)
        _rating = State(initialValue: track.rating)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Song Info").font(.headline)
            Form {
                TextField("Title", text: $title)
                TextField("Artist", text: $artist)
                TextField("Album", text: $album)
                TextField("Genre", text: $genre)
                Picker("Rating", selection: $rating) {
                    ForEach(0...5, id: \.self) { n in
                        Text(n == 0 ? "—" : String(repeating: "★", count: n)).tag(n)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(title, artist, album, genre, rating)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}
