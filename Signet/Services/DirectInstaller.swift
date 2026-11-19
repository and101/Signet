import Foundation
import Network
import IDevice

/// Installs an IPA on this iPhone the way a computer does, without the install server: through an encrypted
/// remote-pairing tunnel to the device's own services, reached over a loopback VPN (LocalDevVPN routes 10.7.0.1
/// back to the device) with a remote-pairing file made once on a computer (iloader).
///
/// Every call into idevice blocks, so use an instance off the main thread, and from one task at a time.
// Unchecked: one task uses an instance at a time; the timeout only hands it to a worker thread and stops using it.
final class DirectInstaller: @unchecked Sendable {
    struct Failure: LocalizedError {
        /// `tunnel`: the device answered but wouldn't open the tunnel, usually an expired pairing file.
        enum Stage { case pairingFile, connect, tunnel, upload, install }
        let stage: Stage
        let message: String
        var errorDescription: String? { message }
    }

    static let defaultAddress = "10.7.0.1"
    /// Where the remote-pairing service usually listens; Bonjour (`_remotepairing._tcp`) gives the exact port.
    static let defaultPort: UInt16 = 49152
    static let stagingFolder = "/PublicStaging"
    static let stagedPrefix = "signet-"

    private let pairingFileURL: URL
    private let address: String
    private let log: (String) -> Void
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?

    init(pairingFileURL: URL, address: String = DirectInstaller.defaultAddress, log: @escaping (String) -> Void = { _ in }) {
        self.pairingFileURL = pairingFileURL
        self.address = address
        self.log = log
    }

    deinit { disconnect() }

    // MARK: - Pairing file

    /// Whether a file is a remote-pairing file. Older lockdown pairing files don't work over the network on
    /// current iOS, so they're rejected.
    static func isRemotePairingFile(_ url: URL) -> Bool {
        var handle: OpaquePointer?
        if let error = rp_pairing_file_read(url.path, &handle) {
            idevice_error_free(error)
            return false
        }
        rp_pairing_file_free(handle)
        return true
    }

