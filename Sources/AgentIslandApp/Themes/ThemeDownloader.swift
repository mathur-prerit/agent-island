import Foundation
import PersonaKit
import AgentIslandThemes

// App-side runtime theme download (the highest-risk, lowest-immediate-value Tier-4 feature). Fetches
// the hosted catalog, downloads a theme zip, and — treating BOTH as fully untrusted network input —
// validates before trusting at every step, landing a verified theme in `~/.agent-island/themes/<id>/`
// for `ManifestThemeDiscovery` to pick up on the next `Themes.reload()`.
//
// This file owns ONLY the network half (https-only fetch + bounded download); the offline tail —
// integrity verify → central-directory inspection → ditto extract → on-disk validation → atomic move —
// lives in the AppKit-free `AgentIslandThemes.ThemeInstaller` so `AgentIslandSelfTest` can drive the
// whole install pipeline from a LOCAL fixture zip with no network.
//
// Why the validation order is what it is (the whole point of the feature):
//   1. The catalog entry's `id` is gated as a single safe path segment BEFORE anything else — it flows
//      into the install path, so `id=".."` (which would `removeItem` the whole themes root) is refused
//      up front. The catalog decode itself is strict (unknown keys reject the index).
//   2. Both the index URL and the entry URL must be `https` (no `file://`/`ftp://`), and a URLSession
//      delegate refuses any redirect that leaves https.
//   3. The zip is downloaded to a FILE (URLSessionDownloadTask streams to disk), never buffered in
//      memory; the delegate CANCELS the task the instant the bytes written exceed the entry's
//      `sizeBytes`/the archive ceiling — even when the server omits `Content-Length`.
//   4. The rest is `ThemeInstaller.installFromLocalZip` (verify → ZipInspector pre-extraction limits →
//      ditto → post-extraction lstat/PackValidator → strict manifest → direct-child-asserted atomic
//      move). Every temp artifact is cleaned up on every exit path — a failure leaves NO partial install.

/// Why a theme download failed. Typed so the caller can log/no-op without crashing; the pure install
/// reasons (`ThemeInstallError`, itself wrapping catalog + zip-inspection errors) are wrapped so a
/// reviewer can see the full failure surface.
enum ThemeDownloadError: Error, Equatable {
    case badURL(String)                  // an entry's url (or the index url) wasn't https / didn't parse
    case network                         // offline / transport failure / non-2xx response
    case declaredTooLarge(Int)           // Content-Length or sizeBytes exceeds the archive limit (pre-body)
    case appTooOld(required: String)     // entry.minAppVersion > the running app (defensive; menu greys it)
    case install(ThemeInstallError)      // the offline install pipeline rejected the archive (see ThemeInstaller)
}

/// Downloads, validates, and installs a data theme described by a `ThemeCatalogEntry`. Stateless;
/// one method does the whole pipeline. The network half is here; the offline half is `ThemeInstaller`.
enum ThemeDownloader {

    /// Where to fetch the hosted index from. A real URL is wired here (GitHub raw is the planned
    /// host); kept as a single constant so the catalog can move without touching the menu code.
    static let catalogURL = "https://raw.githubusercontent.com/mathur-prerit/agent-island/main/themes-index.json"

    /// The folder downloaded themes land in — the SAME root `ManifestThemeDiscovery` scans, so a
    /// successful install is visible after `Themes.reload()`.
    static let installRoot = ManifestThemeDiscovery.userThemesDir

    /// Hard ceilings reused from the Persona Pack defenses (10 MB archive / 50 MB uncompressed /
    /// 100 files / 5 MB per file / 100× ratio). One source of truth for "how big may a theme be".
    static let limits = PackLimits()

    // MARK: - Catalog

    /// Fetch + strictly decode the hosted index. Network-bound; the decode itself is the pure
    /// `ThemeCatalog.decode`. Synchronous (callers run it off the main thread).
    static func fetchCatalog(from urlString: String = catalogURL) -> Result<ThemeCatalog, ThemeDownloadError> {
        guard let url = httpsURL(urlString) else { return .failure(.badURL(urlString)) }
        let result = fetchData(url)
        switch result {
        case .failure(let e): return .failure(e)
        case .success(let data):
            switch ThemeCatalog.decode(data) {
            case .success(let catalog): return .success(catalog)
            case .failure(let e): return .failure(.install(.integrity(e)))   // surface a malformed index
            }
        }
    }

    // MARK: - Download + install one theme

