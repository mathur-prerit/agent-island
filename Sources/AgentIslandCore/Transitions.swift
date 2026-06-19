import Foundation

/// A session lifecycle transition worth a sound cue. Edge-triggered: each fires only on the step
/// *into* the state, never while already in it. Themes map these to clips (the Road Runner theme
/// plays an arcade set: game-start / checkpoint / goal / game-over).
public enum SoundTransition: Equatable, Sendable {
    case startedWorking                // → working from a non-working / first-seen state
    case enteredWaiting(WaitReason)    // → waiting-for-user-input (your turn) from a non-waiting state
    case enteredFinished(Verdict)      // → finished(success/failed/unknown)

    /// Coarse, user-facing cue key for per-cue muting in the Sound menu (start / waiting / finished /
    /// failed). `nil` = no user-mutable cue for this transition (the silent `.unknown` verdict). Pure +
    /// pinned by the self-test so the menu toggles and the play gate speak the same vocabulary.
    public var muteKey: String? {
        switch self {
        case .startedWorking:            return "start"
        case .enteredWaiting:            return "waiting"
        case .enteredFinished(.success): return "finished"
        case .enteredFinished(.failed):  return "failed"
        case .enteredFinished(.unknown): return nil
        }
    }
}

/// Detects the sound-worthy transition (if any) between two consecutive observations of a session.
/// Pure and AppKit-free so the framework-free self-test runner can cover it.
public enum TransitionDetector {
    /// The transition from the previous status to the current one, or `nil` for none.
    /// `old == nil` means first sighting: it establishes a baseline and is silent (so the app
    /// doesn't fire a burst of jingles for sessions already in flight at launch).
    public static func transition(from old: AgentStatus?, to new: AgentStatus) -> SoundTransition? {
        guard let old else { return nil }   // first sighting → baseline, silent
        switch new {
        case .finished(let v):
            if case .finished = old { return nil }
            return .enteredFinished(v)
        case .waitingForInput(let r):
            if case .waitingForInput = old { return nil }
            return .enteredWaiting(r)
        case .working:
            if case .working = old { return nil }
            return .startedWorking
        }
    }
}

/// The neutral, non-theme lifecycle cue set: a pure transition→clip-name mapping. The App target
/// resolves these names to bundled WAVs (under `Themes/Default/`); kept here, framework-free, so the
/// self-test can pin the mapping. `nil` means "no cue for this transition" (matching JourneyTheme,
/// which is also silent on `.unknown`).
public enum DefaultSoundSet {
    /// The clip base-name for a transition, or `nil` for silence.
    public static func clipName(for transition: SoundTransition) -> String? {
        switch transition {
        case .startedWorking:            return "started"
        case .enteredWaiting:            return "waiting"
        case .enteredFinished(.success): return "finished_ok"
        case .enteredFinished(.failed):  return "finished_fail"
        case .enteredFinished(.unknown): return nil
        }
    }
}

/// Time-based gate so a burst of transitions on one refresh tick doesn't fire overlapping clips.
public enum PlayThrottle {
    /// True if a new clip may start: at least `cooldown` seconds since the last play.
    public static func allows(now: Date, last: Date, cooldown: TimeInterval) -> Bool {
        now.timeIntervalSince(last) >= cooldown
    }
}
