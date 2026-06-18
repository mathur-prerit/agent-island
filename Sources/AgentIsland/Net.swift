import Foundation
import AgentIslandThemes

// Thin, https-only Foundation networking for the CLI — the GET half of `theme add` / `update`. It does
// NOT reimplement any theme validation/extraction (that's the shared `ThemeInstaller`); it only fetches
// bytes. https-only (refusing a plaintext/redirect downgrade), with a hard byte ceiling so a hostile or
// runaway response can't buffer unbounded memory before the shared installer's integrity checks run.
enum Net {
    /// 10 MB — the same archive ceiling the Persona Pack defenses use (`PackLimits.maxArchiveBytes`),
    /// applied here as a transfer cap so a download is bounded even before the installer inspects it.
    static let maxBytes = 10 * 1024 * 1024

    enum NetError: Error { case badURL, transport, httpStatus(Int), tooLarge }

    /// GET `urlString` (must be https) fully into memory, refusing anything past `cap` bytes. Synchronous
    /// (the CLI is a one-shot process, so a blocking fetch is fine). A non-https URL, transport failure,
    /// non-2xx status, or oversize body is a typed error the caller surfaces.
    static func get(_ urlString: String, cap: Int = maxBytes) -> Result<Data, NetError> {
        guard ThemeCatalogEntry.isHTTPSURL(urlString), let url = URL(string: urlString) else {
            return .failure(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("agent-island-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        var result: Result<Data, NetError> = .failure(.transport)
        let sem = DispatchSemaphore(value: 0)
        // Ephemeral + a redirect guard that refuses any hop leaving https (no plaintext downgrade).
        let session = URLSession(configuration: .ephemeral, delegate: HTTPSOnlyRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if error != nil { result = .failure(.transport); return }
            guard let http = response as? HTTPURLResponse else { result = .failure(.transport); return }
            guard (200..<300).contains(http.statusCode) else {
                result = .failure(.httpStatus(http.statusCode)); return
            }
            guard let data = data else { result = .failure(.transport); return }
            guard data.count <= cap else { result = .failure(.tooLarge); return }
            result = .success(data)
        }
        task.resume()
        sem.wait()
        return result
    }
}

/// Refuses any redirect whose destination isn't https — a 30x to `http://`/`file://` can't downgrade
/// the transfer (mirrors the app's `HTTPSRedirectGuard`).
private final class HTTPSOnlyRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else { completionHandler(nil); return }
        completionHandler(request)
    }
}
