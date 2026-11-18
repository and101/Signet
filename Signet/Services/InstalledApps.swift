import Foundation

/// Finds the bundle IDs an app may already be installed under, so a re-sign can update it in place.
///
/// iOS has no public API to list installed apps, so several private LaunchServices queries are tried. Each is
/// trusted only if it reports this app as installed and a made-up bundle ID as not installed. When none passes
/// (iOS hides other apps from sandboxed apps), the bundle IDs this app was signed or installed with are offered.
enum InstalledApps {
    struct Match: Hashable {
        enum Evidence { case installed, previouslyInstalled, signedBefore }
        let bundleID: String
        let evidence: Evidence
    }

    struct Detection: Equatable {
        /// Whether iOS answered install queries; if false, matches come from this app's own records.
        var systemCanSee: Bool
        var matches: [Match]
    }

    typealias Check = (String) -> Bool?

    /// Bundle IDs worth checking for `app`: its own, then those it was signed with, newest first.
    static func candidates(for app: LibraryApp, in library: [LibraryApp]) -> [String] {
        unique([originalBundleID(of: app), app.bundleID] + signedBundleIDs(for: app, in: library))
    }

    static func detect(
        for app: LibraryApp,
        in library: [LibraryApp],
        check: Check? = workingSystemCheck(),
        history: Set<String> = InstallHistory.bundleIDs
    ) -> Detection {
        let candidates = candidates(for: app, in: library)
        if let check {
            let installed = candidates.filter { check($0) == true }
            return Detection(systemCanSee: true, matches: installed.map { Match(bundleID: $0, evidence: .installed) })
        }
        let signed = Set(signedBundleIDs(for: app, in: library))
        let matches = candidates.compactMap { id -> Match? in
            if history.contains(id) { return Match(bundleID: id, evidence: .previouslyInstalled) }
            if signed.contains(id) { return Match(bundleID: id, evidence: .signedBefore) }
            return nil
        }
        return Detection(systemCanSee: false, matches: matches)
    }

    private static func originalBundleID(of app: LibraryApp) -> String {
        app.kind == .signed ? (app.originalBundleID ?? app.bundleID) : app.bundleID
    }

    private static func signedBundleIDs(for app: LibraryApp, in library: [LibraryApp]) -> [String] {
        let original = originalBundleID(of: app)
        return library
            .filter { $0.kind == .signed && ($0.originalAppID == app.id || $0.originalBundleID == original) }
            .sorted { $0.dateAdded > $1.dateAdded }
            .map(\.bundleID)
    }

    private static func unique(_ ids: [String]) -> [String] {
        ids.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    // MARK: - System queries

    /// The first query that gives correct answers for a known-installed and a known-missing bundle ID.
    static func workingSystemCheck(_ checks: [Check] = [workspaceCheck, proxyCheck, recordCheck]) -> Check? {
        guard let me = Bundle.main.bundleIdentifier else { return nil }
        let missing = "com.example.not-installed.\(UUID().uuidString)"
        return checks.first { $0(me) == true && $0(missing) == false }
    }

    /// `-[LSApplicationWorkspace applicationIsInstalled:]`
    static func workspaceCheck(_ bundleID: String) -> Bool? {
        guard let workspace = classObject("LSApplicationWorkspace", call: "defaultWorkspace") else { return nil }
        return callBool(workspace, "applicationIsInstalled:", bundleID)
    }

    /// `+[LSApplicationProxy applicationProxyForIdentifier:]`, then `appState.isInstalled` (or `isInstalled`).
    static func proxyCheck(_ bundleID: String) -> Bool? {
        guard let proxy = classObject("LSApplicationProxy", call: "applicationProxyForIdentifier:", bundleID) else {
            return false
        }
        if let state = callObject(proxy, "appState"), let installed = callBool(state, "isInstalled") { return installed }
        return callBool(proxy, "isInstalled")
    }

    /// `+[LSBundleRecord bundleRecordWithBundleIdentifier:allowPlaceholder:error:]`: a record exists if installed.
    static func recordCheck(_ bundleID: String) -> Bool? {
        guard let recordClass = NSClassFromString("LSBundleRecord") as AnyObject? else { return nil }
        let selector = NSSelectorFromString("bundleRecordWithBundleIdentifier:allowPlaceholder:error:")
        guard recordClass.responds(to: selector) else { return nil }
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, Bool, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let lookup = unsafeBitCast(recordClass.method(for: selector), to: Lookup.self)
        var error: NSError?
        return lookup(recordClass, selector, bundleID as NSString, false, &error) != nil
    }

    private static func classObject(_ name: String, call selectorName: String, _ argument: String? = nil) -> NSObject? {
        guard let cls = NSClassFromString(name) as AnyObject? else { return nil }
        let selector = NSSelectorFromString(selectorName)
        guard cls.responds(to: selector) else { return nil }
        let result = argument.map { cls.perform(selector, with: $0 as NSString) } ?? cls.perform(selector)
        return result?.takeUnretainedValue() as? NSObject
    }

    private static func callObject(_ target: NSObject, _ selectorName: String) -> NSObject? {
        let selector = NSSelectorFromString(selectorName)
        guard target.responds(to: selector) else { return nil }
        return target.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private static func callBool(_ target: NSObject, _ selectorName: String, _ argument: String? = nil) -> Bool? {
        let selector = NSSelectorFromString(selectorName)
        guard target.responds(to: selector) else { return nil }
        if let argument {
            typealias Query = @convention(c) (AnyObject, Selector, NSString) -> Bool
            return unsafeBitCast(target.method(for: selector), to: Query.self)(target, selector, argument as NSString)
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(target.method(for: selector), to: Getter.self)(target, selector)
    }
}

/// Bundle IDs this signer has sent to iOS for installation.
enum InstallHistory {
    private static let key = "installedBundleIDs"

    static var bundleIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func record(_ bundleID: String) {
        var ids = bundleIDs
        guard ids.insert(bundleID).inserted else { return }
        UserDefaults.standard.set(ids.sorted(), forKey: key)
    }
}
