import Foundation
import LocalAuthentication

/// Hands certificates to other apps and accepts them from links, using the formats LiveContainer, SideStore and
/// Feather already use. A certificate and its password let anyone sign apps as you, so every export asks first and
/// needs Face ID, Touch ID or the passcode.
enum CertificateSharing {
    static let liveContainerScheme = "livecontainer"

    /// `livecontainer://certificate?cert=<base64 p12>&password=<password>`, which LiveContainer accepts at any time.
    static func liveContainerURL(p12: Data, password: String) -> URL? {
        var components = URLComponents()
        components.scheme = liveContainerScheme
        components.host = "certificate"
        components.queryItems = [
            URLQueryItem(name: "cert", value: p12.base64EncodedString()),
            URLQueryItem(name: "password", value: password),
        ]
        // Base64's + and / must survive the trip, so encode them as well.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F")
        return components.url
    }

    /// Fills a requesting app's callback template, e.g. `livecontainer://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)`.
    /// Returns nil for web or file links, which would send the certificate off the device.
    static func callbackURL(template: String, p12: Data, password: String) -> URL? {
        guard isAppScheme(template), template.contains("$(BASE64_CERT)") else { return nil }
        let encode: (String) -> String = {
            $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0
        }
        let filled = template
            .replacingOccurrences(of: "$(BASE64_CERT)", with: encode(p12.base64EncodedString()))
            .replacingOccurrences(of: "$(PASSWORD)", with: encode(password))
        return URL(string: filled)
    }

    /// The app a callback template goes to, for the confirmation ("Send to livecontainer?").
    static func scheme(of template: String) -> String? {
        URL(string: template)?.scheme ?? template.components(separatedBy: "://").first
    }

    /// Only custom app schemes, never http(s), file or data links.
    static func isAppScheme(_ template: String) -> Bool {
        guard let scheme = scheme(of: template)?.lowercased(), !scheme.isEmpty else { return false }
        return !["http", "https", "file", "data", "ftp", "javascript", "about"].contains(scheme)
    }

    // MARK: - Import

    struct IncomingCertificate: Equatable {
        let p12: Data
        let profile: Data
        let password: String
    }

    /// Feather's format: `import-certificate?p12=<base64>&mobileprovision=<base64>&password=<base64>`.
    static func incoming(from url: URL) -> IncomingCertificate? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> Data? {
            items.first { $0.name.lowercased() == name }?.value
                .flatMap { $0.removingPercentEncoding ?? $0 }
                .flatMap { Data(base64Encoded: $0.replacingOccurrences(of: " ", with: "+")) }
        }
        guard let p12 = value("p12"), let profile = value("mobileprovision"), !p12.isEmpty, !profile.isEmpty else { return nil }
        let password = value("password").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return IncomingCertificate(p12: p12, profile: profile, password: password)
    }

    // MARK: - Authentication

    /// Face ID, Touch ID or the passcode. Throws if the user cancels or the device has no passcode.
    static func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw AppError("Set a passcode on this iPhone to share certificates.")
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw AppError("Not shared: \(error.localizedDescription)")
        }
    }
}
