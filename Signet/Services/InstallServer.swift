import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

/// A tiny HTTPS server bound to 127.0.0.1 that serves the itms-services manifest, IPA and icon.
final class InstallServer: @unchecked Sendable {
    static let shared = InstallServer()

    struct HostedApp {
        let ipa: URL
        let icon: URL?
        let bundleID: String
        /// CFBundleVersion (the build number), which iOS compares with the installed app.
        let bundleVersion: String
        let title: String
    }

    private let lock = NSLock()
    private var group: MultiThreadedEventLoopGroup?
    private var channels: [Channel] = []
    private var threadPool: NIOThreadPool?
    private var hosted: [String: HostedApp] = [:]
    private var profileData: Data?
    private(set) var port = 0
    private(set) var hostname = ""

    /// Plain-HTTP port for the CA profile. Safari can't fetch it over HTTPS before the CA is trusted.
    var profilePort: Int { port + 100 }

    /// Called with (token, bytesSent, totalBytes) while the IPA is being downloaded by iOS.
    var onProgress: (@Sendable (String, Int64, Int64) -> Void)?
    /// Called with (token, file name) whenever iOS requests a hosted file.
    var onRequest: (@Sendable (String, String) -> Void)?

    var isRunning: Bool { lock.withLock { !channels.isEmpty } }

