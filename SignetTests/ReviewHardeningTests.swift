import XCTest
import ZIPFoundation
@testable import Signet

final class ReviewHardeningTests: XCTestCase {
    override func setUp() { Paths.prepare() }

    func testByteRanges() {
        XCTAssertEqual(HTTPByteRange.parse(nil, size: 1000), .full)
        XCTAssertEqual(HTTPByteRange.parse("bytes=10-19", size: 1000), .partial(start: 10, end: 19))
        XCTAssertEqual(HTTPByteRange.parse("bytes=900-", size: 1000), .partial(start: 900, end: 999))
        XCTAssertEqual(HTTPByteRange.parse("bytes=-100", size: 1000), .partial(start: 900, end: 999))
        XCTAssertEqual(HTTPByteRange.parse("bytes=-2000", size: 1000), .partial(start: 0, end: 999))
        XCTAssertEqual(HTTPByteRange.parse("bytes=900-2000", size: 1000), .partial(start: 900, end: 999))
        XCTAssertEqual(HTTPByteRange.parse("bytes= 10-19", size: 1000), .partial(start: 10, end: 19))
        for header in ["bytes=-0", "bytes=1000-", "bytes=2000-3000"] {
            XCTAssertEqual(HTTPByteRange.parse(header, size: 1000), .unsatisfiable, header)
        }
        XCTAssertEqual(HTTPByteRange.parse("bytes=0-", size: 0), .unsatisfiable)
        // Headers this server doesn't handle are ignored rather than refused.
        for header in ["bytes=100-50", "bytes=+10-19", "bytes=1-2-3", "bytes=1-2,4-5",
                       "bytes=9223372036854775808-", "bytes=", "bytes=--1", "items=0-1"] {
            XCTAssertEqual(HTTPByteRange.parse(header, size: 1000), .full, header)
        }
    }

    func testUntrustedVersionAndNameStayInTheirDirectory() {
        let app = LibraryApp(kind: .signed, name: "../App", bundleID: "com.test", version: "x/../../other/target", build: "1", appFolderName: "A.app", size: 0)
        XCTAssertEqual(app.ipaURL.standardizedFileURL.deletingLastPathComponent(), app.directory.standardizedFileURL)
        XCTAssertFalse(app.ipaFileName.contains("/"))
        XCTAssertLessThanOrEqual(LibraryApp.safeFileComponent(String(repeating: "😀", count: 100)).utf8.count, 80)
    }

