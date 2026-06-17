import Foundation

/// Pure layout math for the road-trip theme's scrolling journey scene (AppKit-free, unit-tested).
///
/// The vehicle is pinned near the left of a fixed-width view; the world scrolls so roadside
/// milestone signs — one every `signEvery` tokens — slide past as the session burns tokens. The
/// app layer (`RoadSceneView`) turns this into Core Graphics drawing; all the positional maths
/// that decides *which* signs are on screen and *where* lives here so it can be tested without a UI.
public enum RoadJourney {
    /// Tokens between consecutive roadside signs.
    public static let signEvery = 5_000

    /// The vehicle the session is currently "driving", by token band (mirrors `JourneyMilestones`).
    public enum Stage: Equatable { case cycle, car, train, plane }

    public static func stage(forTokens tokens: Int) -> Stage {
        switch tokens {
        case ..<JourneyMilestones.cycle: return .cycle
        case ..<JourneyMilestones.car:   return .car
        case ..<JourneyMilestones.plane: return .train
        default:                          return .plane
        }
    }

    /// A roadside milestone sign at a token multiple of `signEvery`.
    public struct Sign: Equatable {
        public let tokens: Int     // 5_000, 10_000, …
        public let label: String   // "5k", "50k", …
        public let x: Double       // screen-space x (points from the view's left edge)
        public let isMajor: Bool   // a vehicle-upgrade milestone (50k/100k/200k) → bigger signboard
        public init(tokens: Int, label: String, x: Double, isMajor: Bool) {
            self.tokens = tokens; self.label = label; self.x = x; self.isMajor = isMajor
        }
    }

    public struct Layout: Equatable {
        public let signs: [Sign]    // left-to-right, only those within the (slightly padded) view
        public let vehicleX: Double // where to draw the vehicle (points from the left)
        public let stage: Stage
        public let airborne: Bool   // past the last milestone: the plane has taken off (danger)
    }

    /// Token milestones that read as "towns" — the vehicle-upgrade points — drawn as signboards.
    public static func isMajor(_ tokens: Int) -> Bool {
        tokens == JourneyMilestones.cycle || tokens == JourneyMilestones.car || tokens == JourneyMilestones.plane
    }

    static func label(forTokens tokens: Int) -> String {
        // Every sign is a multiple of `signEvery` (≥ 5_000), so a plain "<n>k" is always exact.
        "\(tokens / 1_000)k"
    }

    /// What the scene shows for `tokens` in a view `viewWidth` points wide. `segment` is the
    /// on-screen spacing between two adjacent signs; `anchorRatio` fixes the vehicle's x as a
    /// fraction of the width. The vehicle sits at the current token position, so a sign at token
    /// value `t` appears at `vehicleX + (t - tokens)/signEvery * segment`.
    public static func layout(tokens: Int,
                              viewWidth: Double,
                              segment: Double = 60,
                              anchorRatio: Double = 0.26) -> Layout {
        let tokens = max(0, tokens)
        let vehicleX = viewWidth * anchorRatio
        func screenX(_ t: Int) -> Double {
            vehicleX + (Double(t - tokens) / Double(signEvery)) * segment
        }
        // Include one extra segment of slack each side so the entering/leaving sign is present
        // (it gets clipped by the view) and the slide-in/out reads smoothly.
        let margin = segment
        var signs: [Sign] = []
        if segment > 0 {
            let loVal = Double(tokens) + Double(signEvery) * (-margin - vehicleX) / segment
            let hiVal = Double(tokens) + Double(signEvery) * (viewWidth + margin - vehicleX) / segment
            let kLo = max(1, Int((loVal / Double(signEvery)).rounded(.up)))
            var kHi = Int((hiVal / Double(signEvery)).rounded(.down))
            kHi = min(kHi, kLo + 63)   // defensive cap; the real range is only ~3-5 signs
            if kHi >= kLo {
                for k in kLo...kHi {
                    let t = k * signEvery
                    signs.append(Sign(tokens: t, label: label(forTokens: t), x: screenX(t), isMajor: isMajor(t)))
                }
            }
        }
        return Layout(signs: signs,
                      vehicleX: vehicleX,
                      stage: stage(forTokens: tokens),
                      airborne: tokens >= JourneyMilestones.plane)
    }
}