    func start() throws {
        try lock.withLock {
            guard channels.isEmpty else { return }
            let info = try ServerCertificate.ensure()
            let chain = try NIOSSLCertificate.fromPEMFile(ServerCertificate.certificateURL.path)
            let key = try NIOSSLPrivateKey(file: ServerCertificate.keyURL.path, format: .pem)
            let tls = TLSConfiguration.makeServerConfiguration(
                certificateChain: chain.map { .certificate($0) },
                privateKey: .privateKey(key)
            )
            let sslContext = try NIOSSLContext(configuration: tls)

            let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
            let pool = NIOThreadPool(numberOfThreads: 2)
            pool.start()
            let fileIO = NonBlockingFileIO(threadPool: pool)

            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 32)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [weak self] channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sync = channel.pipeline.syncOperations
                        try sync.addHandler(NIOSSLServerHandler(context: sslContext))
                        try sync.configureHTTPServerPipeline()
                        try sync.addHandler(RequestHandler(server: self, fileIO: fileIO, profileOnly: false))
                    }
                }
            let plainBootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [weak self] channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sync = channel.pipeline.syncOperations
                        try sync.configureHTTPServerPipeline()
                        try sync.addHandler(RequestHandler(server: self, fileIO: fileIO, profileOnly: true))
                    }
                }

            // localhost resolves to both 127.0.0.1 and ::1, so listen on both loopback addresses.
            var lastError: Error?
            for candidate in 47_801...47_820 {
                var bound: [Channel] = []
                do {
                    bound.append(try bootstrap.bind(host: "127.0.0.1", port: candidate).wait())
                    // The profile URL always uses this port, so it must be ours: if another app holds it, Safari
                    // would be sent to that app while the user is asked to trust a root certificate.
                    bound.append(try plainBootstrap.bind(host: "127.0.0.1", port: candidate + 100).wait())
                    if let v6 = try? bootstrap.bind(host: "::1", port: candidate).wait() {
                        bound.append(v6)
                    }
                    channels = bound
                    port = candidate
                    break
                } catch {
                    for channel in bound { try? channel.close().wait() }
                    lastError = error
                }
            }
            guard !channels.isEmpty else {
                try? group.syncShutdownGracefully()
                try? pool.syncShutdownGracefully()
                throw lastError ?? AppError("Couldn't start the install server.")
            }
            self.group = group
            self.threadPool = pool
            self.hostname = info.hostname
        }
    }

    func stop() {
        // Detach the running state under the lock, then shut it down without holding it. Request handlers on the
        // event loops take the same lock, so waiting for the loops while holding it can deadlock.
        let (channels, group, threadPool) = lock.withLock {
            let detached = (self.channels, self.group, self.threadPool)
            self.channels = []
            self.group = nil
            self.threadPool = nil
            hosted.removeAll()
            return detached
        }
        for channel in channels { try? channel.close().wait() }
        try? group?.syncShutdownGracefully()
        try? threadPool?.syncShutdownGracefully()
    }

    /// Restarts so a newly downloaded certificate takes effect.
    func restartIfRunning() throws {
        guard isRunning else { return }
        stop()
        try start()
    }

    /// iOS can reclaim an app's listening sockets while it's suspended. The channels still look open to NIO, but
    /// nothing answers, so iOS's install request goes nowhere. Ping the server and rebuild it if it's gone quiet.
    func ensureResponsive() async throws {
        guard isRunning else { return try start() }
        if await respondsToPing() { return }
        stop()
        try start()
    }

    #if DEBUG
    /// Closes the sockets but leaves the server looking "running", like after iOS reclaims them.
    func simulateReclaimedSockets() {
        let channels = lock.withLock { self.channels }
        for channel in channels { try? channel.close().wait() }
    }
    #endif

    private func respondsToPing() async -> Bool {
        // The IP address, not the hostname: ATS ignores trust overrides for named hosts.
        guard let url = URL(string: "https://127.0.0.1:\(port)/ping") else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration, delegate: LoopbackTrust(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Registers an app and returns (token, itms-services URL).
    func host(_ app: HostedApp) throws -> (String, URL) {
        try start()
        let token = UUID().uuidString.lowercased()
        lock.withLock { hosted[token] = app }
        let manifest = baseURL(token).appendingPathComponent("manifest.plist").absoluteString
        return (token, Self.itmsURL(manifest: manifest))
    }

    /// iOS only accepts the `itms-services://?action=…` form. URLComponents drops the `//` when there's no
    /// host (`itms-services:?action=…`), which iOS silently ignores, so build the string by hand.
    static func itmsURL(manifest: String) -> URL {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?&=+#")
        let encoded = manifest.addingPercentEncoding(withAllowedCharacters: allowed) ?? manifest
        return URL(string: "itms-services://?action=download-manifest&url=\(encoded)")!
    }

    /// Serves the CA profile over plain HTTP and returns a URL for Safari to open.
    func serveProfile(_ data: Data) throws -> URL {
        try start()
        lock.withLock { profileData = data }
        return URL(string: "http://127.0.0.1:\(profilePort)/Signet.mobileconfig")!
    }

    fileprivate var profile: Data? { lock.withLock { profileData } }

    func baseURL(_ token: String) -> URL {
        URL(string: "https://\(hostname):\(port)/\(token)/")!
    }

    fileprivate func app(for token: String) -> HostedApp? {
        lock.withLock { hosted[token] }
    }

    fileprivate func manifest(token: String, app: HostedApp) -> Data {
        let base = baseURL(token)
        var assets: [[String: String]] = [
            ["kind": "software-package", "url": base.appendingPathComponent("app.ipa").absoluteString],
        ]
        if app.icon != nil {
            let icon = base.appendingPathComponent("icon.png").absoluteString
            assets.append(["kind": "display-image", "url": icon])
            assets.append(["kind": "full-size-image", "url": icon])
        }
        let plist: [String: Any] = [
            "items": [[
                "assets": assets,
                "metadata": [
                    "bundle-identifier": app.bundleID,
                    "bundle-version": app.bundleVersion,
                    "kind": "software",
                    "title": app.title,
                ],
            ]],
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }
}

/// Accepts the server's own certificate for the loopback health check, which runs before the CA may be trusted.
private final class LoopbackTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private weak var server: InstallServer?
    private let fileIO: NonBlockingFileIO
    private let profileOnly: Bool
    private var head: HTTPRequestHead?

    init(server: InstallServer?, fileIO: NonBlockingFileIO, profileOnly: Bool) {
        self.server = server
        self.fileIO = fileIO
        self.profileOnly = profileOnly
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
        case .body:
            break
        case .end:
            guard let head else { return }
            self.head = nil
            respond(to: head, context: context)
        }
    }

    private func respond(to head: HTTPRequestHead, context: ChannelHandlerContext) {
        let parts = head.uri.split(separator: "?").first.map { $0.split(separator: "/").map(String.init) } ?? []
        if profileOnly {
            guard parts == ["Signet.mobileconfig"], let profile = server?.profile else {
                return sendStatus(.notFound, context: context, head: head)
            }
            return sendData(profile, contentType: "application/x-apple-aspen-config", context: context, head: head)
        }
        if parts == ["ping"] {
            // A health check must exercise a brand-new connection rather than reusing a pooled one.
            return sendData(Data("ok".utf8), contentType: "text/plain", closeConnection: true, context: context, head: head)
        }
        guard parts.count == 2, let server, let app = server.app(for: parts[0]) else {
            return sendStatus(.notFound, context: context, head: head)
        }
        let token = parts[0]
        server.onRequest?(token, parts[1])
        switch parts[1] {
        case "manifest.plist":
            sendData(server.manifest(token: token, app: app), contentType: "text/xml", context: context, head: head)
        case "icon.png":
            guard let icon = app.icon, let data = try? Data(contentsOf: icon) else {
                return sendStatus(.notFound, context: context, head: head)
            }
            sendData(data, contentType: "image/png", context: context, head: head)
        case "app.ipa":
            sendFile(app.ipa, token: token, context: context, head: head)
        default:
            sendStatus(.notFound, context: context, head: head)
        }
    }

    private func sendStatus(_ status: HTTPResponseStatus, context: ChannelHandlerContext, head: HTTPRequestHead) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: status, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }

    private func sendData(
        _ data: Data,
        contentType: String,
        closeConnection: Bool = false,
        context: ChannelHandlerContext,
        head: HTTPRequestHead
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(data.count)")
        if closeConnection {
            headers.add(name: "Connection", value: "close")
        }
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: .ok, headers: headers))), promise: nil)
        if head.method != .HEAD {
            let buffer = context.channel.allocator.buffer(bytes: data)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        let end = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if closeConnection {
            end.whenComplete { _ in context.close(promise: nil) }
        }
    }

    private func sendFile(_ url: URL, token: String, context: ChannelHandlerContext, head: HTTPRequestHead) {
        let total = FileManager.default.fileSize(at: url)
        guard total > 0, let handle = try? NIOFileHandle(path: url.path) else {
            return sendStatus(.notFound, context: context, head: head)
        }

        // Honour a single "bytes=start-[end]" range if the installer asks for one.
        var start: Int64 = 0
        var end: Int64 = total - 1
        var status: HTTPResponseStatus = .ok
        if let range = head.headers.first(name: "Range"), range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if let lower = bounds.first.flatMap({ Int64($0) }), lower < total {
                start = lower
                if bounds.count > 1, let upper = Int64(bounds[1]) { end = min(upper, total - 1) }
                status = .partialContent
            }
        }
        let length = end - start + 1

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/octet-stream")
        headers.add(name: "Content-Length", value: "\(length)")
        headers.add(name: "Accept-Ranges", value: "bytes")
        if status == .partialContent {
            headers.add(name: "Content-Range", value: "bytes \(start)-\(end)/\(total)")
        }
        context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: status, headers: headers))), promise: nil)

        guard head.method != .HEAD else {
            try? handle.close()
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            return
        }

        let progress = server?.onProgress
        var sent = start
        fileIO.readChunked(
            fileHandle: handle,
            fromOffset: start,
            byteCount: Int(length),
            chunkSize: 256 * 1024,
            allocator: context.channel.allocator,
            eventLoop: context.eventLoop
        ) { [weak self] chunk in
            guard let self else { return context.eventLoop.makeSucceededVoidFuture() }
            sent += Int64(chunk.readableBytes)
            progress?(token, sent, total)
            return context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(chunk))))
        }.whenComplete { result in
            try? handle.close()
            switch result {
            case .success:
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            case .failure:
                context.close(promise: nil)
            }
        }
    }
}