    /// The full pipeline for one catalog entry: gate id/url → download → (ThemeInstaller) verify →
    /// inspect → extract → validate → atomic-move. Returns the installed theme id on success. On ANY
    /// failure no partial install is left behind. Synchronous; run off the main thread.
    static func install(_ entry: ThemeCatalogEntry,
                        appVersion: String = AppInfo.version) -> Result<String, ThemeDownloadError> {
        // The id flows into the install path (`<root>/<id>/`); refuse anything but a single safe path
        // segment BEFORE we download a byte — an id of `..` would later `removeItem` the themes root.
        guard ThemeCatalogEntry.isSafeID(entry.id) else { return .failure(.install(.unsafeID(entry.id))) }
        // Defensive gate (the menu already greys these out): never download a theme this app is too
        // old to load — reuses the same SemVer comparison the manifest loader uses for minAppVersion.
        guard SemVer.isAtLeast(appVersion, entry.minAppVersion) else {
            return .failure(.appTooOld(required: entry.minAppVersion ?? ""))
        }
        guard let url = httpsURL(entry.url) else { return .failure(.badURL(entry.url)) }
        // Bound the declared size BEFORE fetching the body — a hostile index can't make us pull 5 GB.
        guard entry.sizeBytes >= 0, entry.sizeBytes <= limits.maxArchiveBytes else {
            return .failure(.declaredTooLarge(entry.sizeBytes))
        }

        let fm = FileManager.default
        // One scratch dir per attempt; torn down on every exit path so nothing partial survives.
        let scratch = fm.temporaryDirectory.appendingPathComponent("agent-island-theme-\(UUID().uuidString)",
                                                                    isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        do { try fm.createDirectory(at: scratch, withIntermediateDirectories: true) }
        catch { return .failure(.install(.ioError)) }

        // 1. Download to a FILE (no unbounded in-memory body); the download delegate cancels the task
        //    the instant the delivered bytes exceed the entry's sizeBytes / the archive ceiling, so a
        //    server that omits Content-Length (or lies) still can't stream gigabytes to disk.
        let zipURL = scratch.appendingPathComponent("theme.zip")
        switch downloadToFile(url, to: zipURL, maxBytes: entry.sizeBytes) {
        case .failure(let e): return .failure(e)
        case .success: break
        }

        // 2. Hand off to the offline pipeline (verify → inspect → extract → validate → atomic move).
        switch ThemeInstaller.installFromLocalZip(zipURL, entry: entry, appVersion: appVersion,
                                                  installRoot: installRoot, scratch: scratch,
                                                  limits: limits, fm: fm) {
        case .success(let id): return .success(id)
        case .failure(let e): return .failure(.install(e))
        }
    }

    // MARK: - Networking (Foundation/URLSession)

    /// Parse `string` only if it's an `https` URL — `file://`/`ftp://`/anything else is refused (both
    /// the index URL and the entry URL flow through here). Returns nil for a non-https or unparseable URL.
    static func httpsURL(_ string: String) -> URL? {
        guard ThemeCatalogEntry.isHTTPSURL(string), let url = URL(string: string) else { return nil }
        return url
    }

    /// A `URLSession` that refuses any redirect leaving https (so a 30x to `file://`/`http://` can't
    /// downgrade us). Shared across catalog fetches; the delegate is stateless w.r.t. redirects.
    private static let httpsOnlySession: URLSession = {
        URLSession(configuration: .ephemeral, delegate: HTTPSRedirectGuard(), delegateQueue: nil)
    }()

    /// GET a small resource (the index) fully into memory. Bounded by the index being tiny JSON; a
    /// runaway index is still capped by URLSession's own behavior + the strict decode rejecting junk.
    private static func fetchData(_ url: URL) -> Result<Data, ThemeDownloadError> {
        var out: Result<Data, ThemeDownloadError> = .failure(.network)
        let sem = DispatchSemaphore(value: 0)
        let task = httpsOnlySession.dataTask(with: url) { data, response, error in
            defer { sem.signal() }
            if error != nil { out = .failure(.network); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data = data else { out = .failure(.network); return }
            out = .success(data)
        }
        task.resume()
        sem.wait()
        return out
    }

    /// Download `url` to `dest`, refusing anything larger than `maxBytes`. Uses a download task with a
    /// delegate that CANCELS the transfer the moment the bytes written exceed `maxBytes` (or the global
    /// archive ceiling) — so an absent/lying `Content-Length` can't stream an unbounded body to disk.
    /// A final size re-check guards the case where everything fit under the cap.
    private static func downloadToFile(_ url: URL, to dest: URL, maxBytes: Int) -> Result<Void, ThemeDownloadError> {
        var out: Result<Void, ThemeDownloadError> = .failure(.network)
        let sem = DispatchSemaphore(value: 0)
        let fm = FileManager.default
        // Cap the live transfer at the smaller of the entry's declared size and the global ceiling.
        let cap = min(maxBytes, limits.maxArchiveBytes)
        let delegate = BoundedDownloadDelegate(maxBytes: cap)
        // A per-download session so the delegate's per-task state isn't shared; still https-redirect-safe.
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: url) { tempURL, response, error in
            defer { sem.signal() }
            // The delegate cancels the task when the body exceeds the cap → surfaces as an error here.
            if delegate.exceeded { out = .failure(.declaredTooLarge(cap + 1)); return }
            if error != nil { out = .failure(.network); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let tempURL = tempURL else { out = .failure(.network); return }
            // Re-check the delivered file's actual size (defence atop the streaming cap).
            let size = (try? fm.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? nil
            if let size = size, size > cap { out = .failure(.declaredTooLarge(size)); return }
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: tempURL, to: dest)
                out = .success(())
            } catch {
                out = .failure(.install(.ioError))
            }
        }
        task.resume()
        sem.wait()
        return out
    }
}

// MARK: - URLSession delegates (the size/redirect guards)

/// Refuses any redirect whose destination isn't https — a 30x to `http://`/`file://` can't downgrade
/// the transfer. Returning nil to the completion handler cancels the redirect (the task fails).
private final class HTTPSRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else { completionHandler(nil); return }
        completionHandler(request)
    }
}

/// Cancels a download task the moment the bytes written exceed `maxBytes` — the defense against an
/// unbounded body when `Content-Length` is absent/lying. Also refuses non-https redirects (download
/// tasks need their own delegate). `exceeded` is read after completion to map the cancel to a typed
/// "too large" error. Single-task use (a fresh session per download), so the flag needs no locking.
private final class BoundedDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let maxBytes: Int
    private(set) var exceeded = false

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Int64(maxBytes) {
            exceeded = true
            downloadTask.cancel()
        }
    }

    // Required by the protocol; the completion-handler form on the task carries the result, so this
    // is a no-op (the temp file is consumed there).
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else { completionHandler(nil); return }
        completionHandler(request)
    }
}
