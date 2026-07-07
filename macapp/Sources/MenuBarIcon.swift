import SwiftUI

/// The menu-bar label. It must read at a glance and NOT look like a running toggle:
///   • stopped        → `zzz` (asleep), so it's obvious nothing is running
///   • starting/drain  → an hourglass
///   • running         → a small grid of squares, one per slot, each tinted by that slot's state
///   • attention       → an alert triangle (contract mismatch, a failed required check, a broken slot)
struct MenuBarIcon: View {
    @ObservedObject var app: AppState

    var body: some View {
        switch app.controller.state {
        case .stopped:
            Image(systemName: "zzz")
        case .starting, .draining:
            Image(systemName: "hourglass")
        case .running:
            if app.needsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
            } else {
                SlotGrid(slots: app.allSlots)
            }
        }
    }
}

/// A compact near-square grid of slot-status squares, sized to sit in the ~18pt menu-bar area.
private struct SlotGrid: View {
    let slots: [SlotSnapshot]

    var body: some View {
        let states = slots.isEmpty ? ["idle"] : slots.map { $0.state }   // running-but-no-slots → one square
        let cols = max(1, Int(ceil(Double(states.count).squareRoot())))
        let side: CGFloat = states.count <= 4 ? 6 : (states.count <= 9 ? 5 : 4)
        let rows = stride(from: 0, to: states.count, by: cols).map { Array(states[$0..<min($0 + cols, states.count)]) }

        VStack(spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 1) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, state in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(SlotGrid.color(for: state))
                            .frame(width: side, height: side)
                    }
                }
            }
        }
        .frame(maxHeight: 18)
    }

    static func color(for state: String) -> Color {
        switch state {
        case "busy": return .green
        case "broken": return .red
        case "idle": return .blue
        default: return .gray            // cold / unknown
        }
    }
}
