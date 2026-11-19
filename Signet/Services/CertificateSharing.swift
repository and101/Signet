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

    /// Where a callback template goes, for the confirmation: `livecontainer://certificate`.
    static func destination(of template: String) -> String {
        guard let scheme = scheme(of: template) else { return template }
        let host = URL(string: template)?.host ?? ""
        return host.isEmpty ? "\(scheme)://" : "\(scheme)://\(host)"
    }

    /// The app a callback template goes to.
    static func scheme(of template: String) -> String? {
        URL(string: template)?.scheme ?? template.components(separatedBy: "://").first
    }

    /// Apps allowed to receive a certificate through a callback link. Any other scheme could forward it on (browsers
    /// open web links with their own schemes, such as googlechrome://), so only apps known to use it are allowed.
    static let allowedCallbackSchemes: Set<String> = [liveContainerScheme]

    static func isAppScheme(_ template: String) -> Bool {
        guard let scheme = scheme(of: template)?.lowercased() else { return false }
        return allowedCallbackSchemes.contains(scheme)
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
    /// - Parameter allowWithoutPasscode: proceed on an iPhone with no passcode, where there's nothing to check
    ///   against (backups). Sending a certificate to another app always needs one.
    static func authenticate(reason: String, allowWithoutPasscode: Bool = false) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if allowWithoutPasscode, (error as? LAError)?.code == .passcodeNotSet { return }
            throw AppError("Set a passcode on this iPhone first.")
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw AppError("Cancelled: \(error.localizedDescription)")
        }
    }
}
