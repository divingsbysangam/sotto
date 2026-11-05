import AppKit
import SwiftUI

/// The shared window shell. Destination content stays independent of the navigation bar.
struct SottoTopNavigation: View {
    let navigation: SottoNavigation
    let status: SottoStatusPresentation
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: SottoDesign.spacing) {
            HStack(spacing: SottoDesign.spacing / 2) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text("Sotto")
                    .font(.headline)
                    .foregroundStyle(SottoDesign.cream)
            }
            .accessibilityElement(children: .combine)

            ScrollView(.horizontal) {
                HStack(spacing: SottoDesign.spacing / 4) {
                    ForEach(SottoDestination.allCases) { destination in
                        tab(destination)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)

            HStack(spacing: SottoDesign.spacing / 4) {
                Circle()
                    .fill(status.tone == .ready || status.tone == .recording
                          ? SottoDesign.accent : SottoDesign.cream.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(status.title == "Ready to dictate" ? "Ready" : status.title)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(SottoDesign.cream)
            .accessibilityLabel(status.title)
        }
        .padding(.horizontal, SottoDesign.spacing / 2)
        .frame(height: 40)
        .background {
            RoundedRectangle(cornerRadius: SottoDesign.cornerRadius)
                .fill(reduceTransparency ? SottoDesign.charcoal : SottoDesign.charcoal.opacity(0.8))
        }
        .overlay {
            RoundedRectangle(cornerRadius: SottoDesign.cornerRadius)
                .strokeBorder(SottoDesign.cream.opacity(0.1))
        }
        .modifier(TopNavigationGlass(reduceTransparency: reduceTransparency))
    }

    private func tab(_ destination: SottoDestination) -> some View {
        let selected = navigation.destination == destination
        return Button {
            navigation.destination = destination
        } label: {
            Label(destination.rawValue, systemImage: destination.symbol.rawValue)
                .font(.caption)
                .foregroundStyle(selected ? SottoDesign.cream : SottoDesign.cream.opacity(0.72))
                .padding(.horizontal, SottoDesign.spacing / 2)
                .padding(.vertical, SottoDesign.spacing / 3)
                .background(selected ? SottoDesign.accent.opacity(0.22) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "")
    }
}

struct SottoWindowFooter: View {
    let modelLoaded: Bool

    var body: some View {
        HStack(spacing: SottoDesign.spacing / 4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            Text(modelLoaded ? "Local model loaded" : "Local model not ready")
            Text("·")
            Text("Audio never leaves this Mac")
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(SottoDesign.cream.opacity(0.6))
    }
}

private struct TopNavigationGlass: ViewModifier {
    let reduceTransparency: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: SottoDesign.cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: SottoDesign.cornerRadius))
        }
    }
}
