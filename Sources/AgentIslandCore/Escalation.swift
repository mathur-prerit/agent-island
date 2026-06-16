import Foundation

/// The WAITING escalation rungs, lowest to highest.
public enum EscalationTier: Int, Comparable, Sendable {
    case silentPulse = 0
    case bounce = 1
    case brightness = 2
    case haptic = 3
    case sound = 4
    public static func < (lhs: EscalationTier, rhs: EscalationTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Escalation thresholds and channel toggles. Quiet by default: muted (no sound),
/// no haptic — so the ladder caps at `.brightness` until the developer opts in.
public struct EscalationConfig: Sendable, Equatable {
    public var bounceAfter: TimeInterval
    public var brightnessAfter: TimeInterval
    public var hapticAfter: TimeInterval
    public var soundAfter: TimeInterval
    public var hapticEnabled: Bool
    public var soundEnabled: Bool

    public init(bounceAfter: TimeInterval = 30,
                brightnessAfter: TimeInterval = 60,
                hapticAfter: TimeInterval = 90,
                soundAfter: TimeInterval = 120,
                hapticEnabled: Bool = false,
                soundEnabled: Bool = false) {
        self.bounceAfter = bounceAfter
        self.brightnessAfter = brightnessAfter
        self.hapticAfter = hapticAfter
        self.soundAfter = soundAfter
        self.hapticEnabled = hapticEnabled
        self.soundEnabled = soundEnabled
    }
}

public enum EscalationLadder {
    /// The tier for a WAITING session given effective elapsed time. Haptic/sound rungs
    /// are reachable only when their channel is enabled, so the default (muted, no
    /// haptic) caps at `.brightness` — purely visual. WAITING never self-dismisses;
    /// this only computes how loud the (still-present) signal is.
    public static func tier(effectiveElapsed t: TimeInterval,
                            config: EscalationConfig = .init()) -> EscalationTier {
        if config.soundEnabled, t >= config.soundAfter { return .sound }
        if config.hapticEnabled, t >= config.hapticAfter { return .haptic }
        if t >= config.brightnessAfter { return .brightness }
        if t >= config.bounceAfter { return .bounce }
        return .silentPulse
    }
}

public enum WaitingClock {
    /// Effective elapsed time driving escalation. Acknowledgement resets the baseline
    /// (caller supplies a fresh `rawElapsed`); dismiss-snooze freezes the clock, so
    /// snoozed time is subtracted and escalation resumes from where it paused.
    public static func effectiveElapsed(rawElapsed: TimeInterval,
                                        snoozedTotal: TimeInterval) -> TimeInterval {
        max(0, rawElapsed - snoozedTotal)
    }
}
