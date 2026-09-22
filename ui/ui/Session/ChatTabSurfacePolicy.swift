import Foundation
import Structure

/// Host binding for Chat-tab Surface. Not a procession slot.
///
/// The human does not pick Surface unless `bind` returns `.needsHumanChoice`.
enum ChatTabSurfacePolicy: Sendable {
    enum Binding: Equatable, Sendable {
        case decided(ChatTabSurface)
        case needsHumanChoice
    }

    /// Bind from whether this tab is a messaging connector when no present tree exists yet.
    static func bind(isMessagingConnector: Bool) -> Binding {
        if isMessagingConnector {
            return .decided(.thread)
        }
        return .decided(.conversation)
    }

    /// Slice 2: bind from Return / Connect, then the caller may apply wrongness on the spec.
    static func bind(spec: PluginSpecDraft, isMessagingConnector: Bool = false) -> Binding {
        switch PluginPresentPolicy.bind(spec: spec, isMessagingConnector: isMessagingConnector) {
        case .decided(let present):
            return .decided(ChatTabSurface(present))
        case .needsHumanChoice:
            return .needsHumanChoice
        }
    }

    static func bind(present: PluginPresent) -> Binding {
        .decided(ChatTabSurface(present))
    }
}
