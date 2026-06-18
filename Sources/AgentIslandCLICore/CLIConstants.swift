import Foundation

// PURE constants + paths shared across the `agentisland` management CLI. Lives in this AppKit-free,
// network-free, side-effect-free library (NOT the executable) so `AgentIslandSelfTest` can cover the
// parsing/allowlist/plan logic with no real filesystem, network, or login-item touched. The thin
// `agentisland` executable wires these to URLSession / FileManager / SMAppService / CFPreferences.

public enum CLIConstants {
    /// The CLI version — the single source of truth for `agentisland version`. Kept in lockstep with
    /// `Scripts/build-app.sh`'s `VERSION` and the `AppInfo.version` fallback (they all ship together).
    public static let version = "0.3.0"

    /// The app's preferences domain — the bundle id stamped into `Info.plist` by `build-app.sh`. The
    /// `config` subcommand reads/writes the APP's defaults (via this suite), NOT the CLI's own domain,
    /// so `agentisland config set islandTheme x` changes what the running app reads. One source of truth.
    public static let appBundleID = "com.mathur-prerit.agentisland"

    /// GitHub coordinates — mirror `UpdateCheck` / `ThemeDownloader` so the CLI and app agree on the repo.
    public static let releasesLatestAPI =
        "https://api.github.com/repos/mathur-prerit/agent-island/releases/latest"
    public static let releasesPageURL =
        "https://github.com/mathur-prerit/agent-island/releases/latest"
    public static let installOneLiner =
        "curl -fsSL https://raw.githubusercontent.com/mathur-prerit/agent-island/main/install.sh | sh"

    /// The hosted theme catalog index — mirrors `ThemeDownloader.catalogURL` so `theme list`/`theme add`
    /// resolve the same entries the app's menu does.
    public static let catalogURL =
        "https://raw.githubusercontent.com/mathur-prerit/agent-island/main/themes-index.json"
}

/// The set of on-disk locations a full install touches — bundled into one struct so both the installer
/// and `uninstall` reason about the SAME paths, and so the uninstall plan is path-injectable (tests
/// point `home` at a temp dir; nothing real is touched). Every path derives from `home`, so a sandboxed
/// `home` keeps the whole plan inside the sandbox.
public struct InstallPaths: Equatable {
    public let home: String
    /// `~/.agent-island` — daemon socket, state.json, and downloaded themes.
    public var agentIslandDir: String { home + "/.agent-island" }
    /// `~/.claude/settings.json` — where the lifecycle hooks are wired (reversed via SettingsFile).
    public var settingsPath: String { home + "/.claude/settings.json" }
    /// `~/.agent-island/themes` — the downloaded-theme install root.
    public var themesDir: String { agentIslandDir + "/themes" }
    /// Where the bundled `.app` lives once installed.
    public var appPath: String
    /// The directory the `agentisland` + `agentisland-hook` binaries are copied to (on PATH).
    public var binDir: String

    /// The default PATH dir the installer uses, by CPU arch — matches `install.sh`'s `BIN_DIR` default
    /// so `uninstall` removes the binaries from the SAME place they were installed. On Apple Silicon
    /// /usr/local/bin isn't on PATH (nor writable without sudo); Homebrew's /opt/homebrew/bin is. Compiled
    /// per-arch, so `#if arch` reflects the running CPU. (The app's `locateManagementCLI` searches both.)
    public static var defaultBinDir: String {
        #if arch(arm64)
        return "/opt/homebrew/bin"
        #else
        return "/usr/local/bin"
        #endif
    }

    public init(home: String,
                appPath: String = "/Applications/AgentIsland.app",
                binDir: String = InstallPaths.defaultBinDir) {
        self.home = home
        self.appPath = appPath
        self.binDir = binDir
    }

    /// The two CLI binaries the installer drops on PATH (removed on uninstall).
    public var binaryPaths: [String] { [binDir + "/agentisland", binDir + "/agentisland-hook"] }
}
