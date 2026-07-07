import AppKit
import SwiftUI

/// The menu-bar label. It must read at a glance and NEVER be invisible:
///   • stopped        → `zzz` (asleep)
///   • starting/drain  → an hourglass
///   • running         → a small grid of squares, one per slot, tinted by that slot's state
///   • attention       → an alert triangle (contract mismatch, a failed required check, a broken slot)
///
/// The running grid is drawn as a NON-template NSImage: a SwiftUI view handed to the menu bar is
/// rendered as a template (monochrome alpha mask), which turned the colored squares invisible.
struct MenuBarIcon: View {
    @ObservedObject var app: AppState

    var body: some View {
        switch app.controller.state {
        case .stopped(let reason):
            // A crash (reason set) flags the menu bar; a clean/asked stop just sleeps.
            Image(systemName: reason == nil ? "zzz" : "exclamationmark.triangle.fill")
        case .starting, .draining:
            Image(systemName: "hourglass")
        case .running:
            if app.needsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
            } else {
                Image(nsImage: SlotGridIcon.image(for: app.allSlots.map { $0.state }))
            }
        }
    }
}

enum SlotGridIcon {
    /// A compact near-square grid of slot-status squares, drawn in AppKit so the colors survive
    /// the menu bar (isTemplate = false). Sits in the ~15pt menu-bar area.
    static func image(for states: [String]) -> NSImage {
        let items = states.isEmpty ? ["idle"] : states     // running-but-no-slots → one square
        let n = items.count
        let cols = max(1, Int(Double(n).squareRoot().rounded(.up)))
        let rows = Int((Double(n) / Double(cols)).rounded(.up))
        let side: CGFloat = n <= 1 ? 13 : n <= 4 ? 7 : n <= 9 ? 5 : 4
        let gap: CGFloat = 1.5
        let w = CGFloat(cols) * side + CGFloat(cols - 1) * gap
        let h = CGFloat(rows) * side + CGFloat(rows - 1) * gap

        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            for (i, state) in items.enumerated() {
                let col = i % cols, row = i / cols
                let x = CGFloat(col) * (side + gap)
                let y = h - CGFloat(row + 1) * side - CGFloat(row) * gap   // fill top row first
                color(for: state).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: side, height: side),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func color(for state: String) -> NSColor {
        switch state {
        case "busy": return .systemGreen
        case "broken": return .systemRed
        case "idle": return .systemBlue
        default: return .systemGray            // cold / unknown
        }
    }
}
