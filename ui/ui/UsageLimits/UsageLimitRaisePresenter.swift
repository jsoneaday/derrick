import Combine
import Foundation
import PolicyUserInteraction
import SwiftUI

@MainActor
final class UsageLimitRaisePresenter: ObservableObject {
    static let shared = UsageLimitRaisePresenter()

    @Published private(set) var activeEvent: PolicyUserEvent?
    @Published private(set) var metadata: UsageLimitRaiseMetadata?
    @Published private(set) var isPresented = false
    @Published var selectedPreset: Int?
    @Published var customLimitText = ""

    private var continuation: CheckedContinuation<UsageLimitRaiseOutcome, Never>?

    private init() {}

    func present(event: PolicyUserEvent) async -> UsageLimitRaiseOutcome {
        guard let meta = UsageLimitRaiseMetadata.decode(from: event) else {
            return .stop
        }
        if isPresented {
            return .stop
        }
        activeEvent = event
        metadata = meta
        selectedPreset = meta.selectablePresets.first(where: { $0 >= meta.sessionProposedLimit })
            ?? meta.selectablePresets.first
        customLimitText = selectedPreset.map { UsageLimitFormatting.grouped($0) } ?? ""
        isPresented = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func selectPreset(_ value: Int) {
        selectedPreset = value
        customLimitText = UsageLimitFormatting.grouped(value)
    }

    var resolvedPermanentLimit: Int? {
        guard let metadata else { return nil }
        if let preset = selectedPreset, preset > metadata.currentLimit, preset <= metadata.absoluteMax {
            return preset
        }
        let digits = customLimitText.filter(\.isNumber)
        guard let parsed = Int(digits), parsed > metadata.currentLimit, parsed <= metadata.absoluteMax else {
            return nil
        }
        return parsed
    }

    func stop() {
        finish(.stop)
    }

    func raiseSession() {
        guard let metadata else {
            finish(.stop)
            return
        }
        let limit = min(metadata.sessionProposedLimit, metadata.absoluteMax)
        guard limit > metadata.currentLimit else {
            finish(.stop)
            return
        }
        finish(.session(limit))
    }

    func raisePermanent() {
        guard let limit = resolvedPermanentLimit else { return }
        finish(.permanent(limit))
    }

    private func finish(_ outcome: UsageLimitRaiseOutcome) {
        isPresented = false
        activeEvent = nil
        metadata = nil
        selectedPreset = nil
        customLimitText = ""
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

struct UsageLimitRaiseModalView: View {
    @ObservedObject var presenter: UsageLimitRaisePresenter

    var body: some View {
        if let event = presenter.activeEvent, let metadata = presenter.metadata {
            VStack(alignment: .leading, spacing: 14) {
                PolicyEventModalHeader(event: event)

                VStack(alignment: .leading, spacing: 10) {
                    Text(event.summary)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail = event.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Raise permanently (saved in Settings)")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)

                    if metadata.selectablePresets.isEmpty {
                        Text("Already at the maximum allowed (\(UsageLimitFormatting.grouped(metadata.absoluteMax))).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(metadata.selectablePresets, id: \.self) { preset in
                                presetChip(preset, metadata: metadata)
                            }
                        }

                        HStack(spacing: 8) {
                            Text("Custom")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("e.g. 750,000", text: $presenter.customLimitText)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: presenter.customLimitText) { _, _ in
                                    presenter.selectedPreset = nil
                                }
                            Text("max \(UsageLimitFormatting.compact(metadata.absoluteMax))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 20)

                HStack(spacing: 10) {
                    Button("Stop", action: presenter.stop)
                        .buttonStyle(ModalSecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)

                    Spacer(minLength: 0)

                    Button("This session only") {
                        presenter.raiseSession()
                    }
                    .buttonStyle(ModalSecondaryButtonStyle())
                    .disabled(metadata.sessionProposedLimit <= metadata.currentLimit)

                    Button("Save permanent") {
                        presenter.raisePermanent()
                    }
                    .buttonStyle(ModalPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(presenter.resolvedPermanentLimit == nil)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .padding(.top, 4)
            }
        }
    }

    private func presetChip(_ preset: Int, metadata: UsageLimitRaiseMetadata) -> some View {
        let selected = presenter.selectedPreset == preset
        return Button {
            presenter.selectPreset(preset)
        } label: {
            Text(UsageLimitFormatting.compact(preset))
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected
                            ? Color(nsColor: .labelColor).opacity(0.12)
                            : Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            selected ? Color(nsColor: .labelColor).opacity(0.35) : Color(nsColor: .separatorColor),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

/// Simple left-to-right chip flow for preset buttons.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
