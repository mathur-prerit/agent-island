import Foundation
import ServiceManagement

// The login-item (start-on-boot) seam, via `SMAppService` (macOS 13+). agent-island has NO LaunchAgent
// today — the daemon is APP-spawned as a sibling binary (see EventDrivenSetup), so "start on boot" means
// registering the .APP itself as a login item; the daemon then follows the app on launch.
//
// HONEST SCOPE / SAFETY: `SMAppService.mainApp` registers the *currently running* main app bundle as a
// login item — it's meant to be called from INSIDE the .app (a `.app`-bundled, signed/identified
// process). Called from this standalone CLI binary (which has no main-app bundle), registration won't
// reliably create the right login item. So:
//   - `status` reports the SMAppService status when meaningful, else explains the limitation.
//   - `register`/`unregister` attempt the SMAppService call (a real no-op-safe API) but, because the CLI
//     isn't the app bundle, we ALSO print the reliable manual path (Login Items) so the user is never
//     left thinking it worked when it didn't.
// During development this is never exercised against the real login-item DB (the self-test covers only
// the pure command parsing); these effectful calls are for live, by-eye verification.
enum LoginItem {
    /// `SMAppService.mainApp` — the app-as-login-item service. (Registering THIS from the CLI process
    /// targets the CLI's own (bundle-less) identity, hence the caveats above.)
    private static var service: SMAppService { .mainApp }

    /// Human-readable current status.
    static func statusDescription() -> String {
        switch service.status {
        case .enabled: return "enabled (launches at login)"
        case .notRegistered: return "not registered (won't launch at login)"
        case .requiresApproval: return "requires approval in System Settings ▸ General ▸ Login Items"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    /// Attempt to register the app as a login item. Returns true on a clean register. Because the CLI is
    /// not the app bundle, this is best-effort — the caller also prints the manual fallback.
    static func register() -> Bool {
        do { try service.register(); return true }
        catch { FileHandle.standardError.write(Data("  note: SMAppService.register failed: \(error)\n".utf8)); return false }
    }

    /// Attempt to unregister the login item. Only an ENABLED item can (and should) be unregistered; any
    /// other state — .notRegistered, .notFound, .requiresApproval — means there's nothing for us to
    /// remove, so it's a quiet success (idempotent uninstall). From the bundle-less CLI,
    /// `SMAppService.mainApp` usually can't act on the APP's login item and throws "Operation not
    /// permitted"; that's not a failure of the uninstall — the app's own "Launch at login" toggle (or
    /// System Settings ▸ Login Items) is the reliable control. So we never fail the uninstall over it.
    static func unregister() -> Bool {
        guard service.status == .enabled else { return true }
        do { try service.unregister(); return true }
        catch {
            FileHandle.standardError.write(Data(
                ("  note: couldn't remove the login item from the CLI — if agent-island still shows under "
                 + "System Settings ▸ General ▸ Login Items, switch it off there.\n").utf8))
            return true
        }
    }
}
