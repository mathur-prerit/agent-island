import Foundation
import AgentIslandCLICore
import AgentIslandThemes
import PersonaKit

// The effectful half of `theme list / add / set`. `add` does ONLY the network GET here and hands the
// bytes to the SHARED `ThemeInstaller.installFromLocalZip` — the security-critical verify / zip
// inspection / ditto extraction / post-extraction validation / strict-manifest / atomic-move pipeline
// is reused verbatim, NOT reimplemented. `set` writes the app's `islandTheme` preference. `list`
// gathers rows (built-in + installed-on-disk + catalog) and renders them via the pure renderer.
enum ThemeCommands {
    private static var paths: InstallPaths { InstallPaths(home: HomeDir.path) }
    private static var themesRoot: URL { URL(fileURLWithPath: paths.themesDir, isDirectory: true) }

    /// The ids built into / shipped with the app. The CLI can't introspect the (separate) .app bundle,
    /// so these mirror `Themes.codeThemes` + `ManifestThemeDiscovery.bundledIDs` — kept in lockstep with
    /// the app. (Installed + catalog themes ARE discovered dynamically below.)
    private static let codeThemeIDs: [(id: String, name: String)] =
        [("journey", "Road Runner"), ("minimal", "Minimal")]
    private static let bundledThemeIDs: [(id: String, name: String)] = [("critter", "Pixel Critter")]

    // MARK: - list

    static func list() {
        var rows: [ThemeListing] = []
        var seen = Set<String>()
        for t in codeThemeIDs where seen.insert(t.id).inserted {
            rows.append(ThemeListing(id: t.id, displayName: t.name, source: .code))
        }
        for t in bundledThemeIDs where seen.insert(t.id).inserted {
            rows.append(ThemeListing(id: t.id, displayName: t.name, source: .bundled))
        }
        // Installed (downloaded / hand-dropped) data themes — scan ~/.agent-island/themes/<id>/theme.json.
        for installed in installedThemes() where seen.insert(installed.id).inserted {
            rows.append(ThemeListing(id: installed.id, displayName: installed.displayName, source: .installed))
        }
        // Downloadable catalog entries not already present locally. Offline / no catalog → just skip them.
        if case .success(let catalog) = fetchCatalog() {
            for entry in catalog.themes where seen.insert(entry.id).inserted {
                rows.append(ThemeListing(id: entry.id, displayName: entry.displayName, source: .catalog))
            }
        }
        let active = AppDefaults.stringValue(forKey: "islandTheme")
        out(ThemeListRenderer.render(rows, activeID: active))
    }

