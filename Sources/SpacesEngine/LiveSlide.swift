import CDockSwipe

/// The app controls the gesture's travel. macOS draws the slide and handles the release.
struct LiveSlide {
    static let initialTravel = 0.000016
    let direction: DSDirection
    let start: Double
    let duration: Double
    let spaceCount: Int
    private(set) var position = Self.initialTravel

    mutating func advance(to now: Double) -> (delta: Double, ended: Bool) {
        let fraction = min(max((now - start) / duration, 0), 1)
        // Ease into the slide and leave the final part for the Dock to settle.
        let eased = fraction * fraction * (3 - 2 * fraction)
        // Empirical Dock scaling: the gesture travel for an adjacent Space depends on the display's Space count.
        let adjacentTravel = 1 + 1 / Double(max(spaceCount - 1, 1))
        let next = max(position, eased * adjacentTravel * 0.85)
        let delta = next - position
        position = next
        return (delta, fraction >= 1)
    }
}
