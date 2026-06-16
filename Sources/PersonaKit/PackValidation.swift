import Foundation

/// Why a Persona Pack was rejected by the hardened loader.
public enum PackRejection: Equatable, Sendable {
    case pathTraversal(String)     // asset path escapes the pack root (Zip-Slip)
    case disallowedAsset(String)   // asset type not on the allowlist (e.g. SVG)
    case archiveTooLarge
    case uncompressedTooLarge
    case tooManyFiles
    case fileTooLarge
    case compressionBomb
    case unknownSchemaField(String) // a top-level manifest key we don't recognize
    case unknownState(String)       // a slot keyed to a state the core doesn't own
}

/// Pure validation for declarative Persona Packs. Packs contain NO executable code —
/// these checks enforce that the data stays in-bounds and can't escape the pack root,
/// introduce script-bearing assets, or remap which visual slot renders which state.
public enum PackValidator {
    /// Asset types a pack may ship. SVG is intentionally excluded — it can carry script.
    public static let allowedAssetExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "pdf"]

    /// The canonical visual slots — they mirror AgentIslandCore's states. The core owns
    /// this mapping; a pack supplies an asset per slot but cannot invent or remap slots.
    public static let validSlots: Set<String> = ["working", "waitingForInput", "finished"]

    /// Reject any asset path that is absolute, contains "..", uses backslashes/NUL, or
    /// otherwise resolves outside the pack root.
    public static func validateAssetPath(_ path: String) -> PackRejection? {
        if path.hasPrefix("/") { return .pathTraversal(path) }
        if path.contains("..") { return .pathTraversal(path) }
        if path.contains("\\") || path.contains("\u{0}") { return .pathTraversal(path) }
        var depth = 0
        for component in path.split(separator: "/") {
            if component == "." { continue }
            depth += 1
            if depth < 0 { return .pathTraversal(path) }
        }
        return nil
    }

    public static func isAllowedAsset(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return allowedAssetExtensions.contains(ext)
    }

    /// Validate a single asset reference: path safety first, then type allowlist.
    public static func validateAsset(_ filename: String) -> PackRejection? {
        if let pathRejection = validateAssetPath(filename) { return pathRejection }
        if !isAllowedAsset(filename) { return .disallowedAsset(filename) }
        return nil
    }

    /// Enforce size / zip-bomb limits. Call before extraction using the archive's
    /// central-directory metadata where possible.
    public static func checkLimits(archiveBytes: Int,
                                   uncompressedBytes: Int,
                                   fileCount: Int,
                                   largestFileBytes: Int,
                                   limits: PackLimits = .init()) -> PackRejection? {
        if archiveBytes > limits.maxArchiveBytes { return .archiveTooLarge }
        if uncompressedBytes > limits.maxUncompressedBytes { return .uncompressedTooLarge }
        if fileCount > limits.maxFileCount { return .tooManyFiles }
        if largestFileBytes > limits.maxFileBytes { return .fileTooLarge }
        if archiveBytes > 0,
           Double(uncompressedBytes) / Double(archiveBytes) > limits.maxCompressionRatio {
            return .compressionBomb
        }
        return nil
    }

    /// Reject unknown top-level manifest keys (strict schema — keeps packs declarative
    /// and prevents smuggling, e.g. an `exec`/`script` field).
    public static func validateManifestKeys(_ keys: [String]) -> PackRejection? {
        let allowed: Set<String> = ["name", "version", "slots", "copy"]
        for key in keys where !allowed.contains(key) {
            return .unknownSchemaField(key)
        }
        return nil
    }

    /// A pack's slots may only key the core-owned states — it cannot introduce a new
    /// state or remap which slot renders which state.
    public static func validateSlotKeys(_ keys: [String]) -> PackRejection? {
        for key in keys where !validSlots.contains(key) {
            return .unknownState(key)
        }
        return nil
    }
}
