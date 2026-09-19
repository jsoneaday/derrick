import SwiftUI

public struct HostUIScreen<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

public struct HostUISidebar<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 440, maxHeight: .infinity)
    }
}

public struct HostUIMessage: View {
    private let sender: String
    private let bodyText: String
    private let outbound: Bool

    public init(sender: String, body: String, outbound: Bool = false) {
        self.sender = sender
        self.bodyText = body
        self.outbound = outbound
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if outbound { Spacer(minLength: 80) }
            VStack(alignment: outbound ? .trailing : .leading, spacing: 4) {
                if !sender.isEmpty {
                    Text(sender)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(bodyText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(outbound ? Color.black.opacity(0.08) : Color.white)
                    )
            }
            .frame(maxWidth: .infinity, alignment: outbound ? .trailing : .leading)
            if !outbound { Spacer(minLength: 80) }
        }
    }
}

public struct HostUITableRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var cells: [String]

    public init(id: String, cells: [String]) {
        self.id = id
        self.cells = cells
    }
}

public struct HostUITable: View {
    private let columns: [String]
    private let rows: [HostUITableRow]

    public init(columns: [String], rows: [HostUITableRow]) {
        self.columns = columns
        self.rows = rows
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            if !columns.isEmpty {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, title in
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                    .gridCellColumns(max(columns.count, 1))
            }
            ForEach(rows) { row in
                GridRow {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.body)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
