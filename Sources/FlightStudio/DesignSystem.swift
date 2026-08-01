import SwiftUI

/// The app's one structural device: a small tracked uppercase label used for
/// every section heading, so all three panes read as one instrument.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(.secondary)
    }
}

/// Timeline semantics — the only colour in the chrome, and each hue means one
/// thing everywhere it appears: accent = kept, red = removed, orange = speed.
enum TL {
    static let kept = Color.accentColor.opacity(0.28)
    static let cut = Color.red.opacity(0.45)
    static let speed = Color.orange.opacity(0.50)
    static let track = Color.primary.opacity(0.06)
}

extension View {
    /// One consistent tool-button look for the editing bench.
    func benchButton() -> some View {
        self.buttonStyle(.bordered).controlSize(.small)
    }
}
