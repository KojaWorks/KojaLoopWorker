import Foundation

/// The host-wide weighted slot budget (`max_slots`) and the port bands derived from it.
public enum Budget {
    /// How many more slots of `weight` fit in `remaining` budget units. The epsilon keeps a
    /// weight like 0.1 from undercounting (0.3 / 0.1 is 2.9999999999999996 in floating point).
    public static func affordable(remaining: Double, weight: Double) -> Int {
        max(0, Int((remaining / weight) + 1e-9))
    }

    /// The number of slots each project gets in its pool, in the order of `projects`.
    ///
    /// Every pool is capped at `band` (default `ceil(maxSlots)`) so its slots stay inside its
    /// port band. Hot projects reserve their slots in config order, each also capped by what the
    /// budget still affords. Cold projects provision per card, so their pools only bound
    /// concurrency, and fill checks the budget before each start.
    public static func slotTargets(for projects: [ProjectSpec], maxSlots: Double, band: Int? = nil) -> [Int] {
        var remaining = maxSlots
        let band = band ?? bandSize(maxSlots: maxSlots)
        return projects.map { p in
            guard p.hot else { return min(p.slots, band) }
            let n = min(p.slots, band, affordable(remaining: remaining, weight: p.weight))
            remaining -= Double(n) * p.weight
            return n
        }
    }

    /// Slots per port band: `max(ceil(maxSlots), 1)`.
    public static func bandSize(maxSlots: Double) -> Int { max(Int(maxSlots.rounded(.up)), 1) }

    /// The first port of slot `index` of the project that holds port band `band`, with
    /// `bandSize` slots per band.
    public static func port(basePort: Int, portStep: Int, bandSize: Int, band: Int, index: Int) -> Int {
        basePort + (band * bandSize + index) * portStep
    }

    /// The lowest band index not in `used`, so a band freed by a removed project is reused.
    public static func freeBand(used: Set<Int>) -> Int {
        var b = 0
        while used.contains(b) { b += 1 }
        return b
    }
}
