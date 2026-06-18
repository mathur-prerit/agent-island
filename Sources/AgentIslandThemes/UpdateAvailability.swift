import Foundation

// The PURE, network-free half of the "update available" indicator. The App-side `UpdateCheck` owns the
// one GitHub Releases fetch; everything decidable from strings lives here so `AgentIslandSelfTest` can
// cover it from fixtures with no network. Two pieces:
//   1. `parseLatestTag` — pull a release tag out of the GitHub `releases/latest` JSON and normalise it
//      to a bare dotted-numeric version (strip a leading `v`/`V`).
//   2. `UpdateAvailability.decide` — given installed / latest / dismissed versions, decide whether to
//      show the badge and for which version, reusing the shared `SemVer` comparison (no duplicate type).

/// Whether the app should surface an "update available" cue, and the version it points at. Computed
/// purely from three version strings; the App turns `.available` into a menu item + glyph cue.
public enum UpdateAvailability: Equatable {
    /// No newer-and-undismissed release: up to date, the fetch failed, or the user dismissed this version.
    case upToDate
    /// A strictly-newer-than-installed release the user hasn't dismissed; carries the normalised version.
    case available(version: String)

    /// The version to offer, or nil when up to date — convenience for the menu/glyph code.
    public var offeredVersion: String? {
        if case .available(let v) = self { return v }
        return nil
    }

    /// Decide from the three versions. Show "update available" iff the latest tag is STRICTLY newer than
    /// what's installed AND strictly newer than the last version the user dismissed — so a dismissed
    /// release stays quiet until a yet-newer one ships. All inputs are already-normalised dotted versions
    /// (parse a GitHub tag with `parseLatestTag` first). A nil/blank `latest` (offline / parse miss) is
    /// always `.upToDate` — the indicator is strictly opt-in on a successful, newer fetch.
    public static func decide(installed: String, latest: String?, dismissed: String?) -> UpdateAvailability {
        guard let latest = latest, !latest.isEmpty else { return .upToDate }
        guard SemVer.isNewer(latest, than: installed) else { return .upToDate }
        guard SemVer.isNewer(latest, than: dismissed) else { return .upToDate }
        return .available(version: latest)
    }
}

/// Pulls `tag_name` out of a GitHub `releases/latest` JSON blob and normalises it to a bare dotted
/// version. Pure so the App's network fetch can hand its bytes straight here, and the self-test can
/// drive it from a fixture string. Returns nil for non-JSON / a missing-or-empty tag — the caller
/// treats nil as "no usable latest" (→ `.upToDate`), never a crash.
public enum ReleaseFeed {
    public static func parseLatestTag(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        return normalizeTag(tag)
    }

    /// Strip a single leading `v`/`V` and surrounding whitespace from a release tag (`v0.4.0` → `0.4.0`,
    /// `0.4.0` → `0.4.0`). Returns nil for an empty/whitespace-only tag; otherwise the trimmed body —
    /// `SemVer` is itself lenient on any odd trailer, so junk like `nightly` flows through harmlessly
    /// (and compares as 0.0.0, i.e. never "newer").
    public static func normalizeTag(_ tag: String) -> String? {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
        return s.isEmpty ? nil : s
    }
}
