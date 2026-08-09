import SwiftUI

/// Default geometry for `ModalPopup`. Callers may override per presentation.
enum ModalPopupDefaults {
    static let minWidth: CGFloat = 320
    /// No forced tall chrome — card hugs content (word-wrap included) up to `maxHeight`.
    static let minHeight: CGFloat = 0
    /// Caps growth so the card stays a centered popup, not a full-window panel.
    static let maxWidth: CGFloat = 480
    static let maxHeight: CGFloat = 360
    static let cornerRadius: CGFloat = 16
    static let backdropOpacity: Double = 0.35
    static let zIndex: Double = 10_000
    /// Reserve for header + footer when body must scroll under the height cap.
    static let headerFooterReserve: CGFloat = 100
}

/// Full-window modal that always sits on top of the app.
///
/// Height: **hugs content** when short; if content would exceed `maxHeight`, uses a capped
/// card with a scrollable body. Empty header/footer types (`EmptyView`) take no space.
struct ModalPopup<Header: View, BodyContent: View, Footer: View>: View {
    private let minWidth: CGFloat
    private let minHeight: CGFloat
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat
    private let onBackdropDismiss: (() -> Void)?
    private let onEscape: (() -> Void)?
    private let header: Header
    private let bodyContent: BodyContent
    private let footer: Footer

    init(
        minWidth: CGFloat = ModalPopupDefaults.minWidth,
        minHeight: CGFloat = ModalPopupDefaults.minHeight,
        maxWidth: CGFloat = ModalPopupDefaults.maxWidth,
        maxHeight: CGFloat = ModalPopupDefaults.maxHeight,
        onBackdropDismiss: (() -> Void)? = nil,
        onEscape: (() -> Void)? = nil,
        @ViewBuilder header: () -> Header = { EmptyView() },
        @ViewBuilder body: () -> BodyContent,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) {
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.onBackdropDismiss = onBackdropDismiss
        self.onEscape = onEscape ?? onBackdropDismiss
        self.header = header()
        self.bodyContent = body()
        self.footer = footer()
    }

    private var hasHeader: Bool { Header.self != EmptyView.self }
    private var hasFooter: Bool { Footer.self != EmptyView.self }

    private var bodyMaxHeight: CGFloat {
        var reserve: CGFloat = 24 // card padding
        if hasHeader { reserve += ModalPopupDefaults.headerFooterReserve * 0.45 }
        if hasFooter { reserve += ModalPopupDefaults.headerFooterReserve * 0.45 }
        return max(80, maxHeight - reserve)
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

            ViewThatFits(in: .vertical) {
                styledCard(scrollBody: false)
                styledCard(scrollBody: true)
            }
            .frame(maxWidth: maxWidth)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .background(
                Button("", action: { onEscape?() })
                    .keyboardShortcut(.cancelAction)
                    .opacity(0.001)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(ModalPopupDefaults.zIndex)
        .onExitCommand {
            onEscape?()
        }
    }

    private func styledCard(scrollBody: Bool) -> some View {
        cardChrome(scrollBody: scrollBody)
            .background(
                RoundedRectangle(cornerRadius: ModalPopupDefaults.cornerRadius)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .clipShape(RoundedRectangle(cornerRadius: ModalPopupDefaults.cornerRadius))
            .frame(maxHeight: scrollBody ? maxHeight : nil, alignment: .top)
    }

    @ViewBuilder
    private func cardChrome(scrollBody: Bool) -> some View {
        VStack(spacing: 0) {
            if hasHeader {
                header
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if scrollBody {
                ScrollView(.vertical, showsIndicators: true) {
                    bodyContent
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: bodyMaxHeight, alignment: .top)
            } else {
                bodyContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if hasFooter {
                footer
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(minWidth: minWidth, idealWidth: minWidth, maxWidth: maxWidth, alignment: .top)
        .frame(minHeight: minHeight > 0 ? minHeight : nil, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Body-only convenience

extension ModalPopup where Header == EmptyView, Footer == EmptyView {
    init(
        minWidth: CGFloat = ModalPopupDefaults.minWidth,
        minHeight: CGFloat = ModalPopupDefaults.minHeight,
        maxWidth: CGFloat = ModalPopupDefaults.maxWidth,
        maxHeight: CGFloat = ModalPopupDefaults.maxHeight,
        onBackdropDismiss: (() -> Void)? = nil,
        onEscape: (() -> Void)? = nil,
        @ViewBuilder body: () -> BodyContent
    ) {
        self.init(
            minWidth: minWidth,
            minHeight: minHeight,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            onBackdropDismiss: onBackdropDismiss,
            onEscape: onEscape,
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
        onEscape: (() -> Void)? = nil,
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
                    onEscape: onEscape,
                    header: header,
                    body: body,
                    footer: footer
                )
            }
        }
    }
}
