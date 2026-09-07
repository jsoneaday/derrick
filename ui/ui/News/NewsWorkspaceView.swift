import SwiftUI
import Structure

struct NewsWorkspaceView: View {
    @ObservedObject var store: NewsReaderStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.selectedReader == nil {
                emptyState
            } else {
                itemList
            }
        }
        .background(Color(red: 252.0 / 255.0, green: 252.0 / 255.0, blue: 250.0 / 255.0))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedReader?.name ?? "News")
                    .font(.headline)
                if let reader = store.selectedReader {
                    Text(headerSubtitle(reader))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.selectedReader != nil {
                Button {
                    Task { await store.refreshSelected() }
                } label: {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Refresh")
                    }
                }
                .disabled(store.isRefreshing)
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "newspaper")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No news lists yet")
                .font(.title3.weight(.semibold))
            Text("Create a News reader from Plugins. You can pick several topics and several sources.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = store.selectedReader?.lastError ?? store.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if store.selectedReader?.mode == .summaries, !store.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.subheadline.weight(.semibold))
                        Text(NewsReaderRefresh.digest(from: store.items))
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                }
                ForEach(store.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Link(destination: URL(string: item.sourceURL) ?? URL(string: "https://example.com")!) {
                            Text(item.title)
                                .font(.body.weight(.semibold))
                                .multilineTextAlignment(.leading)
                        }
                        HStack(spacing: 8) {
                            Text(item.sourceLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Link("Source", destination: URL(string: item.sourceURL) ?? URL(string: "https://example.com")!)
                                .font(.caption.weight(.semibold))
                        }
                        if let summary = item.summary, !summary.isEmpty, store.selectedReader?.mode == .list {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                }
                if store.items.isEmpty, store.lastError == nil, store.selectedReader?.lastError == nil {
                    Text("No articles yet. Refresh this list.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }

    private func headerSubtitle(_ reader: NewsReaderSpec) -> String {
        let topics = reader.topics.isEmpty ? "All topics" : reader.topics.joined(separator: ", ")
        let sources = "\(reader.sources.count) source\(reader.sources.count == 1 ? "" : "s")"
        return "\(topics) · \(sources) · \(reader.mode.displayName) · \(reader.schedule.displayName)"
    }
}
