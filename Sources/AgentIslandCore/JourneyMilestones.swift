import Foundation

/// Token milestones for the "road trip" theme: the vehicle upgrades as the session burns tokens.
/// 🚲 cycle → 🚗 car → 🚆 train → ✈️ plane, with the plane "flying dangerously" past 200K.
public enum JourneyMilestones {
    public static let cycle = 50_000     // 🚲 below this
    public static let car = 100_000      // 🚗 up to here
    public static let plane = 200_000    // 🚆 up to here, then ✈️ (danger)

    public static func vehicle(forTokens tokens: Int) -> String {
        switch tokens {
        case ..<cycle: return "🚲"
        case ..<car:   return "🚗"
        case ..<plane: return "🚆"
        default:       return "✈️"
        }
    }
}
