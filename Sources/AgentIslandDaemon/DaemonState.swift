import Foundation
import AgentIslandCore

/// A serializable per-session snapshot the daemon writes to `state.json`.
public struct SessionSnapshot: Codable, Equatable {
    public var sessionID: String
    public var state: String     // working | waiting | waiting-permission | done | failed
    public var subActive: Int
    public var subDone: Int
    public var label: String?    // project name (lastPathComponent of the session's cwd), if known
    public var cwd: String?      // full working dir — lets the app find the transcript to sum tokens
    // Window identity for click-to-focus — the terminal env the hook saw at this session's events.
    // All Optional so an old state.json (written before this feature) still decodes cleanly.
    public var termProgram: String?    // e.g. "iTerm.app" (TERM_PROGRAM)
    public var itermSessionID: String? // e.g. "w2t0p0:<GUID>" (ITERM_SESSION_ID); GUID after the colon
    public var termBundleID: String?   // e.g. "com.googlecode.iterm2" (__CFBundleIdentifier)
    public init(sessionID: String, state: String, subActive: Int = 0, subDone: Int = 0,
                label: String? = nil, cwd: String? = nil,
                termProgram: String? = nil, itermSessionID: String? = nil, termBundleID: String? = nil) {
        self.sessionID = sessionID
        self.state = state
        self.subActive = subActive
        self.subDone = subDone
        self.label = label
        self.cwd = cwd
        self.termProgram = termProgram
        self.itermSessionID = itermSessionID
        self.termBundleID = termBundleID
    }
}

/// Extract the iTerm2 session GUID (the part after the last `:`) from an `ITERM_SESSION_ID` value
/// like `w2t0p0:E6101BA4-C887-4433-9901-DD2126E04CC7`. Returns nil if there's no usable GUID
/// component (empty input, no colon, or empty suffix). Pure + tested in the self-test.
public func itermGUID(from itermSessionID: String?) -> String? {
    guard let raw = itermSessionID, let idx = raw.lastIndex(of: ":") else { return nil }
    let guid = String(raw[raw.index(after: idx)...])
    return guid.isEmpty ? nil : guid
}

/// The full state document the daemon publishes and the app reads.
public struct DaemonState: Codable, Equatable {
    public var sessions: [SessionSnapshot]
    public init(sessions: [SessionSnapshot] = []) { self.sessions = sessions }
}

/// Stable string tokens bridging AgentStatus across the daemon↔app file boundary.
public extension AgentStatus {
    var stateToken: String {
        switch self {
        case .working: return "working"
        case .waitingForInput(.permission): return "waiting-permission"
        case .waitingForInput: return "waiting"
        case .finished(.failed): return "failed"
        case .finished: return "done"
        }
    }

    init(stateToken: String) {
        switch stateToken {
        case "working": self = .working
        case "waiting-permission": self = .waitingForInput(.permission)
        case "waiting": self = .waitingForInput(.stoppedTurn)
        case "failed": self = .finished(.failed)
        case "done": self = .finished(.success)
        default: self = .working
        }
    }
}
