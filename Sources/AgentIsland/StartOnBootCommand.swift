import Foundation
import AgentIslandCLICore
import HookInstall   // HomeDir (shared $HOME resolver)

// `agentisland start-on-boot [on|off|status]`. Drives the `SMAppService` login item via `LoginItem`.
// `status` is read-only (the default for a bare invocation, so the command never silently toggles).
// Because the CLI binary isn't the app bundle, on/off also print the reliable manual fallback so the
// user is never misled about whether it took effect (see LoginItem's scope note).
enum StartOnBootCommand {
    static func run(_ action: StartOnBootAction) -> Bool {
        switch action {
        case .status:
            out("start-on-boot: \(LoginItem.statusDescription())")
            return true
        case .on:
            let ok = LoginItem.register()
            out(ok ? "start-on-boot enabled (\(LoginItem.statusDescription()))."
                   : "Couldn't enable start-on-boot automatically.")
            out("If it didn't take effect, add it manually: System Settings ▸ General ▸ Login Items ▸ + ▸ \(InstallPaths(home: HomeDir.path).appPath)")
            return ok
        case .off:
            let ok = LoginItem.unregister()
            out(ok ? "start-on-boot disabled (\(LoginItem.statusDescription()))."
                   : "Couldn't disable start-on-boot automatically.")
            out("You can also remove it manually under System Settings ▸ General ▸ Login Items.")
            return ok
        }
    }
}
