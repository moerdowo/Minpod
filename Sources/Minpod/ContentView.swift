import SwiftUI
import MinpodKit

enum SidebarItem: Hashable {
    case library
    case playlist(UInt64)
}

enum NameSheet: Identifiable {
    case create
    case createWith([UInt32])
    case rename(UInt64, String)
    var id: String {
        switch self {
        case .create: return "create"
        case .createWith: return "createWith"
        case .rename(let id, _): return "rename-\(id)"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isDropTargeted = false
    @State private var search = ""
    @State private var selection = Set<Track.ID>()
    @State private var confirmRemove = false
    @State private var editingTrack: Track?
    @State private var sidebarSelection: SidebarItem? = .library
    @State private var nameSheet: NameSheet?

    private var selectedTrack: Track? {
        selection.count == 1 ? model.tracks.first { $0.id == selection.first } : nil
    }

    private var currentPlaylist: ITunesDB.PlaylistInfo? {
        if case .playlist(let id) = sidebarSelection { return model.playlists.first { $0.id == id } }
        return nil
    }

    /// Tracks for the selected sidebar item, then filtered by search.
    private var filteredTracks: [Track] {
        var base = model.tracks
        if let pl = currentPlaylist {
            let byId = Dictionary(model.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            base = pl.trackIds.compactMap { byId[$0] }
        }
        guard !search.isEmpty else { return base }
        let q = search.lowercased()
        return base.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) || $0.album.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(item: $nameSheet) { kind in nameSheetView(kind) }
    }

    // MARK: sidebar

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Label("Library", systemImage: "music.note").tag(SidebarItem.library)
            if !model.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(model.playlists) { pl in
                        Label(pl.name, systemImage: "music.note.list")
                            .tag(SidebarItem.playlist(pl.id))
                            .contextMenu {
                                Button("Rename…") { nameSheet = .rename(pl.id, pl.name) }
                                Button("Delete Playlist", role: .destructive) { model.deletePlaylist(id: pl.id) }
                            }
                    }
                }
            }
        }
        .frame(minWidth: 170)
        .safeAreaInset(edge: .bottom) {
            Button {
                nameSheet = .create
            } label: {
                Label("New Playlist", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(8)
            .disabled(model.device == nil || model.isBusy)
        }
    }

    // MARK: detail

    private var detail: some View {
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
                Text(currentPlaylist?.name ?? model.device?.displayName ?? "Minpod")
                    .font(.headline)
                if model.device != nil {
                    Text("\(filteredTracks.count) songs\(model.capacity.isEmpty ? "" : " · \(model.capacity)")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.device != nil {
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            if model.isBusy { ProgressView().controlSize(.small) }
            if model.device != nil {
                Button { editingTrack = selectedTrack } label: { Label("Edit", systemImage: "pencil") }
                    .help("Edit the selected song's info")
                    .disabled(model.isBusy || selectedTrack == nil)
                Button(role: .destructive) { confirmRemove = true } label: { Label("Remove", systemImage: "trash") }
                    .help("Remove the selected song(s) from the iPod")
                    .disabled(model.isBusy || selection.isEmpty)
                Button { model.eject() } label: { Label("Eject", systemImage: "eject.fill") }
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
            Image(systemName: "cable.connector").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Connect an iPod to begin").font(.title3)
            Text("Plug in your iPod and enable disk use. Minpod detects it automatically, then drag audio files or folders onto the window to add them.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
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
                Text(t.rating > 0 ? String(repeating: "★", count: t.rating) : "").foregroundStyle(.yellow)
            }.width(60)
            TableColumn("Plays") { Text($0.playCount > 0 ? "\($0.playCount)" : "").monospacedDigit() }.width(44)
            TableColumn("Time") { Text($0.durationText).monospacedDigit() }.width(52)
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            if ids.count == 1, let t = model.tracks.first(where: { $0.id == ids.first }) {
                Button("Edit…") { editingTrack = t }
                Button("Set Artwork…") { model.chooseAndSetArtwork(id: t.id) }
            }
            if !ids.isEmpty {
                Menu("Add to Playlist") {
                    Button("New Playlist…") { nameSheet = .createWith(Array(ids)) }
                    if !model.playlists.isEmpty { Divider() }
                    ForEach(model.playlists) { pl in
                        Button(pl.name) { model.addToPlaylist(id: pl.id, trackIds: Array(ids)) }
                    }
                }
                Button("Export to…") { model.exportSelected(ids: ids) }
                Divider()
                Button("Remove \(ids.count) Song\(ids.count == 1 ? "" : "s") from iPod", role: .destructive) {
                    selection = ids; confirmRemove = true
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
            Button("Remove", role: .destructive) { model.remove(ids: selection); selection = [] }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The song\(selection.count == 1 ? "" : "s") and \(selection.count == 1 ? "its" : "their") file\(selection.count == 1 ? "" : "s") will be deleted from the iPod.")
        }
    }

    private var removePrompt: String { "Remove \(selection.count) song\(selection.count == 1 ? "" : "s")?" }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10]))
                .foregroundStyle(.tint).padding(8)
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 40))
                Text("Drop to add to \(model.device?.displayName ?? "iPod")").font(.title3.weight(.medium))
            }
            .foregroundStyle(.tint)
        }
        .background(.ultraThinMaterial.opacity(0.6))
        .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack {
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.device != nil {
                Text("Drag audio files or folders here to add").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    @ViewBuilder
    private func nameSheetView(_ kind: NameSheet) -> some View {
        switch kind {
        case .create:
            NameSheetView(title: "New Playlist", initial: "") { model.createPlaylist(name: $0) }
        case .createWith(let ids):
            NameSheetView(title: "New Playlist", initial: "") { model.createPlaylist(name: $0, withTracks: ids) }
        case .rename(let id, let current):
            NameSheetView(title: "Rename Playlist", initial: current) { model.renamePlaylist(id: id, name: $0) }
        }
    }
}

/// Small sheet to enter a playlist name.
struct NameSheetView: View {
    let title: String
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(title: String, initial: String, onConfirm: @escaping (String) -> Void) {
        self.title = title
        self.onConfirm = onConfirm
        _name = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { onConfirm(name); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
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
                Button("Save") { onSave(title, artist, album, genre, rating); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}
