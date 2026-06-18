import Foundation

// PURE help/usage text + the `theme list` rendering model. Text is built here (no printing) so the
// self-test can assert the surface mentions every subcommand, and so the executable's `--help` and
// `config` listing read from one source.

public enum Help {
    /// The full `--help` / usage text. One block listing every subcommand so README and `--help` agree.
    public static var usage: String {
        """
        agentisland — manage your agent-island install (v\(CLIConstants.version))

        USAGE:
          agentisland <command> [args]

        COMMANDS:
          theme list                 List installed + bundled + downloadable themes
          theme add <id|url|path>    Install a theme: a catalog id, an https zip url, or a LOCAL path
                                     (your own theme folder or a .zip on disk)
          theme set <id>             Make <id> the active theme (writes the app's preference)
          config                     List the settable preferences and their current values
          config get <key>           Print one preference's current value
          config set <key> <value>   Set one preference (validated against the allowlist)
          update                     Check for a newer release; offer to update in place
          start-on-boot [on|off|status]  Launch agent-island at login (login item; default: status)
          daemon [status|stop|restart]   Inspect / kill a dangling agentislandd, or kill + respawn it
          uninstall [--yes] [--dry-run] [--purge]  Remove hooks, login item, the app + ~/.agent-island
                                     (KEEPS your custom themes by default; --purge wipes those too)
          version                    Print the CLI version
          help                       Show this help

        Install/upgrade:  \(CLIConstants.installOneLiner)
        """
    }

    /// Render the `config` (no-args) listing from the allowlist + a value lookup. `currentValue`
    /// returns the app's stored value for a key (nil when unset); pure here so the self-test can render
    /// the table from a stub lookup with no real defaults store.
    public static func configListing(currentValue: (String) -> String?) -> String {
        var lines = ["Settable preferences (written into the app's domain — \(CLIConstants.appBundleID)):", ""]
        for k in ConfigKeys.all {
            let value = currentValue(k.key) ?? "(unset)"
            lines.append("  \(k.key) = \(value)")
            lines.append("      \(k.summary)")
        }
        return lines.joined(separator: "\n")
    }
}

/// What `theme list` shows for one theme, regardless of source. Pure data so the listing can be
/// assembled (and asserted) without touching disk or the network.
public struct ThemeListing: Equatable {
    /// Where a theme comes from — drives the label suffix so a user sees what's local vs downloadable.
    public enum Source: String, Equatable {
        case code        // a built-in code theme (always present)
        case bundled     // a data theme shipped inside the .app
        case installed   // a data theme under ~/.agent-island/themes
        case catalog     // a downloadable entry not yet installed
    }
    public let id: String
    public let displayName: String
    public let source: Source

    public init(id: String, displayName: String, source: Source) {
        self.id = id
        self.displayName = displayName
        self.source = source
    }
}

public enum ThemeListRenderer {
    /// Render the theme rows into lines, marking the active id. Catalog entries already installed are
    /// expected to be filtered out by the caller (so a theme shows once, as local). Pure: the executable
    /// gathers the rows + active id from disk/catalog and hands them here.
    public static func render(_ rows: [ThemeListing], activeID: String?) -> String {
        guard !rows.isEmpty else { return "No themes found." }
        var lines: [String] = []
        for r in rows {
            let active = (r.id == activeID) ? " *" : "  "
            let tag: String
            switch r.source {
            case .code: tag = "built-in"
            case .bundled: tag = "bundled"
            case .installed: tag = "installed"
            case .catalog: tag = "downloadable"
            }
            lines.append("\(active) \(r.id) — \(r.displayName)  [\(tag)]")
        }
        lines.append("")
        lines.append("(* = active.  Set with: agentisland theme set <id>.  Add with: agentisland theme add <id|url>.)")
        return lines.joined(separator: "\n")
    }
}
