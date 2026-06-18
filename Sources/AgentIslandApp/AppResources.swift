import Foundation

/// Resolves THIS target's SwiftPM resource bundle (`AgentIsland_AgentIslandApp.bundle` — the bundled
/// themes, sounds, images) across every way the app runs. Use `AppResources.bundle` instead of
/// `Bundle.module` for any packaged-app resource lookup.
///
/// Why this exists — a hard conflict between two macOS rules:
///   • SwiftPM's generated `Bundle.module` ONLY looks at `Bundle.main.bundleURL/<name>.bundle` (the .app
///     ROOT, beside Contents/) plus a build-machine path. So in a packaged .app it resolves ONLY when the
///     bundle sits at the .app root.
///   • `codesign` FORBIDS anything at the .app root except `Contents/` — signing an .app with a bundle at
///     the root fails with "unsealed contents present in the bundle root". (Local macOS is lenient; the
///     macos-13/14 release runners are not — this broke the v0.3.4/v0.3.5 release CI.)
///
/// Those two rules can't both be satisfied with the stock accessor, so we resolve the bundle ourselves:
/// prefer the standard, codesign-clean `Contents/Resources/<name>.bundle`; fall back to the .app root (for
/// any legacy/dev layout); and finally to `Bundle.module` so `swift run` and the self-test (which rely on
/// SwiftPM's baked-in `.build/` path) keep working unchanged.
enum AppResources {
    static let bundle: Bundle = {
        let name = "AgentIsland_AgentIslandApp.bundle"
        var candidates: [URL] = []
        // 1. Standard packaged-app location — Contents/Resources (what codesign expects).
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent(name)) }
        // 2. .app root — where SwiftPM's own accessor looks (legacy layout).
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(name))
        for url in candidates {
            if let b = Bundle(url: url) { return b }
        }
        // 3. `swift run` / self-test: SwiftPM's generated accessor (hardcoded .build path).
        return Bundle.module
    }()
}
