import SwiftUI

struct AskAIDoor: View {
    @ObservedObject var browser: Browser
    var compact = false
    var body: some View {
        Button { browser.askFromAddress() } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Ask AI")
            }
            .font(.system(size: compact ? 11 : 12.5, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 26 : 32)
            .background(Palette.wash, in: Capsule())
        }
        .buttonStyle(.plain).help("Ask AI").accessibilityLabel("Ask AI")
    }
}
