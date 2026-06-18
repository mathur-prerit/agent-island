import Foundation
import CryptoKit

// AppKit-free model of the hosted theme catalog — the JSON index a user fetches to discover data
// themes that aren't bundled with the app (the runtime-download target). Lives in this target (NOT
// the App) so `AgentIslandSelfTest` can cover decode + the integrity check WITHOUT a network: the
// network fetch + on-disk extraction are the App-side `ThemeDownloader`'s job, everything here is
// pure (decode a blob of bytes, verify a blob of bytes).
//
// Like a `theme.json` manifest, the catalog is fully untrusted (fetched over the network), so decode
// is strict (unknown keys rejected — no smuggling) and the integrity check is the gate the App runs
// BEFORE it ever extracts a downloaded zip: a blob whose sha256/size doesn't match its catalog entry
// is rejected before a single byte reaches `ditto`.

/// One downloadable theme as described by the hosted index. Mirrors a `theme.json`'s `id` /
/// `displayName` / `minAppVersion`, plus the download coordinates (`url`) and the integrity claims
/// (`sha256`, `sizeBytes`) the downloader verifies against the fetched bytes.
public struct ThemeCatalogEntry: Codable, Equatable, Sendable {
    public let id: String              // the theme id == its on-disk folder name (loader enforces it)
    public let displayName: String     // menu label
    public let version: String         // the theme's own version (cosmetic; shown/logged)
    public let url: String             // where to download the zip
    public let sha256: String          // expected SHA-256 of the zip, lowercase hex (64 chars)
    public let sizeBytes: Int          // expected byte length of the zip (enforced before reading body)
    public let minAppVersion: String?  // grey out / refuse on an older app (gated via SemVer)

    public init(id: String, displayName: String, version: String, url: String,
                sha256: String, sizeBytes: Int, minAppVersion: String?) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.minAppVersion = minAppVersion
    }

    // Strict keys: an unknown field is a decode failure (parallels the manifest loader's strict
    // top-level keys — a hostile/typo'd index shouldn't decode into a half-populated entry).
    private enum CodingKeys: String, CodingKey {
        case id, displayName, version, url, sha256, sizeBytes, minAppVersion
    }

    /// Keys an entry may carry — anything else rejects the catalog. (Swift's synthesized `Codable`
    /// silently IGNORES unknown keys, so strictness is enforced explicitly before the typed decode,
    /// matching `ThemeManifestLoader`'s posture: an `exec`/`script` field must never be smuggled in.)
    static let allowedKeys: Set<String> =
        ["id", "displayName", "version", "url", "sha256", "sizeBytes", "minAppVersion"]
}

/// The hosted index: a list of downloadable theme entries. The top-level JSON is `{ "themes": [...] }`
/// (an object, not a bare array) so the index can grow new top-level fields later without breaking
/// the wire format.
public struct ThemeCatalog: Codable, Equatable, Sendable {
    public let themes: [ThemeCatalogEntry]
    public init(themes: [ThemeCatalogEntry]) { self.themes = themes }

    private enum CodingKeys: String, CodingKey { case themes }

    /// Decode a fetched index blob. Strict: unknown keys (top-level or per-entry) reject the whole
    /// catalog rather than being silently ignored. A `JSONSerialization` pass enforces the key
    /// allowlists first (Swift's synthesized `Codable` would otherwise drop unknown keys on the
    /// floor), then the typed decode produces the model. Network-free.
    public static func decode(_ data: Data) -> Result<ThemeCatalog, ThemeCatalogError> {
        // Strict-key gate: the wire shape must be `{ "themes": [ {<allowed keys>}, … ] }`.
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["themes"] as? [Any] else {
            return .failure(.malformedIndex)
        }
        for key in root.keys where key != "themes" { return .failure(.malformedIndex) }
        for entry in entries {
            guard let dict = entry as? [String: Any] else { return .failure(.malformedIndex) }
            for key in dict.keys where !ThemeCatalogEntry.allowedKeys.contains(key) {
                return .failure(.malformedIndex)   // an unrecognized field (e.g. exec) -> reject
            }
        }
        // Shape is sound; let the typed decoder enforce required fields + types.
        do {
            return .success(try JSONDecoder().decode(ThemeCatalog.self, from: data))
        } catch {
            return .failure(.malformedIndex)
        }
    }
}

/// Why a catalog operation failed. App-side download/IO errors live in the downloader's own error
/// type; these are the pure, network-free catalog reasons so the self-test can assert them.
public enum ThemeCatalogError: Error, Equatable, Sendable {
    case malformedIndex                              // the index JSON didn't decode (bad shape / unknown key)
    case sizeMismatch(expected: Int, actual: Int)    // downloaded blob length != the entry's sizeBytes
    case hashMismatch(expected: String, actual: String)  // SHA-256 of the blob != the entry's sha256
}

extension ThemeCatalogEntry {
    /// Is `id` safe to use as a SINGLE on-disk path segment (the install folder name)? An entry id
    /// flows untrusted into `~/.agent-island/themes/<id>/`, where an id of `..` would make a later
    /// `removeItem` delete the whole themes root, and `a/b` would write outside it. Reject anything
    /// that isn't a plain, single, non-dotted path component: empty, `/`/`\`/NUL, `.`/`..`, or an id
    /// that doesn't survive a round-trip through `lastPathComponent` (i.e. contained a separator).
    /// Pure (no disk) so the App can gate on it BEFORE download and the self-test can assert it.
    public static func isSafeID(_ id: String) -> Bool {
        if id.isEmpty || id == "." || id == ".." { return false }
        if id.contains("/") || id.contains("\\") || id.contains("\u{0}") { return false }
        // A `..` substring is caught above only as the whole string; a component like `a..b` is fine,
        // but `..` as a standalone component (already covered) or any separator (covered) is not.
        // lastPathComponent collapses `foo/` → `foo` and trims trailing slashes, so a mismatch means
        // the id carried a separator we must refuse.
        if (id as NSString).lastPathComponent != id { return false }
        return true
    }

    /// Is `string` an `https` URL? Both the hosted index URL and an entry's download URL must be
    /// https — `file://`/`ftp://`/`http://` are refused so a hostile/typo'd index can't make the app
    /// read a local file or fetch over plaintext. The scheme compare is case-insensitive. Pure (no
    /// network) so the App reuses it and the self-test can assert the rejection set.
    public static func isHTTPSURL(_ string: String) -> Bool {
        URL(string: string)?.scheme?.lowercased() == "https"
    }

    /// Verify a downloaded blob against this entry's integrity claims: byte length first (cheap), then
    /// SHA-256 (lowercase hex). Pure — the App calls this AFTER the body is in hand and BEFORE it
    /// extracts anything, so a tampered/corrupt/truncated download never reaches `ditto`. Returns the
    /// matching reason on failure, `nil` when the blob is exactly what the catalog promised.
    public func verify(_ data: Data) -> ThemeCatalogError? {
        guard data.count == sizeBytes else {
            return .sizeMismatch(expected: sizeBytes, actual: data.count)
        }
        let actual = ThemeCatalogEntry.sha256Hex(data)
        // Case-insensitive compare so an upper/lower-case hex digest in the index still matches.
        guard actual == sha256.lowercased() else {
            return .hashMismatch(expected: sha256.lowercased(), actual: actual)
        }
        return nil
    }

    /// Lowercase-hex SHA-256 of `data`. Used by `verify` and exposed so a test can compute the
    /// expected digest of a fixture without re-implementing the hashing.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
