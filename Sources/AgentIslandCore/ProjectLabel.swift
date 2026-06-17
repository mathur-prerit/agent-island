import Foundation

/// Derives a friendly session label from the transcript's working directory.
public enum ProjectLabel {
    /// `lastPathComponent` of the **last** `cwd` recorded — the real project dir even when
    /// Claude Code was launched elsewhere (e.g. the home dir) and `cd`'d in later.
    /// Returns nil if no usable `cwd` is present.
    public static func fromTranscript(lines: [String]) -> String? {
        var lastCwd: String?
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty
            else { continue }
            lastCwd = cwd
        }
        guard let cwd = lastCwd else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
