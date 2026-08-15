import SwiftUI
import ServiceContracts

/// Settings → Network blacklist. Exact host or `*.domain` (subdomains only, not apex).
struct NetworkBlacklistSettingsView: View {
    @ObservedObject private var blacklist = EgressBlacklistSettingsStore.shared
    @State private var draft = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Network blacklist")
                .font(.system(size: 26, weight: .semibold, design: .rounded))

            Text("Public HTTPS is allowed unless a host is listed here. Add an exact host (`api.example.com`) or a subdomain wildcard (`*.example.com`). Wildcards do not include the apex — add both if you want the whole site. `*.com` and other public suffixes are rejected.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("api.example.com or *.example.com", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await addEntry() } }
                Button("Add") {
                    Task { await addEntry() }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if blacklist.entries.isEmpty {
                Text("No blocked hosts. The list starts empty.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(blacklist.entries) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.displayPattern)
                                    .font(.body.monospaced())
                                Text(row.kind == "suffix" ? "Subdomains only" : "Exact host")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await removeEntry(id: row.id) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task {
            await load()
        }
    }

    private func load() async {
        do {
            try await blacklist.reload()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func addEntry() async {
        let pattern = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        do {
            try await blacklist.add(pattern: pattern)
            draft = ""
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func removeEntry(id: String) async {
        do {
            try await blacklist.remove(id: id)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
