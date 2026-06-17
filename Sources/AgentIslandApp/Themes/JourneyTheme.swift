import AppKit
import Foundation
import AgentIslandCore

// MARK: - Road Runner theme (id "journey")

/// Token burn drives a journey: a vehicle that upgrades by tokens used (bike→car→train→plane)
/// "drives" along a scrolling road past roadside signs every 5K tokens, with signboard "towns" at
/// the upgrade milestones (50K / 100K / 200K); past 200K the plane takes off. Waiting shows a
/// traffic light; failed a warning; finished the chequered flag; idle a parking sign.
///
/// The theme also carries an arcade lifecycle sound set (see `sound(for:)`): game-start when a
/// session begins working, a checkpoint chime when it stops and waits for you, a goal fanfare on
/// success and a game-over tune on failure.
struct JourneyTheme: IslandTheme {
    let id = "journey"             // persisted in UserDefaults["islandTheme"] — keep stable
    let displayName = "Road Runner"
    let showsPersonaGlyph = false   // the road scene is the indicator

    func animates(_ row: IslandPanel.Row) -> Bool { row.spinning || row.waitReason != nil }

    func cue(for row: IslandPanel.Row, frame: Int) -> Cue {
        if row.id == "idle" { return .icon(IslandIcons.symbol("parkingsign"), tint: .secondaryLabelColor) }
        if row.spinning { return .road(tokens: row.tokens, mode: .driving) }
        if let wait = row.waitReason {
            let kind: RoadMode.StopKind = (wait == .permission) ? .permission : .turnEnd
            return .road(tokens: row.tokens, mode: .stopped(kind))
        }
        if row.verdict == .failed { return .icon(IslandIcons.symbol("exclamationmark.triangle.fill"), tint: .systemRed) }
        if row.dimmed { return .icon(IslandIcons.symbol("flag.checkered"), tint: .systemGreen) }
        return .icon(IslandIcons.symbol("parkingsign"), tint: .secondaryLabelColor)
    }

    func tint(for row: IslandPanel.Row) -> NSColor { stateTint(row) }

    /// Arcade lifecycle cues, mapped by clip name (bundled under `Themes/RoadRunner/`).
    func sound(for transition: SoundTransition) -> URL? {
        switch transition {
        case .startedWorking:            return Self.clip("01_game_start")
        case .enteredWaiting:            return Self.clip("02_check_point")   // your turn — it stopped
        case .enteredFinished(.success): return Self.clip("03_goal")
        case .enteredFinished(.failed):  return Self.clip("04_game_over")
        case .enteredFinished(.unknown): return nil
        }
    }

    /// Resolve a bundled clip. Tries the likely subdirectory layouts SwiftPM's `.copy` may produce,
    /// then a flat lookup — robust to how the resource folder lands in the bundle.
    private static func clip(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "RoadRunner")
            ?? Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Themes/RoadRunner")
            ?? Bundle.module.url(forResource: name, withExtension: "wav")
    }
}