    func testExistingLongFilenamesRemainReadable() throws {
        let app = LibraryApp(kind: .signed, name: String(repeating: "A", count: 100), bundleID: "com.test", version: "1", build: "1", appFolderName: "A.app", size: 0)
        try FileManager.default.createDirectory(at: app.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.directory) }
        let old = app.directory.appendingPathComponent("\(app.name)_1.ipa")
        try Data([1]).write(to: old)
        XCTAssertEqual(app.ipaURL, old)
    }

    func testEntitlementValuesMustBeGranted() {
        let profile: [String: Any] = ["groups": ["group.allowed"], "keychain-access-groups": ["TEAM.*"],
                                      "get-task-allow": false, "aps-environment": "production", "number": 1]
        let custom: [String: Any] = ["groups": ["group.other"], "keychain-access-groups": ["TEAM.app"],
                                     "get-task-allow": true, "aps-environment": "development", "number": true]
        XCTAssertEqual(EntitlementsMerger.ungranted(custom, profile: profile), ["aps-environment", "get-task-allow", "groups", "number"])
        XCTAssertEqual(EntitlementsMerger.ungranted(["groups": ["group.allowed"], "missing": false], profile: profile), [])
    }

    func testDownloadPolicyRejectsPlaintextAndCredentials() {
        for value in ["http://example.com/a", "httpx://example.com/a", "file:///tmp/a", "https://user:pass@example.com/a"] {
            XCTAssertFalse(DownloadPolicy.allows(URL(string: value)!, http: false), value)
        }
        XCTAssertTrue(DownloadPolicy.allows(URL(string: "https://example.com/a")!, http: false))
    }

    func testExtensionKitRewritesOnlyAppNamespace() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let metadata = root.appendingPathComponent("Info.plist")
        let points = root.appendingPathComponent("Test.appexpt")
        try PropertyListSerialization.data(fromPropertyList: ["EXAppExtensionAttributes": ["EXExtensionPointIdentifier": "com.old.point"]], format: .binary, options: 0).write(to: metadata)
        try PropertyListSerialization.data(fromPropertyList: ["com.old.point": [:], "com.apple.widgetkit-extension": [:], "com.older.point": [:]], format: .xml, options: 0).write(to: points)
        try Signer.rewriteExtensionKit(in: root, from: "com.old", to: "com.new")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: metadata))
        XCTAssertEqual((plist["EXAppExtensionAttributes"] as? [String: String])?["EXExtensionPointIdentifier"], "com.new.point")
        let declarations = try XCTUnwrap(NSDictionary(contentsOf: points))
        XCTAssertNotNil(declarations["com.new.point"])
        XCTAssertNil(declarations["com.old.point"])
        XCTAssertNotNil(declarations["com.apple.widgetkit-extension"])
        XCTAssertNotNil(declarations["com.older.point"])
    }

    func testBundleFolderMetadataMustStayInsidePayload() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        var app = LibraryApp(kind: .imported, name: "Test", bundleID: "com.test", version: "1", build: "1", appFolderName: "A.app", size: 0)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Payload/A.app"), withIntermediateDirectories: true)
        XCTAssertNoThrow(try app.validateAppFolder(in: root))
        // requireBundle: false, so a missing bundle can't be what makes these fail; check the reason too.
        for name in ["../outside.app", "/outside.app", "Payload/A.app", ".app", ".."] {
            app.appFolderName = name
            XCTAssertThrowsError(try app.validateAppFolder(in: root, requireBundle: false), name) { error in
                XCTAssertTrue(error.localizedDescription.contains("unsafe bundle folder name"), "\(name): \(error.localizedDescription)")
            }
        }
        // A bundle that's a link to a real folder elsewhere.
        app.appFolderName = "Link.app"
        let elsewhere = root.appendingPathComponent("Elsewhere.app", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Payload/Link.app"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try app.validateAppFolder(in: root, requireBundle: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("outside its Payload"), error.localizedDescription)
        }
    }

    func testTweakDoesNotReplaceADifferentFileInTheApp() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let app = root.appendingPathComponent("A.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "A"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try Data("not a binary".utf8).write(to: app.appendingPathComponent("A"))
        let shipped = app.appendingPathComponent("Frameworks/Foo.dylib")
        try Data("app's own".utf8).write(to: shipped)
        let tweak = root.appendingPathComponent("Foo.dylib")
        try Data("tweak".utf8).write(to: tweak)
        var options = SigningOptions()
        options.injectFiles = [tweak]
        XCTAssertThrowsError(try TweakInjector(appURL: app, options: options, log: { _ in }).run()) { error in
            XCTAssertTrue(error.localizedDescription.contains("already has a different Foo.dylib"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: shipped), Data("app's own".utf8))
    }

    /// The device case: the temporary folder is under /private, which Foundation drops only from paths that exist.
    func testExtractionUnderPrivate() throws {
        #if targetEnvironment(simulator)
        let base = URL(fileURLWithPath: "/private/tmp")
        #else
        let base = FileManager.default.temporaryDirectory // /private/var/mobile/… on a device
        #endif
        let root = base.appendingPathComponent("signet-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("app.ipa")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            func add(_ path: String, _ type: Entry.EntryType, _ text: String = "") throws {
                let body = Data(text.utf8)
                try archive.addEntry(with: path, type: type, uncompressedSize: Int64(body.count)) { position, size in
                    body.subdata(in: Int(position)..<(Int(position) + size))
                }
            }
            // A link before its target exists, a directory, a file, then a link after its target.
            try add("Payload/X.app/Early", .symlink, "X")
            try add("Payload/X.app/Frameworks/", .directory)
            try add("Payload/X.app/X", .file, "binary")
            try add("Payload/X.app/Late", .symlink, "X")
        }
        let out = root.appendingPathComponent("out")
        try ArchiveBudget.unzip(zip, to: out)
        let app = out.appendingPathComponent("Payload/X.app")
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("X")), Data("binary".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: app.appendingPathComponent("Early").path), "X")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: app.appendingPathComponent("Late").path), "X")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks").path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertNoThrow(try ArchiveBudget.checkContained(out.appendingPathComponent("a/b"), in: out))
        XCTAssertThrowsError(try ArchiveBudget.checkContained(out.appendingPathComponent("a/../../b"), in: out))
        // Stays inside lexically, so this only throws if `..` itself is caught (i.e. URL.path didn't collapse it).
        XCTAssertThrowsError(try ArchiveBudget.checkContained(out.appendingPathComponent("a/../b"), in: out))
    }

    private func patch(_ data: inout Data, signature: [UInt8], occurrence: Int, offset: Int, with bytes: [UInt8]) throws {
        var index = data.startIndex, found = -1
        while let range = data.range(of: Data(signature), in: index..<data.endIndex) {
            found += 1
            if found == occurrence {
                data.replaceSubrange((range.lowerBound + offset)..<(range.lowerBound + offset + bytes.count), with: bytes)
                return
            }
            index = range.upperBound
        }
        XCTFail("Fixture signature not found; the malformed-archive test didn't run")
        throw CocoaError(.fileReadCorruptFile)
    }

    func testDamagedCentralDirectoryIsNotMistakenForTheEnd() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let zip = root.appendingPathComponent("two.zip")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            for name in ["a", "b"] {
                let body = Data(name.utf8)
                try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(body.count)) { position, size in
                    body.subdata(in: Int(position)..<(Int(position) + size))
                }
            }
        }
        var bytes = try Data(contentsOf: zip)
        // Break the second central-directory record's signature, so the iterator stops after the first entry.
        try patch(&bytes, signature: [0x50, 0x4b, 0x01, 0x02], occurrence: 1, offset: 0, with: [0, 0, 0, 0])
        try bytes.write(to: zip)
        let archive = try Archive(url: zip, accessMode: .read)
        XCTAssertEqual(archive.declaredEntryCount, 2)
        XCTAssertThrowsError(try ArchiveBudget.ipa.validate(archive)) { error in
            XCTAssertTrue(error.localizedDescription.contains("damaged"), error.localizedDescription)
        }
    }

    func testEntryCantWritePastItsDeclaredSize() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let zip = root.appendingPathComponent("big.zip")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            let body = Data(repeating: 65, count: 100_000)
            try archive.addEntry(with: "a", type: .file, uncompressedSize: Int64(body.count), compressionMethod: .deflate) { position, size in
                body.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        do {
            // The untouched archive extracts, so a failure below comes from the size check.
            let archive = try Archive(url: zip, accessMode: .read)
            let out = root.appendingPathComponent("baseline")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var budget = ArchiveBudget.ipa
            try budget.extract(XCTUnwrap(archive["a"]), from: archive, to: out.appendingPathComponent("a"), root: out)
        }
        var bytes = try Data(contentsOf: zip)
        // Claim 100 bytes in both headers; the deflated data still expands to 100,000.
        let small: [UInt8] = [100, 0, 0, 0]
        try patch(&bytes, signature: [0x50, 0x4b, 0x03, 0x04], occurrence: 0, offset: 22, with: small)
        try patch(&bytes, signature: [0x50, 0x4b, 0x01, 0x02], occurrence: 0, offset: 24, with: small)
        try bytes.write(to: zip)
        let archive = try Archive(url: zip, accessMode: .read)
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var budget = ArchiveBudget.ipa
        XCTAssertThrowsError(try budget.extract(XCTUnwrap(archive["a"]), from: archive, to: out.appendingPathComponent("a"), root: out)) { error in
            XCTAssertTrue(error.localizedDescription.contains("damaged"), error.localizedDescription)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("a").path)
        XCTAssertLessThanOrEqual(try XCTUnwrap(attributes[.size] as? Int), 100)
    }

    func testFreeSpaceCheck() {
        XCTAssertNoThrow(try ArchiveBudget.checkFreeSpace(needed: 1000, available: 1100))
        XCTAssertThrowsError(try ArchiveBudget.checkFreeSpace(needed: 1000, available: 1099))
        XCTAssertNoThrow(try ArchiveBudget.checkFreeSpace(needed: 1000, available: nil))
        XCTAssertNoThrow(try ArchiveBudget.checkFreeSpace(needed: 1000, available: 0), "0 means unknown")
        XCTAssertThrowsError(try ArchiveBudget.checkFreeSpace(needed: .max, available: .max))
    }

    func testFileProviderDocumentGroupFollowsBundleID() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        func write(_ group: String, to folder: String) throws -> URL {
            let dir = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("Info.plist")
            try PropertyListSerialization.data(fromPropertyList: ["NSExtension": ["NSExtensionFileProviderDocumentGroup": group,
                                                                                  "NSExtensionPointIdentifier": "com.apple.fileprovider-nonui"]],
                                               format: .xml, options: 0).write(to: url)
            return url
        }
        let kept = try write("group.com.old.kept", to: "PlugIns/D.appex")
        let renamed = try write("group.com.old.shared", to: "PlugIns/A.appex")
        let exact = try write("group.com.old", to: "PlugIns/B.appex")
        let unrelated = try write("group.com.older", to: "PlugIns/C.appex")
        try Signer.rewriteExtensionKit(in: root, from: "com.old", to: "com.new", keeping: ["group.com.old.kept"])
        func group(_ url: URL) -> String? {
            ((NSDictionary(contentsOf: url)?["NSExtension"] as? [String: Any])?["NSExtensionFileProviderDocumentGroup"]) as? String
        }
        XCTAssertEqual(group(renamed), "group.com.new.shared")
        XCTAssertEqual(group(exact), "group.com.new")
        XCTAssertEqual(group(unrelated), "group.com.older")
        XCTAssertEqual(group(kept), "group.com.old.kept", "A group the profile still grants is left alone")
        XCTAssertEqual((NSDictionary(contentsOf: renamed)?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                       "com.apple.fileprovider-nonui")
    }

    func testBackupKeepsSymlinksInsideAppBundles() throws {
        let app = LibraryApp(kind: .signed, name: "Test", bundleID: "com.test", version: "1", build: "1", appFolderName: "A.app", size: 0)
        try FileManager.default.createDirectory(at: app.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.directory) }
        try Data([1]).write(to: app.directory.appendingPathComponent("target"))
        try FileManager.default.createSymbolicLink(atPath: app.directory.appendingPathComponent("link").path, withDestinationPath: "target")
        try Data([1]).write(to: app.ipaURL) // a signed app's IPA, without which it's left out
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let output = root.appendingPathComponent("backup.zip")
        try Backup.create(.init(certificates: [], sources: [], repos: [], signingDefaults: SigningOptions(), library: [app]), password: "test", to: output)
        let opened = try Backup.open(output, password: "test")
        defer { try? FileManager.default.removeItem(at: opened.folder) }
        let link = opened.folder.appendingPathComponent("Library/\(app.id.uuidString)/link")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "target")
    }

    func testBackupLeavesOutRecordsRestoreWouldRefuse() throws {
        let missing = LibraryApp(kind: .imported, name: "Missing", bundleID: "com.test.a", version: "1", build: "1", appFolderName: "A.app", size: 0)
        let unsafe = LibraryApp(kind: .signed, name: "Unsafe", bundleID: "com.test.b", version: "1", build: "1", appFolderName: "../x.app", size: 0)
        let signed = LibraryApp(kind: .signed, name: "Signed", bundleID: "com.test.c", version: "1", build: "1", appFolderName: "C.app", size: 0)
        let apps = [missing, unsafe, signed]
        for app in apps { try FileManager.default.createDirectory(at: app.directory, withIntermediateDirectories: true) }
        // Missing bundle but a surviving icon, so the directory exists.
        try Data([1]).write(to: missing.iconURL)
        try Data([1]).write(to: signed.ipaURL)
        defer { for app in apps { try? FileManager.default.removeItem(at: app.directory) } }
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let output = root.appendingPathComponent("backup.zip")
        let leftOut = try Backup.create(.init(certificates: [], sources: [], repos: [], signingDefaults: SigningOptions(), library: apps), password: "test", to: output)
        XCTAssertEqual(leftOut, ["Missing", "Unsafe"])
        let opened = try Backup.open(output, password: "test")
        defer { try? FileManager.default.removeItem(at: opened.folder) }
        // A signed app needs no Payload; the other two would be refused by restore, so they're left out.
        XCTAssertEqual(opened.manifest.library.compactMap(\.value?.id), [signed.id])
    }

    func testSignedAppWithoutPayloadValidates() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let app = LibraryApp(kind: .signed, name: "Test", bundleID: "com.test", version: "1", build: "1", appFolderName: "A.app", size: 0)
        try Data([1]).write(to: app.ipaURL(in: root)) // a signed app needs its IPA, not a Payload
        XCTAssertNoThrow(try app.validateAppFolder(in: root))
        let imported = LibraryApp(kind: .imported, name: "Test", bundleID: "com.test", version: "1", build: "1", appFolderName: "A.app", size: 0)
        XCTAssertThrowsError(try imported.validateAppFolder(in: root))
        XCTAssertNoThrow(try imported.validateAppFolder(in: root, requireBundle: false))
    }

    /// On device the temporary folder is reached through a link (/var -> /private/var); extraction must still work.
    func testExtractionThroughLinkedRootAndFrameworkSymlinks() throws {
        let real = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(real) }
        let linked = real.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: linked) }
        let zip = real.appendingPathComponent("app.ipa")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            let body = Data("binary".utf8), target = Data("A".utf8)
            try archive.addEntry(with: "Payload/X.app/Frameworks/Y.framework/Versions/A/Y", type: .file, uncompressedSize: Int64(body.count)) { position, size in
                body.subdata(in: Int(position)..<(Int(position) + size))
            }
            try archive.addEntry(with: "Payload/X.app/Frameworks/Y.framework/Versions/Current", type: .symlink, uncompressedSize: Int64(target.count)) { position, size in
                target.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        let out = linked.appendingPathComponent("out")
        try ArchiveBudget.unzip(zip, to: out)
        let current = out.appendingPathComponent("Payload/X.app/Frameworks/Y.framework/Versions/Current")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: current.path), "A")
        XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("Y")), Data("binary".utf8))
    }

    func testWritesThroughExtractedLinksCantLeaveTheRoot() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let outside = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try ArchiveBudget.checkContained(root.appendingPathComponent("escape/new/file"), in: root))
        XCTAssertThrowsError(try ArchiveBudget.checkContained(root.appendingPathComponent("../file"), in: root))
        XCTAssertNoThrow(try ArchiveBudget.checkContained(root.appendingPathComponent("a/b/c"), in: root))
    }

    func testWildcardGrantsCoverArrays() {
        let profile: [String: Any] = ["com.apple.developer.associated-domains": "*", "keychain-access-groups": "TEAM.*"]
        let custom: [String: Any] = ["com.apple.developer.associated-domains": ["applinks:example.com"],
                                     "keychain-access-groups": ["TEAM.a", "OTHER.b"]]
        XCTAssertEqual(EntitlementsMerger.ungranted(custom, profile: profile), ["keychain-access-groups"])
        // A string value is granted by an array grant containing it; "*" covers strings, not other types.
        XCTAssertEqual(EntitlementsMerger.ungranted(["aps-environment": "production", "com.apple.developer.associated-domains": ["k": "v"]],
                                                    profile: ["aps-environment": ["development", "production"],
                                                              "com.apple.developer.associated-domains": "*"]),
                       ["com.apple.developer.associated-domains"])
    }

    @MainActor
    func testDownloadKeepsItsPublishedLink() {
        let saved = UserDefaults.standard.object(forKey: DownloadPolicy.allowHTTPKey)
        UserDefaults.standard.set(false, forKey: DownloadPolicy.allowHTTPKey)
        defer { UserDefaults.standard.set(saved, forKey: DownloadPolicy.allowHTTPKey) }
        let library = LibraryStore()
        let published = URL(string: "http://127.0.0.1:9/app.ipa")!
        library.download(from: published)
        // Fetched over https (Allow HTTP is off by default), but found by the link the source published.
        let download = library.download(for: published)
        XCTAssertNotNil(download)
        if let download { library.cancel(download) }
    }

    @MainActor
    func testRestoreAddsEachSourceOnce() {
        let store = SourceStore()
        let path = "repo-\(UUID().uuidString).example/source.json"
        let plain = SavedSource(url: URL(string: "http://\(path)")!, name: "A")
        let secure = SavedSource(url: URL(string: "https://\(path)")!, name: "A")
        XCTAssertEqual(store.restore([plain, secure]), 1)
        defer { store.delete(plain.id); store.delete(secure.id) }
        XCTAssertEqual(store.restore([secure]), 0)
    }

    @MainActor
    func testRejectedSourceDoesNotBlockALaterOne() {
        let store = SourceStore()
        let existing = SavedSource(url: URL(string: "https://repo-\(UUID().uuidString).example/a.json")!, name: "A")
        XCTAssertEqual(store.restore([existing]), 1)
        defer { store.delete(existing.id) }
        let url = URL(string: "https://repo-\(UUID().uuidString).example/b.json")!
        // Same ID as an existing source (rejected), then a new ID with the same URL (should be added).
        var clash = SavedSource(url: url, name: "B")
        clash.id = existing.id
        let valid = SavedSource(url: url, name: "B")
        XCTAssertEqual(store.restore([clash, valid]), 1)
        defer { store.delete(valid.id) }
        XCTAssertTrue(store.sources.contains { $0.id == valid.id })
    }

    func testOversizedInfoPlistIsNotRead() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let plist = root.appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "A", "Padding": String(repeating: "x", count: 5 * 1024 * 1024)],
                                           format: .xml, options: 0).write(to: plist)
        XCTAssertNil(AppImporter.readPlist(plist))
        XCTAssertThrowsError(try BundleInfo(appURL: root))
        XCTAssertThrowsError(try AppImporter.validateForSigning(root))
        let link = root.appendingPathComponent("Link.plist")
        try PropertyListSerialization.data(fromPropertyList: ["A": "B"], format: .xml, options: 0).write(to: root.appendingPathComponent("Small.plist"))
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Small.plist")
        // A link inside the same bundle is followed (macOS-style frameworks); one leading out of it isn't.
        XCTAssertEqual(AppImporter.readPlist(link)?["A"] as? String, "B")
        XCTAssertNotNil(AppImporter.readPlist(root.appendingPathComponent("Small.plist")))
        let outside = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(outside) }
        try PropertyListSerialization.data(fromPropertyList: ["A": "B"], format: .xml, options: 0).write(to: outside.appendingPathComponent("Info.plist"))
        let escaping = root.appendingPathComponent("Escaping.plist")
        try FileManager.default.createSymbolicLink(at: escaping, withDestinationURL: outside.appendingPathComponent("Info.plist"))
        XCTAssertNil(AppImporter.readPlist(escaping))
    }

    func testNestedTestBundlesAreCheckedBeforeSigning() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let app = root.appendingPathComponent("A.app")
        let xctest = app.appendingPathComponent("PlugIns/T.xctest")
        try FileManager.default.createDirectory(at: xctest, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "A"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try Data([0]).write(to: app.appendingPathComponent("A"))
        // zsign signs .xctest bundles too, so an executable name leading outside one must be refused.
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "../../A"], format: .xml, options: 0)
            .write(to: xctest.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try AppImporter.validateForSigning(app)) { error in
            XCTAssertTrue(error.localizedDescription.contains("T.xctest"), error.localizedDescription)
        }
    }

    func testCertificateFilesMustBeSmallRegularFiles() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let small = root.appendingPathComponent("small"), big = root.appendingPathComponent("big"), link = root.appendingPathComponent("link")
        try Data([1]).write(to: small)
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(Backup.certificateFileLimit) + 1)
        try handle.close()
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "big")
        XCTAssertTrue(Backup.isSmallRegularFile(small))
        XCTAssertFalse(Backup.isSmallRegularFile(big))
        XCTAssertFalse(Backup.isSmallRegularFile(link), "A link to a large file doesn't pass as small")
        XCTAssertFalse(Backup.isSmallRegularFile(root.appendingPathComponent("missing")))
    }

    func testExecutableLinksMustStayInTheirBundle() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let app = root.appendingPathComponent("A.app")
        let framework = app.appendingPathComponent("Frameworks/F.framework")
        let other = app.appendingPathComponent("Frameworks/G.framework")
        for folder in [framework.appendingPathComponent("Versions/A"), other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data([0]).write(to: app.appendingPathComponent("A"))
        try Data([0]).write(to: other.appendingPathComponent("G"))
        try Data([0]).write(to: framework.appendingPathComponent("Versions/A/F"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "A"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "F"], format: .xml, options: 0)
            .write(to: framework.appendingPathComponent("Info.plist"))
        let link = framework.appendingPathComponent("F")
        // Into its own Versions folder: fine.
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Versions/A/F")
        XCTAssertNoThrow(try AppImporter.validateForSigning(app))
        // To a sibling bundle's binary: refused, though it stays inside the app.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../G.framework/G")
        XCTAssertThrowsError(try AppImporter.validateForSigning(app))
    }

    func testIPAIconsAreCheckedBeforeDecoding() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        func png(_ side: Int) -> Data {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { _ in }
        }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIconFiles": ["AppIcon"]], format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        try png(120).write(to: root.appendingPathComponent("AppIcon60x60@2x.png"))
        try png(IconImage.pixelLimit + 1).write(to: root.appendingPathComponent("AppIconHuge.png"))
        // The oversized one is skipped (not decoded), and the largest acceptable one is chosen.
        let icon = try XCTUnwrap(AppImporter.largestIcon(in: root))
        XCTAssertEqual(icon.size.width * icon.scale, 120)
    }

    func testEntitlementsFilesAreSizeLimited() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let small = root.appendingPathComponent("small.plist"), big = root.appendingPathComponent("big.plist")
        try PropertyListSerialization.data(fromPropertyList: ["get-task-allow": true], format: .xml, options: 0).write(to: small)
        XCTAssertNoThrow(try EntitlementsMerger.read(small))
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(AppImporter.plistLimit) + 1)
        try handle.close()
        XCTAssertThrowsError(try EntitlementsMerger.read(big))
        let link = root.appendingPathComponent("link.plist")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "small.plist")
        XCTAssertThrowsError(try EntitlementsMerger.read(link), "Links aren't followed")
    }

    func testCustomIconsOfAnySizeAreScaledDown() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        func image(width: Int, height: Int) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        func pixels(_ data: Data?) -> CGSize? {
            guard let data, let image = UIImage(data: data) else { return nil }
            return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        }
        // A camera-sized photo (as 1.1 stored it, and as the photo picker hands it over): kept, at icon size.
        let photo = try XCTUnwrap(image(width: 5712, height: 4284).jpegData(compressionQuality: 0.8))
        XCTAssertEqual(pixels(IconImage.normalizedCustomIcon(photo)), CGSize(width: 1024, height: 768))
        let saved = root.appendingPathComponent("custom-icon.png")
        try photo.write(to: saved)
        XCTAssertEqual(pixels(IconImage.loadCustomIcon(saved)), CGSize(width: 1024, height: 768), "A 1.1 icon still loads")
        // Small icons aren't enlarged.
        let small = try XCTUnwrap(image(width: 120, height: 120).pngData())
        XCTAssertEqual(pixels(IconImage.normalizedCustomIcon(small)), CGSize(width: 120, height: 120))
        // Not an image, a link, or absurd dimensions: nothing.
        XCTAssertNil(IconImage.normalizedCustomIcon(Data("not an image".utf8)))
        XCTAssertNil(IconImage.normalizedCustomIcon(pngHeader(width: 40_000, height: 40_000)), "Header claims 40,000 px per side")
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "custom-icon.png")
        XCTAssertNil(IconImage.loadCustomIcon(link))
    }

    /// A PNG that's only a signature, a header chunk claiming the given size, and an end chunk.
    private func pngHeader(width: UInt32, height: UInt32) -> Data {
        func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
        func chunk(_ type: String, _ body: Data) -> Data {
            let typed = Data(type.utf8) + body
            return be32(UInt32(body.count)) + typed + be32(typed.crc32(checksum: 0))
        }
        let header = be32(width) + be32(height) + Data([8, 6, 0, 0, 0])
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + chunk("IHDR", header) + chunk("IEND", Data())
    }

    @MainActor
    func testRestoreSkipsCertificatesThatFailedVerification() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        var record = CertificateRecord(nickname: "Unverified", certificateName: "C", teamName: "T", teamID: "T",
                                       profileName: "P", applicationIdentifier: "T.*", creationDate: Date(),
                                       expirationDate: Date(), provisionedDeviceCount: nil, provisionsAllDevices: false,
                                       entitlements: [:], certificateMatchesProfile: true)
        record.id = UUID()
        let staged = root.appendingPathComponent("Certificates/\(record.id.uuidString)")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data([1]).write(to: staged.appendingPathComponent(record.p12URL.lastPathComponent))
        try Data([1]).write(to: staged.appendingPathComponent(record.profileURL.lastPathComponent))
        let manifest = Backup.Manifest(version: 1, created: Date(), certificates: [.init(value: record)],
                                       passwords: .init(salt: Data(), iterations: 1, sealed: Data()), sources: [], repos: [], library: [])
        // Files and password present, but `open` didn't verify them (verifiedCertificates is empty).
        let opened = Backup.Opened(manifest: manifest, passwords: [record.id: "pw"], folder: root)
        let certificates = CertificateStore()
        let summary = Backup.apply(opened, certificates: certificates, library: LibraryStore(), sources: SourceStore(), github: GitHubStore())
        XCTAssertEqual(summary.certificates, 0)
        XCTAssertTrue(summary.skipped.contains { $0.contains("unreadable") }, "\(summary.skipped)")
        XCTAssertNil(certificates.certificate(record.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.directory.path))
    }

    func testLibraryThumbnailsAreHeaderChecked() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let huge = root.appendingPathComponent("huge.png")
        try UIGraphicsImageRenderer(size: CGSize(width: IconImage.pixelLimit + 1, height: 8), format: format).pngData { _ in }.write(to: huge)
        XCTAssertNil(IconImage.acceptableWidth(of: huge), "Too many pixels to decode, however small the file")
    }

    func testCertificateThatRestoreWouldRefuseFailsTheBackup() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        var record = CertificateRecord(nickname: "Big", certificateName: "Big", teamName: "T", teamID: "T",
                                       profileName: "P", applicationIdentifier: "T.*", creationDate: Date(),
                                       expirationDate: Date(), provisionedDeviceCount: nil, provisionsAllDevices: false,
                                       entitlements: [:], certificateMatchesProfile: nil)
        record.id = UUID()
        try FileManager.default.createDirectory(at: record.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: record.directory) }
        try Data([1]).write(to: record.p12URL)
        FileManager.default.createFile(atPath: record.profileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: record.profileURL)
        try handle.truncate(atOffset: UInt64(Backup.certificateFileLimit) + 1)
        try handle.close()
        let output = root.appendingPathComponent("backup.zip")
        XCTAssertThrowsError(try Backup.create(.init(certificates: [record], sources: [], repos: [], signingDefaults: SigningOptions(), library: []),
                                               password: "test", to: output, readPassword: { _ in "pw" })) { error in
            XCTAssertTrue(error.localizedDescription.contains("too large"), error.localizedDescription)
        }
    }

    func testFlatStringListsOnlyMatchPatterns() {
        XCTAssertEqual(EntitlementsMerger.ungranted(["com.apple.developer.associated-domains": [["applinks:a.com"]]],
                                                    profile: ["com.apple.developer.associated-domains": "*"]),
                       ["com.apple.developer.associated-domains"])
        XCTAssertEqual(EntitlementsMerger.ungranted(["keychain-access-groups": [["TEAM.a"]]],
                                                    profile: ["keychain-access-groups": ["TEAM.*"]]),
                       ["keychain-access-groups"])
    }

    func testBackupRestoresReadOnlyFolders() throws {
        let app = LibraryApp(kind: .imported, name: "ReadOnly", bundleID: "com.test.ro", version: "1", build: "1", appFolderName: "A.app", size: 0)
        let folder = app.appURL.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: app.directory)
        }
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let output = root.appendingPathComponent("backup.zip")
        XCTAssertEqual(try Backup.create(.init(certificates: [], sources: [], repos: [], signingDefaults: SigningOptions(), library: [app]), password: "test", to: output), [])
        let opened = try Backup.open(output, password: "test")
        defer { try? FileManager.default.removeItem(at: opened.folder) }
        let restored = opened.folder.appendingPathComponent("Library/\(app.id.uuidString)/Payload/A.app/Locked/file")
        XCTAssertEqual(try Data(contentsOf: restored), Data("x".utf8))
    }

    func testSignedRecordWithoutItsIPAIsLeftOut() throws {
        let app = LibraryApp(kind: .signed, name: "NoIPA", bundleID: "com.test.noipa", version: "1", build: "1", appFolderName: "A.app", size: 0)
        try FileManager.default.createDirectory(at: app.directory, withIntermediateDirectories: true)
        try Data([1]).write(to: app.iconURL)
        defer { try? FileManager.default.removeItem(at: app.directory) }
        XCTAssertThrowsError(try app.validateAppFolder(in: app.directory))
        XCTAssertNoThrow(try app.validateAppFolder(in: app.directory, requireBundle: false))
        try Data([1]).write(to: app.ipaURL)
        XCTAssertNoThrow(try app.validateAppFolder(in: app.directory))
    }

    func testBackupRestoresEmptyFolders() throws {
        let app = LibraryApp(kind: .imported, name: "Empty", bundleID: "com.test.empty", version: "1", build: "1", appFolderName: "A.app", size: 0)
        try FileManager.default.createDirectory(at: app.appURL.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.directory) }
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let output = root.appendingPathComponent("backup.zip")
        XCTAssertEqual(try Backup.create(.init(certificates: [], sources: [], repos: [], signingDefaults: SigningOptions(), library: [app]), password: "test", to: output), [])
        let opened = try Backup.open(output, password: "test")
        defer { try? FileManager.default.removeItem(at: opened.folder) }
        let staged = opened.folder.appendingPathComponent("Library/\(app.id.uuidString)")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Payload/A.app/Empty").path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertNoThrow(try app.validateAppFolder(in: staged))
    }

    func testHTTPOverride() {
        let plain = URL(string: "http://repo.example/source.json")!
        XCTAssertFalse(DownloadPolicy.allows(plain, http: false))
        XCTAssertTrue(DownloadPolicy.allows(plain, http: true))
        XCTAssertFalse(DownloadPolicy.allows(URL(string: "file:///tmp/a")!, http: true))
        XCTAssertFalse(DownloadPolicy.allows(URL(string: "http://user:pass@repo.example/a")!, http: true))
        XCTAssertEqual(DownloadPolicy.resolved(plain, http: false), URL(string: "https://repo.example/source.json")!)
        XCTAssertEqual(DownloadPolicy.resolved(plain, http: true), plain)
    }

    func testLegacyHTTPLinksUpgrade() {
        XCTAssertEqual(DownloadPolicy.upgraded(URL(string: "http://repo.example:80/source.json")!), URL(string: "https://repo.example/source.json")!)
        XCTAssertEqual(DownloadPolicy.upgraded(URL(string: "https://repo.example/a")!), URL(string: "https://repo.example/a")!)
        XCTAssertEqual(DownloadPolicy.upgraded(URL(string: "file:///tmp/a")!), URL(string: "file:///tmp/a")!)
    }

    @MainActor
    func testRestoreRejectsUnsafeAppRecordBeforeMovingItsDirectory() async throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let app = LibraryApp(kind: .imported, name: "Test", bundleID: "com.test", version: "1", build: "1", appFolderName: "../../outside.app", size: 0)
        let staged = root.appendingPathComponent("Library/\(app.id.uuidString)")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let manifest = Backup.Manifest(version: 1, created: Date(), certificates: [], passwords: .init(salt: Data(), iterations: 1, sealed: Data()), sources: [], repos: [], library: [.init(value: app)])
        let opened = Backup.Opened(manifest: manifest, passwords: [:], folder: root)
        let library = LibraryStore()
        let summary = Backup.apply(opened, certificates: CertificateStore(), library: library, sources: SourceStore(), github: GitHubStore())
        XCTAssertEqual(summary.apps, 0)
        XCTAssertEqual(summary.skipped.count, 1)
        XCTAssertNil(library.app(app.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Restore discards its staging directory after rejecting the record")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.directory.path))
    }

    func testOversizedExtensionMetadataFailsBeforeDecoding() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        try Data(repeating: 65, count: 4 * 1024 * 1024 + 1).write(to: root.appendingPathComponent("Test.appexpt"))
        XCTAssertThrowsError(try Signer.rewriteExtensionKit(in: root, from: "com.old", to: "com.new")) { error in
            XCTAssertTrue(error.localizedDescription.contains("size limit"))
        }
    }

    func testSymlinkWithDishonestLocalSizeIsRejectedBeforeExtraction() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let zip = root.appendingPathComponent("link.zip")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            let data = Data("target".utf8)
            try archive.addEntry(with: "link", type: .symlink, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        var bytes = try Data(contentsOf: zip)
        // Local compressed size = 2 GiB; central directory still claims a six-byte symlink.
        bytes.replaceSubrange(18..<22, with: [0, 0, 0, 128])
        try bytes.write(to: zip)
        let archive = try Archive(url: zip, accessMode: .read)
        // Check the reason, so a reflection failure ("Couldn't check…") can't pass for the size check.
        XCTAssertThrowsError(try ArchiveBudget.ipa.validate(archive)) { error in
            XCTAssertTrue(error.localizedDescription.contains("oversized"), error.localizedDescription)
        }
        var budget = ArchiveBudget.ipa
        XCTAssertThrowsError(try budget.extract(XCTUnwrap(archive["link"]), from: archive,
                                               to: root.appendingPathComponent("link"), root: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("oversized"), error.localizedDescription)
        }
    }

    func testSymlinkLocalSizeMustMatchItsDeclaredSize() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let zip = root.appendingPathComponent("link.zip")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            let data = Data("target".utf8)
            try archive.addEntry(with: "link", type: .symlink, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        var bytes = try Data(contentsOf: zip)
        // Local compressed size 3 (small, so within the link limit) against a declared 6.
        bytes.replaceSubrange(18..<22, with: [3, 0, 0, 0])
        try bytes.write(to: zip)
        let archive = try Archive(url: zip, accessMode: .read)
        XCTAssertThrowsError(try ArchiveBudget.ipa.validate(archive)) { error in
            XCTAssertTrue(error.localizedDescription.contains("damaged"), error.localizedDescription)
        }
    }

    /// A minimal ZIP64 archive (sizes and offset only in ZIP64 extra fields, ZIP64 end records), built by hand to
    /// put chosen values in the fields ZIPFoundation does arithmetic on.
    private func zip64Archive(name: String = "Payload/X.app/X", body: Data = Data("zip64 body".utf8),
                              localOffset: UInt64? = nil, flags: UInt16 = 0, size: UInt64? = nil,
                              prefixLength: Int = 4) -> Data {
        let declared = size ?? UInt64(body.count)
        // Bytes before the local header, so tests can choose a zero or non-zero ZIP64 offset.
        let prefix = Data(count: prefixLength)
        let localOffset = localOffset ?? UInt64(prefix.count)
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let nameData = Data(name.utf8)
        let crc = body.crc32(checksum: 0)
        var out = prefix
        // Local header with a ZIP64 extra (uncompressed, compressed).
        out += le32(0x0403_4b50) + le16(45) + le16(flags) + le16(0) + le16(0) + le16(0x21) + le32(crc)
        out += le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF) + le16(UInt16(nameData.count)) + le16(20)
        out += nameData + le16(0x0001) + le16(16) + le64(declared) + le64(declared) + body
        // Bit 3: a ZIP64 data descriptor follows the data (signature, CRC, compressed, uncompressed).
        if flags & 0x08 != 0 { out += le32(0x0807_4b50) + le32(crc) + le64(declared) + le64(declared) }
        // Central directory record with a ZIP64 extra (uncompressed, compressed, local offset).
        let directoryOffset = UInt64(out.count)
        var central = Data()
        central += le32(0x0201_4b50) + le16(0x031E) + le16(45) + le16(flags) + le16(0) + le16(0) + le16(0x21) + le32(crc)
        central += le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF) + le16(UInt16(nameData.count)) + le16(28) + le16(0)
        central += le16(0) + le16(0) + le32(UInt32(0o100644) << 16) + le32(0xFFFF_FFFF)
        central += nameData + le16(0x0001) + le16(24) + le64(declared) + le64(declared) + le64(localOffset)
        out += central
        // ZIP64 end of central directory, its locator, then the classic record pointing at them.
        let recordOffset = UInt64(out.count)
        out += le32(0x0606_4b50) + le64(44) + le16(45) + le16(45) + le32(0) + le32(0)
        out += le64(1) + le64(1) + le64(UInt64(central.count)) + le64(directoryOffset)
        out += le32(0x0706_4b50) + le32(0) + le64(recordOffset) + le32(1)
        out += le32(0x0605_4b50) + le16(0) + le16(0) + le16(0xFFFF) + le16(0xFFFF) + le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF) + le16(0)
        return out
    }

    /// `zip -fz -r` of Payload/X.app/X ("zip64 body"), by Info-ZIP 3.0: ZIP64 end records, and ZIP64 extra fields
    /// that give folders a 0xFFFFFFFF size as ZIPFoundation reads them.
    private static let infoZIP64 = "UEsDBC0AAAAAANJpdF0AAAAA//////////8IADAAUGF5bG9hZC9VVAkAA7xHAGu8RwBrdXgLAAEE9QEAAAQAAAAAAQAQAAAAAAAAAAAAAAAAAAAAAABQSwMELQAAAAAA0ml0XQAAAAD//////////w4AMABQYXlsb2FkL1guYXBwL1VUCQADvEcAa7xHAGt1eAsAAQT1AQAABAAAAAABABAAAAAAAAAAAAAAAAAAAAAAAFBLAwQtAAAAAADSaXRdMfUEMf//////////DwAwAFBheWxvYWQvWC5hcHAvWFVUCQADvEcAa7xHAGt1eAsAAQT1AQAABAAAAAABABAACgAAAAAAAAAKAAAAAAAAAHppcDY0IGJvZHlQSwECHgMKAAAAAADSaXRdAAAAAAAAAAD/////CAAkAAAAAAAAABAA7UEAAAAAUGF5bG9hZC9VVAUAA7xHAGt1eAsAAQT1AQAABAAAAAABAAgAAAAAAAAAAABQSwECHgMKAAAAAADSaXRdAAAAAAAAAAD/////DgAkAAAAAAAAABAA7UFWAAAAUGF5bG9hZC9YLmFwcC9VVAUAA7xHAGt1eAsAAQT1AQAABAAAAAABAAgAAAAAAAAAAABQSwECHgMtAAAAAADSaXRdMfUEMQoAAAD/////DwAkAAAAAAABAAAApIGyAAAAUGF5bG9hZC9YLmFwcC9YVVQFAAO8RwBrdXgLAAEE9QEAAAQAAAAAAQAIAAoAAAAAAAAAUEsGBiwAAAAAAAAAHgMtAAAAAAAAAAAAAwAAAAAAAAADAAAAAAAAABsBAAAAAAAAGQEAAAAAAABQSwYHAAAAADQCAAAAAAAAAQAAAFBLBQYAAAAAAwADABsBAAD/////AAA="

    func testZIP64ArchivesPassThePreflightAndExtract() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let zip = root.appendingPathComponent("zip64.ipa")
        try XCTUnwrap(Data(base64Encoded: Self.infoZIP64)).write(to: zip)
        let archive = try Archive(url: zip, accessMode: .read)
        XCTAssertEqual(archive.declaredEntryCount, 3)
        // Folders count as empty, not as the 4 GiB ZIPFoundation reports for them here.
        XCTAssertEqual(try ArchiveBudget.ipa.validate(archive), 10)
        let out = root.appendingPathComponent("out")
        try ArchiveBudget.unzip(zip, to: out)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("Payload/X.app/X")), Data("zip64 body".utf8))
    }

    /// The vendored ZIPFoundation's checked arithmetic (Vendor/ZIPFoundation/PATCHES.md): these values used to trap.
    /// Reaching the assertions at all means the app would no longer crash.
    func testOverflowingArchiveValuesFailInsteadOfCrashing() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        // Local-header offsets past Int64.max (readStruct's off_t) and near UInt64.max (dataOffset's sum).
        for offset: UInt64 in [.max - 10, UInt64(Int64.max) + 1, 1 << 40] {
            let zip = root.appendingPathComponent("offset-\(offset).ipa")
            try zip64Archive(localOffset: offset).write(to: zip)
            XCTAssertThrowsError(try ArchiveBudget.unzip(zip, to: root.appendingPathComponent("out-\(offset)")), "\(offset)")
        }
        // A stored entry with a data descriptor: readable with an honest size, so only the size below differs.
        let honest = root.appendingPathComponent("descriptor-honest.ipa")
        try zip64Archive(flags: 0x08).write(to: honest)
        try ArchiveBudget.unzip(honest, to: root.appendingPathComponent("out-honest"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("out-honest/Payload/X.app/X")), Data("zip64 body".utf8))
        // A size that overflows the descriptor position (offset + header + name + extra + size).
        let zip = root.appendingPathComponent("descriptor.ipa")
        try zip64Archive(flags: 0x08, size: .max - 40).write(to: zip)
        XCTAssertThrowsError(try ArchiveBudget.unzip(zip, to: root.appendingPathComponent("out-descriptor"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("damaged"), error.localizedDescription)
        }
    }

    func testHandBuiltZIP64ArchiveExtracts() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let zip = root.appendingPathComponent("zip64.ipa")
        try zip64Archive().write(to: zip)
        try ArchiveBudget.unzip(zip, to: root.appendingPathComponent("out"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("out/Payload/X.app/X")), Data("zip64 body".utf8))
    }

    /// Vendored patch 8: a ZIP64 value of 0 is used when the classic field says to look there.
    func testZeroValuedZIP64FieldsAreRead() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        // First entry at offset 0, with that offset given in the ZIP64 extra field.
        let first = root.appendingPathComponent("first.ipa")
        try zip64Archive(prefixLength: 0).write(to: first)
        try ArchiveBudget.unzip(first, to: root.appendingPathComponent("out-first"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("out-first/Payload/X.app/X")), Data("zip64 body".utf8))
        // An empty file whose ZIP64 sizes are 0: charged nothing, extracted empty.
        let empty = root.appendingPathComponent("empty.ipa")
        try zip64Archive(body: Data()).write(to: empty)
        let archive = try Archive(url: empty, accessMode: .read)
        let entry = try XCTUnwrap(archive["Payload/X.app/X"])
        XCTAssertEqual(entry.compressedSize, 0, "effectiveCompressedSize takes the ZIP64 zero")
        XCTAssertEqual(entry.uncompressedSize, 0)
        XCTAssertEqual(try ArchiveBudget.ipa.validate(archive), 0)
        try ArchiveBudget.unzip(empty, to: root.appendingPathComponent("out-empty"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("out-empty/Payload/X.app/X")), Data())
    }

    /// Vendored patch 9: a streamed entry whose central record uses ZIP64 only for its offset (past 4 GiB in real
    /// archives) has a 32-bit data descriptor, which used to be read as 64-bit and turned its sizes into garbage.
    func testOffsetOnlyZIP64EntryWith32BitDescriptorExtracts() throws {
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let name = Data("Payload/X.app/X".utf8), body = Data("streamed body".utf8), crc = body.crc32(checksum: 0)
        var out = Data(count: 4)
        let localOffset = UInt64(out.count)
        // Local header: bit 3 set, sizes 0, no extra field; then the data and a 32-bit descriptor.
        out += le32(0x0403_4b50) + le16(20) + le16(0x08) + le16(0) + le16(0) + le16(0x21) + le32(0) + le32(0) + le32(0)
        out += le16(UInt16(name.count)) + le16(0) + name + body
        out += le32(0x0807_4b50) + le32(crc) + le32(UInt32(body.count)) + le32(UInt32(body.count))
        // Central record: real sizes, offset 0xFFFFFFFF with the offset in a ZIP64 extra (offset only).
        let directoryOffset = UInt32(out.count)
        var central = le32(0x0201_4b50) + le16(0x031E) + le16(45) + le16(0x08) + le16(0) + le16(0) + le16(0x21) + le32(crc)
        central += le32(UInt32(body.count)) + le32(UInt32(body.count)) + le16(UInt16(name.count)) + le16(12) + le16(0)
        central += le16(0) + le16(0) + le32(UInt32(0o100644) << 16) + le32(0xFFFF_FFFF)
        central += name + le16(0x0001) + le16(8) + le64(localOffset)
        out += central
        out += le32(0x0605_4b50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(UInt32(central.count)) + le32(directoryOffset) + le16(0)

        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let zip = root.appendingPathComponent("streamed.ipa")
        try out.write(to: zip)
        let archive = try Archive(url: zip, accessMode: .read)
        XCTAssertEqual(archive["Payload/X.app/X"]?.uncompressedSize, UInt64(body.count))
        try ArchiveBudget.unzip(zip, to: root.appendingPathComponent("out"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("out/Payload/X.app/X")), body)
    }

    func testClassicCountOf65535IsCheckedToo() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let zip = root.appendingPathComponent("two.zip")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            for name in ["a", "b"] {
                let body = Data(name.utf8)
                try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(body.count)) { position, size in
                    body.subdata(in: Int(position)..<(Int(position) + size))
                }
            }
        }
        var bytes = try Data(contentsOf: zip)
        // Claim 65,535 entries (0xFFFF, with no ZIP64 record): the iterator stops after the real two.
        try patch(&bytes, signature: [0x50, 0x4b, 0x05, 0x06], occurrence: 0, offset: 8, with: [0xFF, 0xFF, 0xFF, 0xFF])
        try bytes.write(to: zip)
        let archive = try Archive(url: zip, accessMode: .read)
        XCTAssertEqual(archive.declaredEntryCount, 65_535)
        XCTAssertThrowsError(try ArchiveBudget.ipa.validate(archive)) { error in
            XCTAssertTrue(error.localizedDescription.contains("damaged"), error.localizedDescription)
        }
    }

    func testArchiveWithoutAnEndRecordFailsQuickly() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let zip = root.appendingPathComponent("cut.ipa")
        // 8 MiB with no end record, like an interrupted download; the search used to read it byte by byte.
        try Data(count: 8 * 1024 * 1024).write(to: zip)
        let start = Date()
        XCTAssertThrowsError(try ArchiveBudget.unzip(zip, to: root.appendingPathComponent("out")))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testArchiveBudgetsRejectEntryCountAndSize() throws {
        let root = try Paths.newTempDirectory()
        defer { Paths.removeIfTemporary(root) }
        let archive = try Archive(url: root.appendingPathComponent("test.zip"), accessMode: .create)
        let bytes = Data(repeating: 65, count: 1024)
        try archive.addEntry(with: "a", type: .file, uncompressedSize: Int64(1024), compressionMethod: .deflate) { position, size in
            bytes.subdata(in: Int(position)..<(Int(position) + size))
        }
        XCTAssertThrowsError(try ArchiveBudget(remaining: 100, perEntry: 2000, entries: 10).validate(archive))
        XCTAssertThrowsError(try ArchiveBudget(remaining: 2000, perEntry: 100, entries: 10).validate(archive))
        XCTAssertThrowsError(try ArchiveBudget(remaining: 2000, perEntry: 2000, entries: 0).validate(archive))
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Bypassing preflight must still enforce the byte budget while streaming.
        var budget = ArchiveBudget(remaining: 100, perEntry: 2000, entries: 10)
        XCTAssertThrowsError(try budget.extract(XCTUnwrap(archive["a"]), from: archive, to: out.appendingPathComponent("a"), root: out))
    }
}
