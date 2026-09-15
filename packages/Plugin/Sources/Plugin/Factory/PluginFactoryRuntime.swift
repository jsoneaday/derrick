import Foundation
import Structure

public extension PluginFactoryRelease {
    var guestLanguage: PluginGuestLanguage {
        PluginFactoryRuntime.decode(from: runtimeJSON)?.language ?? .go
    }
}
