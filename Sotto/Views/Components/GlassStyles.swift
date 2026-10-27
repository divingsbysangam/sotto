import SwiftUI

// MARK: - Glass Card Modifier
@available(macOS 26.0, *)
struct GlassCard: ViewModifier {
    var tint: Color? = nil
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background {
                if let tint {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .glassEffect(.regular.tint(tint))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .glassEffect(.regular)
                }
            }
    }
}

// MARK: - View Extensions
extension View {
    @available(macOS 26.0, *)
    func glassCard(tint: Color? = nil, cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCard(tint: tint, cornerRadius: cornerRadius))
    }

    @available(macOS 26.0, *)
    func glassButton() -> some View {
        self.glassEffect(.regular.interactive())
    }
}
