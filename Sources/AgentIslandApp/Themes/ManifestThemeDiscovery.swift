import AppKit
import Foundation
import AgentIslandThemes

// Discovers + loads DATA themes from two roots and turns each into a `ManifestTheme`:
//   1. the app bundle  — themes shipped with the app (folders copied via `.copy("Themes/<id>")`)
//   2. `~/.agent-island/themes/<id>/` — downloaded or hand-dropped themes (the theme-download target)
// Every manifest passes through the strict, path-safe loader; a rejected/unreadable folder is
// skipped (and logged), never fatal — a single broken data theme must not take down the code themes.

/// The running app's version — used both for `minAppVersion` theme gating and the "update available"
/// indicator (compared against the latest GitHub release). A packaged `.app` reports its real value:
/// `Scripts/build-app.sh` stamps `CFBundleShortVersionString` from its `VERSION` constant (the single
/// source of truth). The `"0.3.0"` fallback is what a bare `swift run AgentIslandApp` (no bundle plist)
/// reports — keep it in lockstep with that `VERSION`.
enum AppInfo {
    static let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.4.1"
}

enum ManifestThemeDiscovery {
    /// Bundled data-theme folder names. `.copy("Themes/<id>")` lands each folder at the bundle root,
    /// so we resolve `theme.json` by folder name (the same pattern Road Runner's sounds use). The
    /// folder name MUST equal the theme id (the loader enforces it).
    static let bundledIDs = ["critter"]

    static let userThemesDir = URL(fileURLWithPath:
        ("~/.agent-island/themes" as NSString).expandingTildeInPath, isDirectory: true)

    /// All discovered data themes, bundled first then user-dir, with ids in `reserved` (the code
    /// themes) dropped so a data theme can never shadow a built-in. First occurrence of a duplicate
    /// folder id wins.
    static func discoverAll(excludingIDs reserved: Set<String>) -> [IslandTheme] {
        var seen = reserved
        var out: [IslandTheme] = []
        for theme in bundled() + user() where !seen.contains(theme.id) {
            seen.insert(theme.id)
            out.append(theme)
        }
        return out
    }

    private static func bundled() -> [ManifestTheme] {
        bundledIDs.compactMap { id in
            // nil-guard: a missing bundled folder simply yields no theme (code themes unaffected).
            guard let jsonURL = AppResources.bundle.url(forResource: "theme", withExtension: "json", subdirectory: id)
            else { return nil }
            return loadTheme(jsonURL: jsonURL, folderName: id)
        }
    }

    private static func user() -> [ManifestTheme] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: userThemesDir,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { dir in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let jsonURL = dir.appendingPathComponent("theme.json")
            guard fm.fileExists(atPath: jsonURL.path) else { return nil }
            return loadTheme(jsonURL: jsonURL, folderName: dir.lastPathComponent)
        }
    }

    private static func loadTheme(jsonURL: URL, folderName: String) -> ManifestTheme? {
        guard let data = try? Data(contentsOf: jsonURL) else { return nil }
        switch ThemeManifestLoader.load(data: data, folderName: folderName, appVersion: AppInfo.version) {
        case .success(let manifest):
            return ManifestTheme(manifest: manifest, baseURL: jsonURL.deletingLastPathComponent())
        case .failure(let reason):
            FileHandle.standardError.write(Data("agent-island: skipping theme '\(folderName)': \(reason)\n".utf8))
            return nil
        }
    }
}
