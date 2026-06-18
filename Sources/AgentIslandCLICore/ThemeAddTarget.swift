import Foundation
import AgentIslandThemes

// PURE classification for `theme add <id|url>`: decide whether the argument names a catalog id (fetch
// its entry from the hosted index) or is a direct https zip URL. The discrimination is pure (no
// network) so the self-test can assert it; the executable then does the matching fetch + hands the
// bytes to the SHARED `ThemeInstaller.installFromLocalZip` (no validation/extraction is reimplemented).

public enum ThemeAddTarget: Equatable {
    /// The argument is an https URL → download those exact bytes and install them.
    case directURL(String)
    /// The argument is a catalog id → fetch the index, find the entry (with its sha256/sizeBytes), and
    /// install that. The integrity claims come from the catalog, so the download is verified end-to-end.
    case catalogID(String)
}

public enum ThemeAdd {
    /// Classify the `theme add` argument. An https URL (per the same `isHTTPSURL` gate the app uses) is
    /// a direct download; anything that isn't a URL with a scheme is treated as a catalog id. A
    /// non-https URL (`http://`, `file://`, …) returns nil — refused up front, never silently treated
    /// as an id (so `file:///etc/passwd` can't sneak through as an "id").
    public static func classify(_ argument: String) -> ThemeAddTarget? {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = URL(string: trimmed)?.scheme, !scheme.isEmpty {
            // It parses as a URL with a scheme → it must be https, else refuse (don't fall back to id).
            return ThemeCatalogEntry.isHTTPSURL(trimmed) ? .directURL(trimmed) : nil
        }
        // No scheme → a bare id. Must be a single safe path segment (it becomes the install folder).
        guard ThemeCatalogEntry.isSafeID(trimmed) else { return nil }
        return .catalogID(trimmed)
    }

    /// Build a self-verifying catalog entry for a DIRECT-URL add, where there are no hosted integrity
    /// claims. We've downloaded `data`; its size + sha256 ARE the claims, so the shared installer's
    /// `verify` step is a tautology here (a corrupt/truncated transfer simply yields a different blob).
    /// All the OTHER gates (zip inspection, ditto, post-extraction lstat/PackValidator, strict manifest,
    /// direct-child atomic move) still run unchanged. `id` is the manifest id the caller peeked from the
    /// extracted archive (so it equals the install folder name the loader enforces).
    public static func selfVerifyingEntry(id: String, url: String, data: Data) -> ThemeCatalogEntry {
        ThemeCatalogEntry(id: id,
                          displayName: id,
                          version: "0",
                          url: url,
                          sha256: ThemeCatalogEntry.sha256Hex(data),
                          sizeBytes: data.count,
                          minAppVersion: nil)
    }
}
