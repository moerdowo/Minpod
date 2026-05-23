import SwiftUI
import MinpodKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

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
                    Text(dev.mountPoint.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
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
            Text("Plug in your iPod and enable disk use. Minpod will detect it automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trackList: some View {
        Table(model.tracks) {
            TableColumn("Title", value: \.title)
            TableColumn("Artist", value: \.artist)
            TableColumn("Album", value: \.album)
            TableColumn("Time") { Text($0.durationText).monospacedDigit() }
                .width(56)
        }
    }

    private var statusBar: some View {
        HStack {
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
