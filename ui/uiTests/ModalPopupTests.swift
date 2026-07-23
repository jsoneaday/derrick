import Foundation
import SwiftUI
import Testing
@testable import ui

@Suite struct ModalPopupTests {
    @Test func defaultsMatchDocumentedGeometry() {
        #expect(ModalPopupDefaults.minWidth == 320)
        #expect(ModalPopupDefaults.minHeight == 180)
        #expect(ModalPopupDefaults.maxWidth == 480)
        #expect(ModalPopupDefaults.maxHeight == 360)
        #expect(ModalPopupDefaults.cornerRadius == 16)
        #expect(ModalPopupDefaults.backdropOpacity == 0.35)
        #expect(ModalPopupDefaults.zIndex == 10_000)
    }

    @Test func defaultsArePositiveAndUsable() {
        #expect(ModalPopupDefaults.minWidth > 0)
        #expect(ModalPopupDefaults.minHeight > 0)
        #expect(ModalPopupDefaults.maxWidth >= ModalPopupDefaults.minWidth)
        #expect(ModalPopupDefaults.maxHeight >= ModalPopupDefaults.minHeight)
        #expect(ModalPopupDefaults.cornerRadius > 0)
        #expect(ModalPopupDefaults.backdropOpacity > 0 && ModalPopupDefaults.backdropOpacity < 1)
        #expect(ModalPopupDefaults.zIndex > 0)
    }

    @MainActor
    @Test func bodyOnlyInitializerBuilds() {
        let popup = ModalPopup(minWidth: 400, minHeight: 220) {
            Text("Required body")
        }
        let mirrored = Mirror(reflecting: popup)
        #expect(mirrored.displayStyle == .struct)
    }

    @MainActor
    @Test func fullInitializerAcceptsHeaderBodyAndFooter() {
        let popup = ModalPopup(
            minWidth: 480,
            minHeight: 260,
            onBackdropDismiss: {},
            header: {
                Text("Title")
            },
            body: {
                Text("Body content")
            },
            footer: {
                HStack {
                    Text("Validation message")
                    Spacer()
                    Button("OK") {}
                }
            }
        )
        let mirrored = Mirror(reflecting: popup)
        #expect(mirrored.displayStyle == .struct)
    }

    @MainActor
    @Test func customMinSizeOverridesDefaults() {
        let customWidth: CGFloat = 512
        let customHeight: CGFloat = 300
        #expect(customWidth != ModalPopupDefaults.minWidth)
        #expect(customHeight != ModalPopupDefaults.minHeight)

        let popup = ModalPopup(minWidth: customWidth, minHeight: customHeight) {
            Text("Sized body")
        }
        let mirrored = Mirror(reflecting: popup)
        #expect(mirrored.displayStyle == .struct)
    }
}
