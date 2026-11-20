import Foundation

/// Remote sources and app downloads use HTTPS, including every redirect, unless the user turns on Allow HTTP.
enum DownloadPolicy {
    static let allowHTTPKey = "allowHTTP"
    static var httpAllowed: Bool { UserDefaults.standard.bool(forKey: allowHTTPKey) }

    static func allows(_ url: URL, http: Bool = httpAllowed) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "https" || (http && scheme == "http")) && url.host?.isEmpty == false
            && url.user == nil && url.password == nil
    }

    /// The URL to fetch. Saved http links are kept as they are, so turning on Allow HTTP restores them;
    /// with it off they're tried over https instead.
    static func resolved(_ url: URL, http: Bool = httpAllowed) -> URL {
        http ? url : upgraded(url)
    }

    /// The URL to load for display (source artwork, news images, screenshots): resolved like any other link, or nil
    /// if it can't be loaded under the current setting.
    static func displayURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let resolved = resolved(url)
        return allows(resolved) ? resolved : nil
    }

    /// Errors suggesting a server has no working HTTPS, after an http link was tried over https. Offline and the like
    /// aren't included, so they show their own message.
    static let httpsUnavailable: Set<URLError.Code> = [
        .secureConnectionFailed, .cannotConnectToHost, .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected, .timedOut,
    ]

    /// Rewrites http links to https, so links published over http keep working wherever the server offers HTTPS.
    static func upgraded(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.url ?? url
    }

    static let session = URLSession(configuration: .default, delegate: Redirects(), delegateQueue: nil)

    private final class Redirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // An http redirect is followed over https unless Allow HTTP is on, like any other http link.
            guard let target = request.url.map({ DownloadPolicy.resolved($0) }), DownloadPolicy.allows(target) else {
                return completionHandler(nil)
            }
            var redirected = request
            redirected.url = target
            completionHandler(redirected)
        }
    }
}