    /// Discover installed data themes by reading each `~/.agent-island/themes/<id>/theme.json` through
    /// the SAME strict loader the app uses (so a broken theme is skipped, never shown). Returns id +
    /// displayName.
    private static func installedThemes() -> [(id: String, displayName: String)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: themesRoot,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [(String, String)] = []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let manifestURL = dir.appendingPathComponent("theme.json")
            guard let data = try? Data(contentsOf: manifestURL) else { continue }
            switch ThemeManifestLoader.load(data: data, folderName: dir.lastPathComponent,
                                            appVersion: CLIConstants.version) {
            case .success(let m): out.append((m.id, m.displayName))
            case .failure: continue
            }
        }
        return out
    }

    // MARK: - add

    /// `theme add <id|url>`. Classifies the argument (pure), then:
    ///   - catalog id → fetch the index, find the entry (with its sha256/sizeBytes), download, install.
    ///   - https url  → download the bytes, peek the manifest id, build a self-verifying entry, install.
    /// In BOTH cases the bytes flow into `ThemeInstaller.installFromLocalZip` — all validation/extraction
    /// is the shared pipeline. Returns true on a clean install.
    static func add(_ idOrURL: String) -> Bool {
        guard let target = ThemeAdd.classify(idOrURL) else {
            errOut("agentisland: '\(idOrURL)' isn't a safe theme id or an https url")
            return false
        }
        switch target {
        case .catalogID(let id): return addFromCatalog(id)
        case .directURL(let url): return addFromURL(url)
        }
    }

    private static func addFromCatalog(_ id: String) -> Bool {
        switch fetchCatalog() {
        case .failure(let e):
            errOut("agentisland: couldn't fetch the theme catalog (\(e))")
            return false
        case .success(let catalog):
            guard let entry = catalog.themes.first(where: { $0.id == id }) else {
                errOut("agentisland: no theme '\(id)' in the catalog (run `agentisland theme list`)")
                return false
            }
            guard let data = downloadBody(entry.url) else { return false }
            return runSharedInstall(entry: entry, data: data)
        }
    }

    private static func addFromURL(_ url: String) -> Bool {
        guard let data = downloadBody(url) else { return false }
        // Peek the manifest id from the archive by running the SAME extraction the installer uses, then
        // re-install for real with an entry whose id == that manifest id (the loader enforces id ==
        // folder name). No validation is bypassed: the real install below re-runs every gate.
        guard let id = peekManifestID(zipData: data) else {
            errOut("agentisland: couldn't read a theme.json id from \(url)")
            return false
        }
        guard ThemeCatalogEntry.isSafeID(id) else {
            errOut("agentisland: the theme's id '\(id)' isn't a safe install folder name")
            return false
        }
        let entry = ThemeAdd.selfVerifyingEntry(id: id, url: url, data: data)
        return runSharedInstall(entry: entry, data: data)
    }

    /// Download the zip body (https-only, size-capped). Logs + returns nil on any failure.
    private static func downloadBody(_ url: String) -> Data? {
        switch Net.get(url) {
        case .success(let data): return data
        case .failure(let e):
            errOut("agentisland: download failed (\(e))")
            return nil
        }
    }

    /// Run the SHARED offline install pipeline: write the bytes to a scratch zip and call
    /// `ThemeInstaller.installFromLocalZip` (verify → ZipInspector → ditto → lstat/PackValidator →
    /// strict manifest → atomic move). No validation is duplicated here. Scratch is torn down always.
    private static func runSharedInstall(entry: ThemeCatalogEntry, data: Data) -> Bool {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("agentisland-cli-\(UUID().uuidString)",
                                                                    isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        do { try fm.createDirectory(at: scratch, withIntermediateDirectories: true) }
        catch { errOut("agentisland: couldn't create a scratch dir"); return false }
        let zipURL = scratch.appendingPathComponent("theme.zip")
        do { try data.write(to: zipURL) }
        catch { errOut("agentisland: couldn't stage the download"); return false }

        try? fm.createDirectory(at: themesRoot, withIntermediateDirectories: true)
        switch ThemeInstaller.installFromLocalZip(zipURL, entry: entry, appVersion: CLIConstants.version,
                                                  installRoot: themesRoot, scratch: scratch) {
        case .success(let installedID):
            out("Installed theme '\(installedID)' to \(paths.themesDir)/\(installedID)")
            out("Activate it with: agentisland theme set \(installedID)")
            return true
        case .failure(let e):
            errOut("agentisland: theme install rejected (\(e))")
            return false
        }
    }

    /// Extract a zip to a throwaway temp dir (via the same ditto engine), locate its theme.json, and
    /// read its `id`. Used ONLY to learn the id for a direct-URL add; the subsequent real install
    /// re-runs every security gate, so this peek bypasses nothing. nil on any failure.
    private static func peekManifestID(zipData: Data) -> String? {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("agentisland-peek-\(UUID().uuidString)",
                                                                    isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        // Inspect the central directory BEFORE extracting (decompression-bomb / zip-slip / symlink) —
        // reuse the shared inspector so even this peek can't be turned into an extraction attack.
        if ZipInspector.checkArchive(zipData, archiveBytes: zipData.count, limits: PackLimits()) != nil {
            return nil
        }
        do { try fm.createDirectory(at: scratch, withIntermediateDirectories: true) } catch { return nil }
        let zipURL = scratch.appendingPathComponent("peek.zip")
        guard (try? zipData.write(to: zipURL)) != nil else { return nil }
        let extractDir = scratch.appendingPathComponent("x", isDirectory: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zipURL.path, extractDir.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        // Accept theme.json at the root or one folder deep (the same shapes the installer accepts).
        for candidate in manifestCandidates(extractDir, fm: fm) {
            guard let data = try? Data(contentsOf: candidate),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String else { continue }
            return id
        }
        return nil
    }

    private static func manifestCandidates(_ extractDir: URL, fm: FileManager) -> [URL] {
        var out = [extractDir.appendingPathComponent("theme.json")]
        if let dirs = try? fm.contentsOfDirectory(at: extractDir,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for d in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                out.append(d.appendingPathComponent("theme.json"))
            }
        }
        return out
    }

    // MARK: - set

    /// `theme set <id>`: write the app's `islandTheme` preference. We don't hard-fail on an id that
    /// isn't installed yet (a user may set then add), but we warn so a typo is visible.
    static func set(_ id: String) -> Bool {
        guard ThemeCatalogEntry.isSafeID(id) else {
            errOut("agentisland: '\(id)' isn't a valid theme id")
            return false
        }
        let known = codeThemeIDs.map(\.id) + bundledThemeIDs.map(\.id) + installedThemes().map(\.id)
        if !known.contains(id) {
            errOut("agentisland: note — '\(id)' isn't installed yet; add it with `agentisland theme add \(id)`")
        }
        AppDefaults.write(.string(id), forKey: "islandTheme")
        out("Set active theme to '\(id)'. Restart agent-island to apply.")
        return true
    }

    // MARK: - catalog

    private static func fetchCatalog() -> Result<ThemeCatalog, Net.NetError> {
        switch Net.get(CLIConstants.catalogURL) {
        case .failure(let e): return .failure(e)
        case .success(let data):
            switch ThemeCatalog.decode(data) {
            case .success(let c): return .success(c)
            case .failure: return .failure(.transport)   // malformed index → treat as no catalog
            }
        }
    }
}