    /// Whether a file looks like the older lockdown pairing format, to explain why it was rejected.
    static func isLockdownPairingFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return false }
        return ["HostCertificate", "HostPrivateKey", "DeviceCertificate"].allSatisfy { plist[$0] != nil }
    }

    // MARK: - Reaching the device

    /// Opens a plain TCP connection to the pairing service, to check the VPN routes to the device.
    static func isReachable(address: String, port: UInt16, timeout: TimeInterval = 3) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = Once()
            let finish = { (reachable: Bool) in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: reachable)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Ports of the `_remotepairing._tcp` services Bonjour finds within `timeout`. Other Apple devices on the same
    /// Wi-Fi advertise it too, so the caller checks which one answers at the VPN address.
    static func discoverPorts(timeout: TimeInterval = 3) async -> [UInt16] {
        await withCheckedContinuation { continuation in
            let once = Once()
            let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: "local."), using: .tcp)
            // Browser and resolver callbacks all run on this serial queue.
            let queue = DispatchQueue(label: "Signet.remotePairingDiscovery")
            let state = Holder<DiscoveryState>()
            state.value = DiscoveryState()
            let finish = {
                guard once.claim() else { return }
                browser.cancel()
                state.value?.resolvers.forEach { $0.cancel() }
                continuation.resume(returning: state.value?.ports ?? [])
            }
            browser.browseResultsChangedHandler = { results, _ in
                for result in results where !(state.value?.seen.contains(result.endpoint) ?? true) {
                    state.value?.seen.insert(result.endpoint)
                    // Connecting resolves the service to an address and port.
                    let connection = NWConnection(to: result.endpoint, using: .tcp)
                    state.value?.resolvers.append(connection)
                    connection.stateUpdateHandler = { connectionState in
                        if case .ready = connectionState, case .hostPort(_, let port)? = connection.currentPath?.remoteEndpoint,
                           !(state.value?.ports.contains(port.rawValue) ?? true) {
                            state.value?.ports.append(port.rawValue)
                        }
                    }
                    connection.start(queue: queue)
                }
            }
            browser.stateUpdateHandler = { browserState in
                if case .failed = browserState { finish() }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }

    private struct DiscoveryState {
        var seen: Set<NWEndpoint> = []
        var resolvers: [NWConnection] = []
        var ports: [UInt16] = []
    }

    // MARK: - Connecting

    /// Opens the tunnel and returns the iOS version the device reports.
    func connect(port: UInt16) throws -> String {
        disconnect()
        let originalFile = try? Data(contentsOf: pairingFileURL)
        var pairing: OpaquePointer?
        try check(.pairingFile, "Couldn't read the pairing file", rp_pairing_file_read(pairingFileURL.path, &pairing))
        defer { rp_pairing_file_free(pairing) }

        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1 else {
            throw Failure(stage: .connect, message: String(localized: "\(address) isn't a valid IPv4 address."))
        }
        let error = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing($0, idevice_socklen_t(MemoryLayout<sockaddr_in>.size), "Signet", pairing,
                                        nil, nil, &adapter, &handshake)
            }
        }
        try check(.tunnel, "This iPhone refused the connection", error)
        log("Connected on port \(port)")
        // A failed pair-verify can fall back to pair-setup, which updates the file; keep the newest copy. Not if the
        // file changed meanwhile: this may be a timed-out attempt finishing after the user imported a new one.
        if (try? Data(contentsOf: pairingFileURL)) == originalFile,
           let error = rp_pairing_file_write(pairing, pairingFileURL.path) {
            idevice_error_free(error)
        }

        var lockdown: OpaquePointer?
        try check(.connect, "Couldn't reach the iPhone's services", lockdownd_connect_rsd(adapter, handshake, &lockdown))
        defer { lockdownd_client_free(lockdown) }
        var value: plist_t?
        try check(.connect, "Couldn't read the iOS version", lockdownd_get_value(lockdown, "ProductVersion", nil, &value))
        defer { plist_free(value) }
        var string: UnsafeMutablePointer<CChar>?
        plist_get_string_val(value, &string)
        defer { plist_mem_free(string) }
        return string.map { String(cString: $0) } ?? "unknown"
    }

    /// How long opening the tunnel may take. A failed pair-verify can fall back to pair-setup, which waits for a PIN
    /// Signet can't give, so without a limit "Connecting…" could spin forever.
    static let connectTimeout: TimeInterval = 20

    /// `connect(port:)` with a time limit. A timed-out attempt is abandoned (idevice calls can't be cancelled), and
    /// this installer shouldn't be used afterwards.
    func connect(port: UInt16, timeout: TimeInterval = DirectInstaller.connectTimeout) async throws -> String {
        // Not a task group: it would wait for the blocked call before returning. Whichever finishes first wins and
        // the other is ignored; a stuck call keeps its thread, which is the price of not being able to cancel it.
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try self.connect(port: port) }
                if once.claim() { continuation.resume(with: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                continuation.resume(throwing: Failure(stage: .tunnel,
                                                      message: String(localized: "This iPhone didn't answer within \(Int(timeout)) seconds")))
            }
        }
    }

    func disconnect() {
        rsd_handshake_free(handshake)
        handshake = nil
        adapter_free(adapter)
        adapter = nil
    }

    // MARK: - Uploading

    /// Copies an IPA into the device's staging folder. `staged` gets the path before any data is written, so a
    /// crash or a self-update still leaves a record to clean up. Returns the path on the device.
    func upload(_ file: URL, staged: (String) -> Void = { _ in }, progress: (Double) -> Void) throws -> String {
        let afc = try connectAFC()
        defer { afc_client_free(afc) }
        // Fails harmlessly when the folder exists.
        if let error = afc_make_directory(afc, Self.stagingFolder) { idevice_error_free(error) }

        let remote = "\(Self.stagingFolder)/\(Self.stagedPrefix)\(UUID().uuidString.prefix(8)).ipa"
        var handle: OpaquePointer?
        try check(.upload, "Couldn't start the upload", afc_file_open(afc, remote, AfcWrOnly, &handle))
        staged(remote)
        var closed = false
        defer { if !closed, let error = afc_file_close(handle) { idevice_error_free(error) } }

        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber
        let total = max(size?.doubleValue ?? 1, 1)
        var sent = 0.0
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try chunk.withUnsafeBytes { bytes in
                try check(.upload, "The upload was interrupted", afc_file_write(handle, bytes.bindMemory(to: UInt8.self).baseAddress, chunk.count))
            }
            sent += Double(chunk.count)
            progress(sent / total)
        }
        closed = true
        try check(.upload, "Couldn't finish the upload", afc_file_close(handle))
        return remote
    }

    /// Signet's IPAs left in the staging folder, including ones from earlier versions that didn't record them.
    /// Throws if the iPhone can't be reached; an empty list means there are none.
    func listStaged() throws -> [String] {
        let afc = try connectAFC()
        defer { afc_client_free(afc) }
        var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count = 0
        if let error = afc_list_directory(afc, Self.stagingFolder, &entries, &count) {
            // Can't tell a missing folder from a dropped connection, so report it; callers keep their records.
            defer { idevice_error_free(error) }
            throw Failure(stage: .upload, message: String(localized: "Couldn't list the iPhone's staging folder (code \(error.pointee.code))"))
        }
        guard let entries else { return [] }
        var names: [String] = []
        for index in 0..<count {
            guard let entry = entries[index] else { continue }
            names.append(String(cString: entry))
            idevice_string_free(entry)
        }
        // The array itself isn't freed: idevice has no function for it, and freeing memory another allocator owns
        // would crash. It's a few bytes per cleanup.
        return names.filter { $0.hasPrefix(Self.stagedPrefix) && $0.hasSuffix(".ipa") }
            .map { "\(Self.stagingFolder)/\($0)" }
    }

    /// Deletes staged IPAs (each is as big as its app). Returns the paths it deleted; failures stay recorded so a
    /// later cleanup can retry. Only Signet's own files are touched.
    func removeStaged(_ paths: [String]) throws -> [String] {
        let ours = paths.filter { $0.hasPrefix("\(Self.stagingFolder)/\(Self.stagedPrefix)") }
        guard !ours.isEmpty else { return [] }
        let afc = try connectAFC()
        defer { afc_client_free(afc) }
        var removed: [String] = []
        for path in ours {
            if let error = afc_remove_path(afc, path) {
                log("Couldn't delete \(path) from the iPhone: code \(error.pointee.code)")
                idevice_error_free(error)
            } else {
                removed.append(path)
            }
        }
        return removed
    }

    // MARK: - Installing

    /// Asks iOS to install a staged IPA, reporting its progress from 0 to 1. `requestSent` is called on the
    /// calling thread just before the request goes out, for a self-update to quit once it's on its way.
    func install(remotePath: String, bundleID: String?, requestSent: () -> Void = {}, progress: @escaping (Double) -> Void) throws {
        var client: OpaquePointer?
        try check(.install, "Couldn't reach the installer", installation_proxy_connect_rsd(adapter, handshake, &client))
        defer { installation_proxy_client_free(client) }

        let options = plist_new_dict()
        defer { plist_free(options) }
        if let bundleID { plist_dict_set_item(options, "CFBundleIdentifier", plist_new_string(bundleID)) }

        let box = Unmanaged.passRetained(ProgressBox(progress))
        defer { box.release() }
        let callback: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { value, context in
            guard let context else { return }
            Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue().report(min(Double(value), 100) / 100)
        }
        requestSent()
        try check(.install, "iOS couldn't install the app",
                  installation_proxy_install_with_callback(client, remotePath, options, callback, box.toOpaque()))
    }

    /// What iOS is doing at each percentage the installer reports, in plain words.
    static func phase(forPercent percent: Int) -> String {
        switch percent {
        case ..<5: String(localized: "Preparing the app…")
        case ..<15: String(localized: "Creating a staging folder…")
        case ..<20: String(localized: "Unpacking the app…")
        case ..<30: String(localized: "Inspecting the app…")
        case ..<40: String(localized: "Checking the app…")
        case ..<50: String(localized: "Verifying the signature…")
        case ..<60: String(localized: "Creating the app's container…")
        case ..<70: String(localized: "Installing…")
        case ..<80: String(localized: "Finishing up…")
        case ..<90: String(localized: "Setting up the sandbox…")
        case ..<100: String(localized: "Registering the app…")
        default: String(localized: "Installed")
        }
    }

    // MARK: - Helpers

    private func connectAFC() throws -> OpaquePointer? {
        guard let adapter else { throw Failure(stage: .connect, message: String(localized: "Not connected to this iPhone.")) }
        var afc: OpaquePointer?
        try check(.upload, "Couldn't reach the iPhone's file service", afc_client_connect_rsd(adapter, handshake, &afc))
        return afc
    }

    private func check(_ stage: Failure.Stage, _ summary: String.LocalizationValue, _ error: UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let error else { return }
        let summary = String(localized: summary)
        defer { idevice_error_free(error) }
        let detail = error.pointee.message.map { String(cString: $0) } ?? "code \(error.pointee.code)"
        log("\(summary): \(detail) [\(error.pointee.code)/\(error.pointee.sub_code)]")
        throw Failure(stage: stage, message: "\(summary): \(detail)")
    }

    // MARK: - Library log

    /// idevice's own debug log, included in Copy Diagnostics.
    static let libraryLogURL = FileManager.default.temporaryDirectory.appendingPathComponent("idevice.log")
    private static let loggerStarted: Void = {
        try? FileManager.default.removeItem(at: libraryLogURL)
        _ = libraryLogURL.path.withCString { idevice_init_logger(Disabled, Info, UnsafeMutablePointer(mutating: $0)) }
    }()
    static func startLibraryLog() { _ = loggerStarted }
}

private final class ProgressBox {
    let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }
}

/// A mutable slot shared by callbacks that all run on one serial queue.
private final class Holder<Value>: @unchecked Sendable {
    var value: Value?
}

/// Lets exactly one of several racing callbacks win.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}
