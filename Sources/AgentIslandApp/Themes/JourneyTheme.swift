import AppKit
import Foundation
import AgentIslandCore

// MARK: - Road Trip theme (id "journey")  (formerly "Road Runner")

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
    let displayName = "Road Trip"
    let showsPersonaGlyph = false   // the road scene is the indicator

    func makeScene() -> ThemeScene { JourneyScene() }
    func icon() -> NSImage { IslandIcons.symbol("car.fill", pointSize: 12) }

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

// MARK: - Journey scene

/// The Road Runner indicator. Holds both sub-views and shows exactly one per state:
/// - working/waiting → the wide scrolling `RoadSceneView` (driving, or stopped at a signal),
///   which `prefersOwnRow` so it sits on its own banner row above the title;
/// - failed/finished/idle → a small tintable SF Symbol (warning / checkered flag / parking sign)
///   shown inline beside the title.
/// `view` returns whichever sub-view is active, so the row places only the live indicator (the
/// road banner vs. the inline icon) exactly as the old `cueRoad`/`cueImage` split did.
final class JourneyScene: ThemeScene {
    private let road = RoadSceneView()
    private let icon = NSImageView()
    private var roadActive = false

    init() {
        // The road scene is a wide banner — give it room so the vehicle, milestone signs and
        // signal all read distinctly (same fixed 290×26 the old cueRoad carried in the row).
        road.isHidden = true
        NSLayoutConstraint.activate([
            road.widthAnchor.constraint(equalToConstant: 290),
            road.heightAnchor.constraint(equalToConstant: 26),
        ])
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.isHidden = true
    }

    /// The active sub-view (road banner while working/waiting; inline icon otherwise).
    var view: NSView { roadActive ? road : icon }
    /// Only the road wants its own banner row; the inline icon sits beside the title.
    var prefersOwnRow: Bool { roadActive }

    func apply(_ snapshot: RowSnapshot) {
        switch snapshot.state {
        case .working:
            road.tokens = snapshot.tokens
            road.mode = .driving
            roadActive = true
        case let .waiting(reason):
            road.tokens = snapshot.tokens
            road.mode = .stopped(reason == .permission ? .permission : .turnEnd)
            roadActive = true
        case .failed:
            setIcon(IslandIcons.symbol("exclamationmark.triangle.fill"), tint: .systemRed)
        case .finished:
            setIcon(IslandIcons.symbol("flag.checkered"), tint: .systemGreen)
        case .idle:
            setIcon(IslandIcons.symbol("parkingsign"), tint: .secondaryLabelColor)
        }
        // Keep the inactive sub-view hidden so a stale frame can't flash through during a swap.
        road.isHidden = !roadActive
        icon.isHidden = roadActive
    }

    func tick(_ frame: Int) { road.frame_ = frame }

    func animates(_ snapshot: RowSnapshot) -> Bool {
        switch snapshot.state {
        case .working, .waiting: return true
        case .idle, .failed, .finished: return false
        }
    }

    private func setIcon(_ image: NSImage, tint: NSColor?) {
        icon.image = image
        icon.contentTintColor = tint   // nil → the image draws with its own colours
        roadActive = false
    }
}
