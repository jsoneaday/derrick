import Structure
import SwiftUI

/// Maps a validated `HostUINode` tree onto the shared HostUI controls.
/// Interactive binds must be supplied by the host via `HostUINodeBindings`.
public struct HostUINodeView: View {
    private let node: HostUINode
    private let bindings: HostUINodeBindings

    public init(node: HostUINode, bindings: HostUINodeBindings = HostUINodeBindings()) {
        self.node = node
        self.bindings = bindings
    }

    public var body: some View {
        switch HostUIElementID(rawValue: node.element) {
        case .screen:
            screenBody
        case .sidebar:
            if bindings.isSidebarVisible(for: node) {
                HostUISidebar {
                    childrenColumn(nodes: node.children ?? [])
                }
            } else {
                EmptyView()
            }
        case .section:
            HostUISection(title: node.configString["title"]) {
                childrenColumn(nodes: node.children ?? [])
            }
        case .text:
            HostUIText(
                node.configString["value"] ?? node.id ?? "",
                style: HostUITextStyle(rawValue: node.configString["style"] ?? "body") ?? .body,
                multilineCenter: node.configString["align"] == "center"
            )
        case .textField:
            HostUITextField(
                label: node.configString["label"],
                placeholder: node.configString["placeholder"] ?? "",
                text: bindings.stringBinding(for: node)
            )
        case .select:
            HostUISelect(
                label: node.configString["label"],
                options: bindings.selectOptions(for: node),
                selection: bindings.stringBinding(for: node)
            )
        case .button:
            HostUIButton(
                node.configString["label"] ?? "Button",
                chrome: HostUIButtonChrome(rawValue: node.configString["style"] ?? "primary") ?? .primary,
                action: { bindings.buttonAction(for: node)() }
            )
        case .calendar:
            HostUICalendar(
                label: node.configString["label"],
                date: bindings.dateBinding(for: node)
            )
        case .time:
            HostUITime(
                label: node.configString["label"],
                date: bindings.dateBinding(for: node)
            )
        case .composer:
            HostUIComposer(
                placeholder: node.configString["placeholder"] ?? "Message",
                text: bindings.stringBinding(for: node),
                isSending: bindings.isSending(for: node),
                canSend: bindings.canSend(for: node),
                onSend: bindings.buttonAction(for: node)
            )
        case .table:
            HostUITable(
                columns: bindings.tableColumns(for: node),
                rows: bindings.tableRows(for: node)
            )
        case .message:
            HostUIMessage(
                sender: node.configString["sender"] ?? "",
                body: node.configString["body"] ?? node.configString["value"] ?? ""
            )
        case .tabStrip:
            HostUITabStrip(
                tabs: bindings.tabItems(for: node),
                selectedID: bindings.selectedTabID(for: node),
                onSelect: bindings.tabSelectAction(for: node)
            )
        case .messageList:
            HostUIMessageList(
                rows: bindings.messageRows(for: node),
                bottomID: bindings.messageBottomID(for: node),
                loadsOlder: bindings.loadsOlder(for: node),
                scrollToBottomToken: bindings.scrollToBottomToken(for: node),
                scrollAnchorID: bindings.scrollAnchorID(for: node),
                onLoadOlder: bindings.loadOlderAction(for: node),
                onNearBottomChange: bindings.nearBottomAction(for: node)
            )
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var screenBody: some View {
        let kids = node.children ?? []
        let tabs = kids.filter { $0.element == HostUIElementID.tabStrip.rawValue }
        let sidebars = kids.filter { $0.element == HostUIElementID.sidebar.rawValue }
        let main = kids.filter {
            $0.element != HostUIElementID.tabStrip.rawValue
                && $0.element != HostUIElementID.sidebar.rawValue
        }
        HostUIScreen {
            VStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { _, child in
                    HostUINodeView(node: child, bindings: bindings)
                }
                HStack(spacing: 0) {
                    childrenColumn(nodes: main)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ForEach(Array(sidebars.enumerated()), id: \.offset) { _, child in
                        if bindings.isSidebarVisible(for: child) {
                            Divider()
                            HostUINodeView(node: child, bindings: bindings)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func childrenColumn(nodes: [HostUINode]) -> some View {
        if nodes.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
                    HostUINodeView(node: child, bindings: bindings)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: child.element == HostUIElementID.messageList.rawValue
                                ? .infinity
                                : nil,
                            alignment: .topLeading
                        )
                }
            }
        }
    }
}

/// Host-owned values and actions for interactive nodes in a present tree.
public struct HostUINodeBindings {
    public var strings: [String: Binding<String>]
    public var dates: [String: Binding<Date>]
    public var selectOptions: [String: [HostUISelectOption]]
    public var tableColumns: [String: [String]]
    public var tableRows: [String: [HostUITableRow]]
    public var actions: [String: () -> Void]
    public var tabItems: [String: [HostUITabItem]]
    public var selectedTabIDs: [String: String]
    public var tabSelectActions: [String: (String) -> Void]
    public var messageRows: [String: [HostUIMessageRow]]
    public var messageBottomIDs: [String: String]
    public var loadsOlderFlags: [String: Bool]
    public var scrollToBottomTokens: [String: Int]
    public var scrollAnchorIDs: [String: String?]
    public var loadOlderActions: [String: () -> Void]
    public var nearBottomActions: [String: (Bool) -> Void]
    public var canSendFlags: [String: Bool]
    public var isSendingFlags: [String: Bool]
    public var sidebarVisible: [String: Bool]
    public var defaultSidebarVisible: Bool

    public init(
        strings: [String: Binding<String>] = [:],
        dates: [String: Binding<Date>] = [:],
        selectOptions: [String: [HostUISelectOption]] = [:],
        tableColumns: [String: [String]] = [:],
        tableRows: [String: [HostUITableRow]] = [:],
        actions: [String: () -> Void] = [:],
        tabItems: [String: [HostUITabItem]] = [:],
        selectedTabIDs: [String: String] = [:],
        tabSelectActions: [String: (String) -> Void] = [:],
        messageRows: [String: [HostUIMessageRow]] = [:],
        messageBottomIDs: [String: String] = [:],
        loadsOlderFlags: [String: Bool] = [:],
        scrollToBottomTokens: [String: Int] = [:],
        scrollAnchorIDs: [String: String?] = [:],
        loadOlderActions: [String: () -> Void] = [:],
        nearBottomActions: [String: (Bool) -> Void] = [:],
        canSendFlags: [String: Bool] = [:],
        isSendingFlags: [String: Bool] = [:],
        sidebarVisible: [String: Bool] = [:],
        defaultSidebarVisible: Bool = true
    ) {
        self.strings = strings
        self.dates = dates
        self.selectOptions = selectOptions
        self.tableColumns = tableColumns
        self.tableRows = tableRows
        self.actions = actions
        self.tabItems = tabItems
        self.selectedTabIDs = selectedTabIDs
        self.tabSelectActions = tabSelectActions
        self.messageRows = messageRows
        self.messageBottomIDs = messageBottomIDs
        self.loadsOlderFlags = loadsOlderFlags
        self.scrollToBottomTokens = scrollToBottomTokens
        self.scrollAnchorIDs = scrollAnchorIDs
        self.loadOlderActions = loadOlderActions
        self.nearBottomActions = nearBottomActions
        self.canSendFlags = canSendFlags
        self.isSendingFlags = isSendingFlags
        self.sidebarVisible = sidebarVisible
        self.defaultSidebarVisible = defaultSidebarVisible
    }

    func stringBinding(for node: HostUINode) -> Binding<String> {
        key(for: node).flatMap { strings[$0] } ?? .constant("")
    }

    func dateBinding(for node: HostUINode) -> Binding<Date> {
        key(for: node).flatMap { dates[$0] } ?? .constant(Date())
    }

    func selectOptions(for node: HostUINode) -> [HostUISelectOption] {
        key(for: node).flatMap { selectOptions[$0] } ?? []
    }

    func tableColumns(for node: HostUINode) -> [String] {
        key(for: node).flatMap { tableColumns[$0] } ?? []
    }

    func tableRows(for node: HostUINode) -> [HostUITableRow] {
        key(for: node).flatMap { tableRows[$0] } ?? []
    }

    func buttonAction(for node: HostUINode) -> () -> Void {
        key(for: node).flatMap { actions[$0] } ?? {}
    }

    func tabItems(for node: HostUINode) -> [HostUITabItem] {
        key(for: node).flatMap { tabItems[$0] } ?? []
    }

    func selectedTabID(for node: HostUINode) -> String? {
        key(for: node).flatMap { selectedTabIDs[$0] }
    }

    func tabSelectAction(for node: HostUINode) -> (String) -> Void {
        key(for: node).flatMap { tabSelectActions[$0] } ?? { _ in }
    }

    func messageRows(for node: HostUINode) -> [HostUIMessageRow] {
        key(for: node).flatMap { messageRows[$0] } ?? []
    }

    func messageBottomID(for node: HostUINode) -> String {
        key(for: node).flatMap { messageBottomIDs[$0] } ?? "host-ui-scroll-bottom"
    }

    func loadsOlder(for node: HostUINode) -> Bool {
        key(for: node).flatMap { loadsOlderFlags[$0] } ?? false
    }

    func scrollToBottomToken(for node: HostUINode) -> Int {
        key(for: node).flatMap { scrollToBottomTokens[$0] } ?? 0
    }

    func scrollAnchorID(for node: HostUINode) -> String? {
        key(for: node).flatMap { scrollAnchorIDs[$0] } ?? nil
    }

    func loadOlderAction(for node: HostUINode) -> () -> Void {
        key(for: node).flatMap { loadOlderActions[$0] } ?? {}
    }

    func nearBottomAction(for node: HostUINode) -> (Bool) -> Void {
        key(for: node).flatMap { nearBottomActions[$0] } ?? { _ in }
    }

    func canSend(for node: HostUINode) -> Bool {
        key(for: node).flatMap { canSendFlags[$0] } ?? true
    }

    func isSending(for node: HostUINode) -> Bool {
        key(for: node).flatMap { isSendingFlags[$0] } ?? false
    }

    func isSidebarVisible(for node: HostUINode) -> Bool {
        if let key = key(for: node), let flagged = sidebarVisible[key] {
            return flagged
        }
        let when = node.configString["visible_when"] ?? "always"
        if when == "always" { return defaultSidebarVisible }
        return defaultSidebarVisible
    }

    private func key(for node: HostUINode) -> String? {
        if let id = node.id, !id.isEmpty { return id }
        if let bind = node.bind, !bind.isEmpty { return bind }
        return nil
    }
}
