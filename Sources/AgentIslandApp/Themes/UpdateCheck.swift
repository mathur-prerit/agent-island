import Foundation
import AgentIslandThemes

// App-side network half of the "update available" indicator. Asks GitHub Releases for the latest tag,
// hands the raw bytes to the PURE `ReleaseFeed.parseLatestTag` / `UpdateAvailability.decide` (in
// AgentIslandThemes, so the self-test covers the whole decision with no network), and reports back the
// version to offer. Network is strictly OPTIONAL: it never blocks the UI, and every failure mode
// (offline, rate-limited, non-200, malformed JSON) is a silent `.upToDate` — the indicator only ever
// appears on a successful fetch of a strictly-newer, undismissed release.
//
// Throttling: at most one fetch per day, gated by a UserDefaults timestamp, so a long-running menu-bar
// app doesn't hammer the API (and stays well under GitHub's unauthenticated rate limit). The "don't
// nag" half (a dismissed version staying quiet until something newer ships) lives in the pure decide().

enum UpdateCheck {
    /// The GitHub Releases "latest" endpoint for this repo. One constant so the repo can move without
    /// touching the fetch code (mirrors `ThemeDownloader.catalogURL`).
    static let latestReleaseURL =
        "https://api.github.com/repos/mathur-prerit/agent-island/releases/latest"

    /// Where the user can grab the update for now (the menu action opens this). Swapped for an in-app
    /// self-updater once the install-and-cli backlog lands — see the TODO at the menu action.
    static let releasesPageURL = "https://github.com/mathur-prerit/agent-island/releases/latest"

    /// UserDefaults keys: the last-check timestamp (throttle) and the version the user dismissed (so the
    /// badge only reappears for a strictly-newer release). Namespaced like the existing `island*` keys.
    static let lastCheckKey = "islandUpdateLastCheck"
    static let dismissedVersionKey = "islandUpdateDismissedVersion"

    /// At most one check per day.
    static let minInterval: TimeInterval = 24 * 60 * 60

    /// Run a check now unless we checked within `minInterval` (best-effort throttle via UserDefaults).
    /// Fetches off the given queue and delivers the decision on the MAIN queue. `completion` is only
    /// invoked when there's something to show (`.available`) OR — so the caller can clear a stale badge —
    /// always; we pass the full availability so the caller decides. Skipped (no completion) when throttled.
    static func checkIfDue(installed: String = AppInfo.version,
                           defaults: UserDefaults = .standard,
                           completion: @escaping (UpdateAvailability) -> Void) {
        let now = Date()
        if let last = defaults.object(forKey: lastCheckKey) as? Date,
           now.timeIntervalSince(last) < minInterval {
            return   // checked recently — stay quiet, don't even hit the network
        }
        defaults.set(now, forKey: lastCheckKey)   // stamp BEFORE the fetch so a failure still throttles
        DispatchQueue.global(qos: .utility).async {
            let latest = fetchLatestTag()   // nil on any failure → decide() yields .upToDate
            let dismissed = defaults.string(forKey: dismissedVersionKey)
            let availability = UpdateAvailability.decide(installed: installed, latest: latest, dismissed: dismissed)
            DispatchQueue.main.async { completion(availability) }
        }
    }

    /// Record that the user dismissed an offered version, so the badge stays quiet until something
    /// strictly newer ships (the pure `decide` compares against this).
    static func dismiss(version: String, defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: dismissedVersionKey)
    }

    // MARK: - Networking (Foundation/URLSession)

    /// GET the latest-release JSON and parse its tag. Synchronous (callers run it off the main thread).
    /// Returns nil on offline / non-2xx / rate-limited / malformed-JSON — the caller maps nil to
    /// `.upToDate`, so a failed check is indistinguishable from "already current". GitHub wants a
    /// User-Agent on API requests, so we send one (a missing UA can itself draw a 403).
    static func fetchLatestTag(from urlString: String = latestReleaseURL) -> String? {
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue("agent-island", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        var out: String?
        let sem = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data = data else { return }
            out = ReleaseFeed.parseLatestTag(data)
        }
        task.resume()
        sem.wait()
        return out
    }
}
