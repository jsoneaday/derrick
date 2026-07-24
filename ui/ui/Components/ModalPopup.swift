import SwiftUI

/// Default geometry for `ModalPopup`. Callers may override per presentation.
enum ModalPopupDefaults {
    static let minWidth: CGFloat = 320
    static let minHeight: CGFloat = 180
    /// Caps growth so the card stays a centered popup, not a full-window panel.
    static let maxWidth: CGFloat = 480
    static let maxHeight: CGFloat = 360
    static let cornerRadius: CGFloat = 16
    static let backdropOpacity: Double = 0.35
    /// Keeps the modal above ordinary overlays and sheets content hosts.
    static let zIndex: Double = 10_000
}

/// Full-window modal that always sits on top of the app.
///
/// - **Header** and **footer** are optional and accept arbitrary views
///   (titles, buttons, validation messages, etc.).
/// - **Body** is required.
/// - **minWidth** / **minHeight** are configurable by the caller.
struct ModalPopup<Header: View, BodyContent: View, Footer: View>: View {
    private let minWidth: CGFloat
    private let minHeight: CGFloat
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat
    private let onBackdropDismiss: (() -> Void)?
    private let header: Header
    private let bodyContent: BodyContent
    private let footer: Footer

    init(
        minWidth: CGFloat = ModalPopupDefaults.minWidth,
        minHeight: CGFloat = ModalPopupDefaults.minHeight,
        maxWidth: CGFloat = ModalPopupDefaults.maxWidth,
        maxHeight: CGFloat = ModalPopupDefaults.maxHeight,
        onBackdropDismiss: (() -> Void)? = nil,
        @ViewBuilder header: () -> Header = { EmptyView() },
        @ViewBuilder body: () -> BodyContent,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) {
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.onBackdropDismiss = onBackdropDismiss
        self.header = header()
        self.bodyContent = body()
        self.footer = footer()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(ModalPopupDefaults.backdropOpacity)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    onBackdropDismiss?()
                }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                header
                bodyContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                footer
            }
            .padding(15)
            .frame(minWidth: minWidth, idealWidth: minWidth, maxWidth: maxWidth)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: ModalPopupDefaults.cornerRadius)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
            )
            .clipShape(RoundedRectangle(cornerRadius: ModalPopupDefaults.cornerRadius))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(ModalPopupDefaults.zIndex)
    }
}

// MARK: - Body-only convenience (no header / footer type noise)

extension ModalPopup where Header == EmptyView, Footer == EmptyView {
    init(
        minWidth: CGFloat = ModalPopupDefaults.minWidth,
        minHeight: CGFloat = ModalPopupDefaults.minHeight,
        maxWidth: CGFloat = ModalPopupDefaults.maxWidth,
        maxHeight: CGFloat = ModalPopupDefaults.maxHeight,
        onBackdropDismiss: (() -> Void)? = nil,
        @ViewBuilder body: () -> BodyContent
    ) {
        self.init(
            minWidth: minWidth,
            minHeight: minHeight,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            onBackdropDismiss: onBackdropDismiss,
            header: { EmptyView() },
            body: body,
            footer: { EmptyView() }
        )
    }
}

// MARK: - Presentation helper

extension View {
    /// Presents `ModalPopup` in an overlay so it covers the entire host view hierarchy.
    func modalPopup<Header: View, BodyContent: View, Footer: View>(
        isPresented: Bool,
        minWidth: CGFloat = ModalPopupDefaults.minWidth,
        minHeight: CGFloat = ModalPopupDefaults.minHeight,
        maxWidth: CGFloat = ModalPopupDefaults.maxWidth,
        maxHeight: CGFloat = ModalPopupDefaults.maxHeight,
        onBackdropDismiss: (() -> Void)? = nil,
        @ViewBuilder header: () -> Header = { EmptyView() },
        @ViewBuilder body: () -> BodyContent,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) -> some View {
        overlay {
            if isPresented {
                ModalPopup(
                    minWidth: minWidth,
                    minHeight: minHeight,
                    maxWidth: maxWidth,
                    maxHeight: maxHeight,
                    onBackdropDismiss: onBackdropDismiss,
                    header: header,
                    body: body,
                    footer: footer
                )
            }
        }
    }
}
