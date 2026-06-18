import Foundation
import PersonaKit

// The OFFLINE tail of the theme-download pipeline: everything from "we have a downloaded zip on disk"
// through "a verified theme dir sits at its final home". Lives in this AppKit-free target (uses only
// Foundation — `FileManager`, `Process`/`ditto`; NO AppKit, NO URLSession) so `AgentIslandSelfTest`
// can drive the WHOLE install path from a LOCAL fixture zip with no network — the regression proof
// that a benign theme actually installs end-to-end (and that a hostile one is rejected) rather than
// merely compiling. The App-side `ThemeDownloader` owns the network half and delegates here once the
// bytes are on disk.
//
// Order (each step is a security gate; a failure leaves NO partial install — the caller cleans the
// scratch dir): id is a safe single path segment → size+sha verify → central-directory inspection
// (decompression-bomb / zip-slip / symlink, PRE-extraction) → ditto extract into an isolated temp →
// post-extraction lstat symlink reject + PackValidator path/limit walk → strict manifest load →
// direct-child-asserted atomic move into place.

/// Why the offline install pipeline rejected an archive. Pure (Foundation-only) so the self-test can
/// assert each path; the App-side downloader wraps these (plus its network errors) for the menu.
public enum ThemeInstallError: Error, Equatable, Sendable {
    case unsafeID(String)                // entry.id isn't a single safe path segment (would escape install root)
    case integrity(ThemeCatalogError)    // size/sha mismatch on the downloaded blob
    case zip(ZipInspectionError)         // central-directory inspection tripped a limit / path / symlink check
    case extractionFailed                // ditto returned non-zero (corrupt/non-zip archive)
    case missingManifest                 // no theme.json in the extracted archive
    case symlinkInArchive(String)        // an extracted entry is a symlink (post-extraction lstat reject)
    case packLimit(PackRejection)        // an extracted dir tripped a PackValidator limit / path check
    case invalidManifest(ThemeRejection) // the extracted theme.json failed the strict loader
    case ioError                         // a filesystem move/cleanup step failed
}

public enum ThemeInstaller {

    /// Install a theme from a LOCAL zip already on disk. `zipURL` is the downloaded archive; `entry` is
    /// its (untrusted) catalog row; `installRoot` is `~/.agent-island/themes`; `scratch` is the
    /// per-attempt temp dir extraction lands under (the caller owns its cleanup). Returns the installed
    /// id on success. Network-free; the self-test calls this directly with a fixture zip.
    public static func installFromLocalZip(_ zipURL: URL,
                                           entry: ThemeCatalogEntry,
                                           appVersion: String,
                                           installRoot: URL,
                                           scratch: URL,
                                           limits: PackLimits = .init(),
                                           fm: FileManager = .default) -> Result<String, ThemeInstallError> {
        // The id flows into the install path (`<root>/<id>/`); refuse anything but a single safe path
        // segment — an id of `..` would later `removeItem` the whole themes root.
        guard ThemeCatalogEntry.isSafeID(entry.id) else { return .failure(.unsafeID(entry.id)) }

        // 1. Verify size + sha256 on the bytes BEFORE extracting (the integrity gate).
        guard let zipData = try? Data(contentsOf: zipURL) else { return .failure(.ioError) }
        if let mismatch = entry.verify(zipData) { return .failure(.integrity(mismatch)) }

        // 2. Inspect the zip CENTRAL DIRECTORY before extraction and enforce the pack limits + reject
        //    absolute/`..`/symlink entries. THIS is the decompression-bomb defense — `ditto` (step 3)
        //    only runs once a small archive is proven not to inflate to gigabytes (or drop a symlink).
        if let inspection = ZipInspector.checkArchive(zipData, archiveBytes: zipData.count, limits: limits) {
            return .failure(.zip(inspection))
        }

        // 3. Extract into an ISOLATED temp dir via ditto. ditto sanitizes `..`, and extracting under
        //    `scratch` means even a hostile entry can't escape into a real location.
        let extractDir = scratch.appendingPathComponent("extracted", isDirectory: true)
        guard runDitto(zip: zipURL, into: extractDir) else { return .failure(.extractionFailed) }
        guard let themeRoot = locateThemeRoot(extractDir, fm: fm) else { return .failure(.missingManifest) }

        // 4. PackValidator on the EXTRACTED dir: lstat symlink reject + per-entry zip-slip + aggregate
        //    limits (defense-in-depth atop the pre-extraction inspection).
        if let failure = validateExtractedDir(themeRoot, archiveBytes: zipData.count, limits: limits, fm: fm) {
            return .failure(failure)
        }

        // 5. Strict manifest validation (the security boundary for what the theme renders). The id must
        //    equal the install folder name, so validate against the catalog entry's id.
        let manifestURL = themeRoot.appendingPathComponent("theme.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else { return .failure(.missingManifest) }
        switch ThemeManifestLoader.load(data: manifestData, folderName: entry.id, appVersion: appVersion) {
        case .failure(let r): return .failure(.invalidManifest(r))
        case .success: break
        }

        // 6. Atomic-move into place, asserting the destination is a DIRECT child of the install root
        //    before any removeItem/moveItem (belt-and-suspenders even though isSafeID gated the id).
        do {
            try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
            let dest = installRoot.appendingPathComponent(entry.id, isDirectory: true)
            guard isDirectChild(dest, of: installRoot) else { return .failure(.unsafeID(entry.id)) }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: themeRoot, to: dest)
        } catch {
            return .failure(.ioError)
        }
        return .success(entry.id)
    }

