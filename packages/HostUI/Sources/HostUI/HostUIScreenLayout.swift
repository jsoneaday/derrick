import Foundation
import Structure

/// How a `HostUINode` screen is composed. Inbox chrome is only for `holds=message_exchange`.
public enum HostUIScreenLayout: Sendable {
    public static func normalized(_ node: HostUINode) -> HostUINode {
        if node.element == HostUIElementID.screen.rawValue {
            return node
        }
        return HostUINode(
            element: HostUIElementID.screen.rawValue,
            config: ["holds": .string("arbitrary")],
            children: [node]
        )
    }

    public static func isMessageExchange(_ node: HostUINode) -> Bool {
        normalized(node).configString["holds"] == "message_exchange"
    }

    public static func visibleChildren(of node: HostUINode) -> [HostUINode] {
        (node.children ?? []).filter { child in
            HostUIElementID(rawValue: child.element)?.isService != true
        }
    }

    public static func tabStripNodes(in node: HostUINode) -> [HostUINode] {
        visibleChildren(of: node).filter { $0.element == HostUIElementID.tabStrip.rawValue }
    }

    public static func sidebarNodes(in node: HostUINode) -> [HostUINode] {
        visibleChildren(of: node).filter { $0.element == HostUIElementID.sidebar.rawValue }
    }

    public static func mainNodes(in node: HostUINode) -> [HostUINode] {
        visibleChildren(of: node).filter {
            $0.element != HostUIElementID.tabStrip.rawValue
                && $0.element != HostUIElementID.sidebar.rawValue
        }
    }
}
