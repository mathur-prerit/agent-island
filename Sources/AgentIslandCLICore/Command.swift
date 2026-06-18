import Foundation

// PURE argument parsing for `agentisland`. `argv[1...]` (the args AFTER the program name) parse into a
// typed `Command`; the executable then performs the effects. Parsing is total — every input yields a
// `Command` (including `.help`/`.unknown`/`.usageError`) rather than throwing — so the self-test can
// assert the whole dispatch table with no process exits. Mirrors the `agentisland-hook` switch-on-argv
// style, just richer (sub-subcommands + flags).

/// The parsed intent of one `agentisland` invocation. The executable matches on this to run the effect.
public enum Command: Equatable {
    case help                                   // no args, or `--help` / `-h` / `help`
    case version                                // `version` / `--version`
    case themeList                              // `theme list` (or bare `theme`)
    case themeAdd(idOrURL: String)              // `theme add <id|url>`
    case themeSet(id: String)                   // `theme set <id>`
    case configList                             // `config` (no args)
    case configGet(key: String)                 // `config get <key>`
    case configSet(key: String, value: String)  // `config set <key> <value>`
    case update                                 // `update`
    case uninstall(yes: Bool, dryRun: Bool, purge: Bool)  // `uninstall [--yes] [--dry-run] [--purge]`
    case startOnBoot(StartOnBootAction)         // `start-on-boot [on|off|status]`
    case daemon(DaemonAction)                   // `daemon [status|stop|restart]`
    case unknown(String)                        // an unrecognized first token
    case usageError(String)                     // a recognized command with the wrong/missing args
}

/// The three start-on-boot verbs. A bare `start-on-boot` defaults to `status` (read-only — never
/// silently toggles the login item).
public enum StartOnBootAction: Equatable {
    case on, off, status
}

/// `daemon` verbs: report status, KILL any (dangling) `agentislandd`, or kill-then-respawn. A bare
/// `daemon` defaults to `status` (read-only — never silently kills).
public enum DaemonAction: Equatable {
    case status, stop, restart
}

public enum CommandParser {
    /// Parse the arguments AFTER the program name (i.e. `CommandLine.arguments.dropFirst()`). Total: any
    /// input maps to a `Command`. Unknown commands → `.unknown`; a known command with bad args →
    /// `.usageError` carrying a one-line reason.
    public static func parse(_ args: [String]) -> Command {
        guard let first = args.first else { return .help }
        let rest = Array(args.dropFirst())

        switch first {
        case "-h", "--help", "help":
            return .help
        case "version", "--version", "-v":
            return .version
        case "theme":
            return parseTheme(rest)
        case "config":
            return parseConfig(rest)
        case "update":
            return rest.isEmpty ? .update : .usageError("update takes no arguments")
        case "uninstall":
            return parseUninstall(rest)
        case "start-on-boot":
            return parseStartOnBoot(rest)
        case "daemon":
            return parseDaemon(rest)
        default:
            return .unknown(first)
        }
    }

    private static func parseTheme(_ args: [String]) -> Command {
        guard let sub = args.first else { return .themeList }   // bare `theme` lists
        let rest = Array(args.dropFirst())
        switch sub {
        case "list":
            return rest.isEmpty ? .themeList : .usageError("theme list takes no arguments")
        case "add":
            guard rest.count == 1 else { return .usageError("usage: agentisland theme add <id|url>") }
            return .themeAdd(idOrURL: rest[0])
        case "set":
            guard rest.count == 1 else { return .usageError("usage: agentisland theme set <id>") }
            return .themeSet(id: rest[0])
        default:
            return .usageError("unknown theme subcommand '\(sub)' (try: list, add, set)")
        }
    }

    private static func parseConfig(_ args: [String]) -> Command {
        guard let sub = args.first else { return .configList }   // bare `config` lists
        let rest = Array(args.dropFirst())
        switch sub {
        case "get":
            guard rest.count == 1 else { return .usageError("usage: agentisland config get <key>") }
            return .configGet(key: rest[0])
        case "set":
            guard rest.count == 2 else { return .usageError("usage: agentisland config set <key> <value>") }
            return .configSet(key: rest[0], value: rest[1])
        default:
            return .usageError("unknown config subcommand '\(sub)' (try: get, set, or no args to list)")
        }
    }

    private static func parseUninstall(_ args: [String]) -> Command {
        var yes = false
        var dryRun = false
        var purge = false
        for a in args {
            switch a {
            case "--yes", "-y": yes = true
            case "--dry-run", "-n": dryRun = true
            case "--purge": purge = true
            default: return .usageError("unknown uninstall flag '\(a)' (try: --yes, --dry-run, --purge)")
            }
        }
        return .uninstall(yes: yes, dryRun: dryRun, purge: purge)
    }

    private static func parseStartOnBoot(_ args: [String]) -> Command {
        guard let verb = args.first else { return .startOnBoot(.status) }   // bare → status (read-only)
        guard args.count == 1 else { return .usageError("usage: agentisland start-on-boot [on|off|status]") }
        switch verb {
        case "on": return .startOnBoot(.on)
        case "off": return .startOnBoot(.off)
        case "status": return .startOnBoot(.status)
        default: return .usageError("unknown start-on-boot verb '\(verb)' (try: on, off, status)")
        }
    }

    private static func parseDaemon(_ args: [String]) -> Command {
        guard let verb = args.first else { return .daemon(.status) }   // bare → status (read-only)
        guard args.count == 1 else { return .usageError("usage: agentisland daemon [status|stop|restart]") }
        switch verb {
        case "status": return .daemon(.status)
        case "stop", "kill", "--stop": return .daemon(.stop)
        case "restart", "--restart": return .daemon(.restart)
        default: return .usageError("unknown daemon verb '\(verb)' (try: status, stop, restart)")
        }
    }
}
