import Foundation

/// Reads iOS's progress for an app it's installing, through private LaunchServices calls.
/// Every call checks the method exists first and returns nil when it doesn't, so a future iOS that removes
/// them just loses the progress bar.
enum InstallProgress {
    private static let progressSelector = NSSelectorFromString("installProgressForBundleID:makeSynchronous:")
    private static let openSelector = NSSelectorFromString("openApplicationWithBundleID:")

    private static var workspace: NSObject? {
        guard let cls = NSClassFromString("LSApplicationWorkspace") as AnyObject? else { return nil }
        let selector = NSSelectorFromString("defaultWorkspace")
        guard cls.responds(to: selector) else { return nil }
        return cls.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    /// Whether this iOS offers install progress at all.
    static var isAvailable: Bool {
        workspace?.responds(to: progressSelector) ?? false
    }

    /// How far iOS is through installing `bundleID`, from 0 to 1, or nil when no install is in progress.
    static func fraction(for bundleID: String) -> Double? {
        guard let workspace, workspace.responds(to: progressSelector) else { return nil }
        typealias Query = @convention(c) (AnyObject, Selector, NSString, Bool) -> Unmanaged<AnyObject>?
        let query = unsafeBitCast(workspace.method(for: progressSelector), to: Query.self)
        guard let progress = query(workspace, progressSelector, bundleID as NSString, true)?
            .takeUnretainedValue() as? Progress else { return nil }
        return min(max(progress.fractionCompleted, 0), 1)
    }

    static var canOpenApps: Bool {
        workspace?.responds(to: openSelector) ?? false
    }

    /// Opens an installed app. Returns false if iOS refused or the call isn't available.
    @discardableResult
    static func open(_ bundleID: String) -> Bool {
        guard let workspace, workspace.responds(to: openSelector) else { return false }
        typealias Open = @convention(c) (AnyObject, Selector, NSString) -> Bool
        return unsafeBitCast(workspace.method(for: openSelector), to: Open.self)(workspace, openSelector, bundleID as NSString)
    }
}

/// Decides what an install is doing from repeated progress readings, after Signet has sent iOS the IPA.
struct InstallWatch {
    enum Step: Equatable {
        /// Still installing; nil while iOS hasn't reported a fraction yet.
        case installing(Double?)
        case installed
        /// iOS never reported progress, or took too long; Signet can't tell how it went.
        case unknown
    }

    /// How long to wait for iOS to start reporting progress.
    static let startTimeout: TimeInterval = 15
    /// How long an install may take before Signet stops watching.
    static let overallTimeout: TimeInterval = 5 * 60

    let started: Date
    private(set) var sawProgress = false

    init(started: Date = Date()) {
        self.started = started
    }

    /// The build (CFBundleVersion) iOS has installed under `bundleID`: `.some(nil)` if it isn't installed,
    /// nil if Signet can't tell (iOS hides installed apps, or the build can't be read).
    static func installedBuild(_ bundleID: String) -> String?? {
        guard let check = InstalledApps.workingSystemCheck(), let installed = check(bundleID) else { return nil }
        guard installed else { return .some(nil) }
        return InstalledApps.installedBuild(bundleID).map { .some($0) } ?? nil
    }

    /// Whether the install demonstrably worked: before, iOS had something other than `expected` (or nothing),
    /// and now it has `expected`. Reinstalling the same build can't be confirmed, since a failure looks the same.
    static func confirmed(before: String??, after: String??, expected: String) -> Bool {
        guard case .some(let old) = before, case .some(let new) = after else { return false }
        return new == expected && old != expected
    }

    mutating func step(progress: Double?, now: Date = Date()) -> Step {
        let elapsed = now.timeIntervalSince(started)
        if let progress {
            sawProgress = true
            // iOS can hold a finished progress object for a moment; 1.0 means done.
            if progress >= 1 { return .installed }
            return elapsed > Self.overallTimeout ? .unknown : .installing(progress)
        }
        // The progress object disappears when the install ends.
        if sawProgress { return .installed }
        return elapsed > Self.startTimeout ? .unknown : .installing(nil)
    }
}
