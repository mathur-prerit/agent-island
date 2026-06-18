import Foundation
import AgentIslandCLICore

// The user-facing management CLI: `agentisland <command>`. Pure parsing + the config allowlist +
// the uninstall plan + the theme-add classification all live in `AgentIslandCLICore` (covered by
// AgentIslandSelfTest with no real FS/network); THIS executable performs the effects — filesystem,
// URLSession, CFPreferences (the app's defaults domain), SMAppService (the login item), and Process
// (re-running the installer for `update`). Dispatch mirrors `agentisland-hook`'s switch-on-argv style.
//
// SAFETY: every destructive path (uninstall) is path-injectable and confirmation-gated; `--dry-run`
// performs nothing. Defaults to the real `$HOME`, but the executor below tolerates already-absent
// targets so a partial install uninstalls cleanly.

func out(_ s: String) { print(s) }
func errOut(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let command = CommandParser.parse(Array(CommandLine.arguments.dropFirst()))

switch command {
case .help:
    out(Help.usage)

case .version:
    out("agentisland \(CLIConstants.version)")

case .themeList:
    ThemeCommands.list()

case .themeAdd(let idOrURL):
    exit(ThemeCommands.add(idOrURL) ? 0 : 1)

case .themeSet(let id):
    exit(ThemeCommands.set(id) ? 0 : 1)

case .configList:
    out(Help.configListing(currentValue: AppDefaults.stringValue(forKey:)))

case .configGet(let key):
    exit(ConfigCommands.get(key) ? 0 : 1)

case .configSet(let key, let value):
    exit(ConfigCommands.set(key: key, value: value) ? 0 : 1)

case .update:
    exit(UpdateCommand.run() ? 0 : 1)

case .uninstall(let yes, let dryRun, let purge):
    exit(UninstallCommand.run(yes: yes, dryRun: dryRun, purge: purge) ? 0 : 1)

case .startOnBoot(let action):
    exit(StartOnBootCommand.run(action) ? 0 : 1)

case .daemon(let action):
    exit(DaemonCommand.run(action) ? 0 : 1)

case .unknown(let token):
    errOut("agentisland: unknown command '\(token)'")
    errOut("")
    errOut(Help.usage)
    exit(1)

case .usageError(let reason):
    errOut("agentisland: \(reason)")
    exit(2)
}