    /// True iff `candidate` resolves to a direct child of `root` (same parent, one component deeper).
    /// Both sides are standardized first so `/var` vs `/private/var` and any `.`/`..` in the path
    /// can't fool the comparison.
    public static func isDirectChild(_ candidate: URL, of root: URL) -> Bool {
        let parent = candidate.standardizedFileURL.deletingLastPathComponent().standardizedFileURL
        return parent.path == root.standardizedFileURL.path && !candidate.lastPathComponent.isEmpty
    }

    // MARK: - Extraction + on-disk validation

    /// Extract `zip` into `dest` via `/usr/bin/ditto -x -k` (Archive Utility's engine — no third-party
    /// dep, sandbox-friendly, and it refuses path-traversal entries). Returns true iff ditto succeeds.
    private static func runDitto(zip: URL, into dest: URL) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zip.path, dest.path]   // -x extract, -k treat src as a PKZip archive
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    /// Find the directory that actually holds `theme.json` within an extracted archive. A theme may be
    /// zipped flat (`theme.json` at the root) or wrapped in one folder (`<id>/theme.json`); accept the
    /// extract root if it has the manifest, else the alphabetically-first sub-directory that does (a
    /// deterministic tie-break — `contentsOfDirectory` order isn't guaranteed). Anything more ambiguous
    /// is "no manifest".
    private static func locateThemeRoot(_ extractDir: URL, fm: FileManager) -> URL? {
        if fm.fileExists(atPath: extractDir.appendingPathComponent("theme.json").path) { return extractDir }
        guard let entries = try? fm.contentsOfDirectory(at: extractDir,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        let dirs = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }   // deterministic tie-break
        for dir in dirs where fm.fileExists(atPath: dir.appendingPathComponent("theme.json").path) {
            return dir
        }
        return nil
    }

    /// Walk an extracted theme dir and validate it: any symlink entry REJECTS the install (lstat-based
    /// via the symlink resource value, so a symlink is detected even though the enumerator's
    /// `isRegularFile` would silently skip it), every regular file's path (relative to the theme root)
    /// is checked for zip-slip via `validateAssetPath`, and the aggregate counts feed `checkLimits`.
    /// The relative path is derived by standardizing BOTH the root and each entry (resolving
    /// `/var`→`/private/var`) so the prefix actually matches — without this the relative-path diff fails
    /// and EVERY theme is wrongly rejected. Defense-in-depth atop the pre-extraction `ZipInspector`.
    private static func validateExtractedDir(_ root: URL, archiveBytes: Int,
                                             limits: PackLimits, fm: FileManager) -> ThemeInstallError? {
        let stdRoot = root.resolvingSymlinksInPath().standardizedFileURL
        // Enumerate WITHOUT resolving symlinks (we want to SEE a symlink, not follow it).
        guard let walker = fm.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]) else { return nil }
        var fileCount = 0
        var totalBytes = 0
        var largest = 0
        for case let fileURL as URL in walker {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            // A symlink anywhere in the extracted tree is never legitimate — reject the whole install.
            // Use the leaf name for the label (never resolve the link — its target may escape the root).
            if values?.isSymbolicLink == true {
                return .symlinkInArchive(fileURL.lastPathComponent)
            }
            guard values?.isRegularFile == true else { continue }   // count files, not directories
            let rel = relativePath(of: fileURL, under: stdRoot)
            if let pathRejection = PackValidator.validateAssetPath(rel) { return .packLimit(pathRejection) }
            fileCount += 1
            let size = values?.fileSize ?? 0
            totalBytes += size
            largest = max(largest, size)
        }
        if let rejection = PackValidator.checkLimits(archiveBytes: archiveBytes,
                                                     uncompressedBytes: totalBytes,
                                                     fileCount: fileCount,
                                                     largestFileBytes: largest,
                                                     limits: limits) {
            return .packLimit(rejection)
        }
        return nil
    }

    /// The path of `fileURL` relative to `stdRoot` (e.g. "images/x.png") — what a manifest asset ref
    /// looks like. Both sides are standardized so the `/var` vs `/private/var` mismatch can't leave the
    /// prefix unmatched (the bug that made every theme's path read as absolute and get rejected). Falls
    /// back to the last component if (impossibly) the entry isn't under the root.
    private static func relativePath(of fileURL: URL, under stdRoot: URL) -> String {
        // Standardize the entry the SAME way the root was (resolve symlinks in the path so the
        // `/var`→`/private/var` prefix matches), then component-diff against the root.
        let stdEntry = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootComps = stdRoot.pathComponents
        let entryComps = stdEntry.pathComponents
        guard entryComps.count > rootComps.count, Array(entryComps.prefix(rootComps.count)) == rootComps else {
            return fileURL.lastPathComponent
        }
        return entryComps.dropFirst(rootComps.count).joined(separator: "/")
    }
}
