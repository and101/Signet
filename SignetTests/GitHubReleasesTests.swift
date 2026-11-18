import XCTest
@testable import Signet

final class GitHubReleasesTests: XCTestCase {
    /// Trimmed from a real `GET /repos/utmapp/UTM/releases` response.
    private let releasesJSON = #"""
    [
      {
        "id": 449734595, "tag_name": "v5.0.9-2", "name": "v5.0.9", "draft": false, "prerelease": false,
        "published_at": "2026-11-18T09:03:04Z", "html_url": "https://github.com/utmapp/UTM/releases/tag/v5.0.9-2",
        "body": "Notes", "author": {"login": "osy"},
        "assets": [
          {"id": 762893604, "name": "UTM-SE.ipa", "size": 237418770, "content_type": "application/octet-stream",
           "browser_download_url": "https://github.com/utmapp/UTM/releases/download/v5.0.9-2/UTM-SE.ipa"},
          {"id": 762916296, "name": "UTM.dmg", "size": 304699821, "content_type": "application/octet-stream",
           "browser_download_url": "https://github.com/utmapp/UTM/releases/download/v5.0.9-2/UTM.dmg"},
          {"id": 762886493, "name": "UTM.ipa", "size": 150730029, "content_type": "application/octet-stream",
           "browser_download_url": "https://github.com/utmapp/UTM/releases/download/v5.0.9-2/UTM.ipa"}
        ]
      },
      {
        "id": 447515343, "tag_name": "v5.0.9", "name": "v5.0.9", "draft": false, "prerelease": false,
        "published_at": "2026-11-16T19:46:15Z", "html_url": "https://github.com/utmapp/UTM/releases/tag/v5.0.9",
        "body": null,
        "assets": [
          {"id": 756409373, "name": "UTM.ipa", "size": 150730050, "content_type": "application/octet-stream",
           "browser_download_url": "https://github.com/utmapp/UTM/releases/download/v5.0.9/UTM.ipa"}
        ]
      },
      {"id": "malformed"}
    ]
    """#

    private func release(_ tag: String, daysAgo: Double, prerelease: Bool = false, assets: [String]) -> GitHubRelease {
        GitHubRelease(
            id: tag.hashValue, tagName: tag, name: nil, body: nil, draft: false, prerelease: prerelease,
            publishedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400), htmlUrl: nil,
            assets: assets.enumerated().map { index, name in
                GitHubAsset(id: index, name: name, size: 1,
                            browserDownloadUrl: URL(string: "https://github.com/o/r/releases/download/\(tag)/\(name)")!)
            }
        )
    }

    func testParsesRepositoryInput() {
        let expected = ("utmapp", "UTM")
        for input in [
            "utmapp/UTM",
            " utmapp/UTM ",
            "github.com/utmapp/UTM",
            "https://github.com/utmapp/UTM",
            "https://github.com/utmapp/UTM.git",
            "https://github.com/utmapp/UTM/releases/latest",
            "https://www.github.com/utmapp/UTM?tab=readme",
            "git@github.com:utmapp/UTM.git",
        ] {
            let parsed = GitHub.parseRepository(input)
            XCTAssertEqual(parsed?.owner, expected.0, input)
            XCTAssertEqual(parsed?.name, expected.1, input)
        }
        XCTAssertNil(GitHub.parseRepository("utmapp"))
        XCTAssertNil(GitHub.parseRepository("https://gitlab.com/utmapp/UTM"))
        XCTAssertNil(GitHub.parseRepository("owner/re po"))
    }

    func testRecognizesReleaseDownloadURLs() {
        let parsed = GitHub.repository(ofDownloadURL: "https://github.com/utmapp/UTM/releases/download/v5.0.9/UTM.ipa")
        XCTAssertEqual(parsed?.owner, "utmapp")
        XCTAssertEqual(parsed?.name, "UTM")
        XCTAssertNil(GitHub.repository(ofDownloadURL: "https://github.com/utmapp/UTM/archive/v5.0.9.zip"))
        XCTAssertNil(GitHub.repository(ofDownloadURL: "https://example.com/utmapp/UTM/releases/download/v1/a.ipa"))
    }

    func testDecodesReleasesAndPicksTheChosenIPA() throws {
        let releases = try GitHub.decodeReleases(Data(releasesJSON.utf8))
        XCTAssertEqual(releases.map(\.tagName), ["v5.0.9-2", "v5.0.9"], "the malformed entry is skipped")
        XCTAssertEqual(releases[0].ipaAssets.map(\.name), ["UTM-SE.ipa", "UTM.ipa"])

        var repo = TrackedRepo(owner: "utmapp", name: "UTM")
        XCTAssertEqual(GitHub.latest(in: releases, for: repo)?.asset.name, "UTM-SE.ipa", "first IPA without a preference")

        repo.assetName = "utm.ipa"
        let latest = try XCTUnwrap(GitHub.latest(in: releases, for: repo))
        XCTAssertEqual(latest.release.tagName, "v5.0.9-2")
        XCTAssertEqual(latest.asset.browserDownloadUrl.absoluteString,
                       "https://github.com/utmapp/UTM/releases/download/v5.0.9-2/UTM.ipa")

        // A preference nothing matches must not fall back to a different app.
        repo.assetName = "UTM-Remote.ipa"
        XCTAssertNil(GitHub.latest(in: releases, for: repo))
    }

    func testMatchesAssetsRenamedEachVersion() {
        let releases = [
            release("v2.0", daysAgo: 1, assets: ["MyApp_v2.0.ipa", "MyApp-Lite_v2.0.ipa"]),
            release("v1.0", daysAgo: 9, assets: ["MyApp_v1.0.ipa"]),
        ]
        var repo = TrackedRepo(owner: "o", name: "r")
        repo.assetName = "MyApp_v1.0.ipa"
        XCTAssertEqual(GitHub.latest(in: releases, for: repo)?.asset.name, "MyApp_v2.0.ipa")
    }

    func testSkipsPrereleasesAndReleasesWithoutIPAs() {
        let releases = [
            release("v3.0-beta", daysAgo: 1, prerelease: true, assets: ["App.ipa"]),
            release("v2.1", daysAgo: 2, assets: ["App.dmg"]),
            release("v2.0", daysAgo: 5, assets: ["App.ipa"]),
        ]
        var repo = TrackedRepo(owner: "o", name: "r")
        XCTAssertEqual(GitHub.visibleReleases(releases, for: repo).map(\.tagName), ["v2.0"])
        XCTAssertEqual(GitHub.latest(in: releases, for: repo)?.release.tagName, "v2.0")

        repo.includePrereleases = true
        XCTAssertEqual(GitHub.latest(in: releases, for: repo)?.release.tagName, "v3.0-beta")
    }

    func testSigningDefaultsOnlyApplyToTheFollowedIPA() {
        var repo = TrackedRepo(owner: "utmapp", name: "UTM")
        let utm = "https://github.com/utmapp/UTM/releases/download/v5.0.9/UTM.ipa"
        let se = "https://github.com/utmapp/UTM/releases/download/v5.0.9/UTM-SE.ipa"
        XCTAssertTrue(GitHub.isDownload(utm, from: repo))
        XCTAssertTrue(GitHub.isDownload(se, from: repo), "every IPA counts until one is chosen")
        XCTAssertTrue(GitHub.isDownload("https://GITHUB.com/UTMapp/utm/releases/download/v1/UTM.ipa", from: repo))
        XCTAssertFalse(GitHub.isDownload("https://github.com/other/UTM/releases/download/v1/UTM.ipa", from: repo))

        repo.assetName = "UTM.ipa"
        XCTAssertTrue(GitHub.isDownload(utm, from: repo))
        XCTAssertFalse(GitHub.isDownload(se, from: repo))
    }

    func testUpdateStateRemembersDownloadsThatLeftTheLibrary() {
        let old = URL(string: "https://github.com/o/r/releases/download/v1/App.ipa")!
        let new = URL(string: "https://github.com/o/r/releases/download/v2/App.ipa")!

        XCTAssertEqual(GitHub.updateState(latest: nil, lastDownloaded: old, inLibrary: false, hasOlderInLibrary: true), .noIPA)
        XCTAssertEqual(GitHub.updateState(latest: new, lastDownloaded: nil, inLibrary: false, hasOlderInLibrary: false), .notDownloaded)
        XCTAssertEqual(GitHub.updateState(latest: new, lastDownloaded: nil, inLibrary: false, hasOlderInLibrary: true), .updateAvailable)
        XCTAssertEqual(GitHub.updateState(latest: new, lastDownloaded: nil, inLibrary: true, hasOlderInLibrary: true), .upToDate)
        // The old IPA was deleted after installing: the new release is still an update.
        XCTAssertEqual(GitHub.updateState(latest: new, lastDownloaded: old, inLibrary: false, hasOlderInLibrary: false), .updateAvailable)
        // The new IPA was downloaded, then deleted: nothing new.
        XCTAssertEqual(GitHub.updateState(latest: new, lastDownloaded: new, inLibrary: false, hasOlderInLibrary: false), .upToDate)
    }

    func testAutoDownloadFetchesEachReleaseOnce() {
        let old = URL(string: "https://github.com/o/r/releases/download/v1/App.ipa")!
        let new = URL(string: "https://github.com/o/r/releases/download/v2/App.ipa")!
        var repo = TrackedRepo(owner: "o", name: "r")
        XCTAssertFalse(GitHub.shouldAutoDownload(repo, latest: new, inLibrary: false), "off by default")

        repo.autoDownload = true
        XCTAssertTrue(GitHub.shouldAutoDownload(repo, latest: new, inLibrary: false))
        XCTAssertFalse(GitHub.shouldAutoDownload(repo, latest: new, inLibrary: true))
        XCTAssertFalse(GitHub.shouldAutoDownload(repo, latest: nil, inLibrary: false))

        repo.lastDownloadedURL = new // downloaded, then deleted or failed
        XCTAssertFalse(GitHub.shouldAutoDownload(repo, latest: new, inLibrary: false))
        repo.lastDownloadedURL = old
        XCTAssertTrue(GitHub.shouldAutoDownload(repo, latest: new, inLibrary: false))
        // A failed download isn't retried automatically; a newer release is.
        repo.failedDownloadURL = new
        XCTAssertFalse(GitHub.shouldAutoDownload(repo, latest: new, inLibrary: false))
        let newer = URL(string: "https://github.com/o/r/releases/download/v3/App.ipa")!
        XCTAssertTrue(GitHub.shouldAutoDownload(repo, latest: newer, inLibrary: false))
    }

    func testReleaseCacheRoundTripsThroughDefaultCoders() throws {
        let releases = try GitHub.decodeReleases(Data(releasesJSON.utf8))
        let caches = [UUID(): GitHubReleaseCache(releases: releases, etag: #"W/"abc""#, checkedAt: Date())]
        let decoded = try JSONDecoder().decode([UUID: GitHubReleaseCache].self, from: JSONEncoder().encode(caches))
        XCTAssertEqual(decoded.keys.first, caches.keys.first)
        XCTAssertEqual(decoded.values.first?.releases, releases)
        XCTAssertEqual(decoded.values.first?.etag, #"W/"abc""#)
    }

    func testGenericRepoNamesDisplayTheOwner() {
        XCTAssertEqual(TrackedRepo(owner: "NeoFreeBird", name: "app").displayName, "NeoFreeBird")
        XCTAssertEqual(TrackedRepo(owner: "acme", name: "iOS").displayName, "acme")
        XCTAssertEqual(TrackedRepo(owner: "utmapp", name: "UTM").displayName, "UTM")
    }

    func testTrackedRepoDecodesWithMissingOptionalFields() throws {
        let id = UUID()
        let json = #"{"id": "\#(id.uuidString)", "owner": "o", "name": "r"}"#
        let repo = try JSONDecoder().decode(TrackedRepo.self, from: Data(json.utf8))
        XCTAssertEqual(repo.id, id)
        XCTAssertFalse(repo.autoDownload)
        XCTAssertFalse(repo.includePrereleases)
        XCTAssertNil(repo.defaultBundleID)

        var edited = repo
        edited.bundleID = "  com.example.app "
        edited.certificateID = UUID()
        let roundTripped = try JSONDecoder().decode(TrackedRepo.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(roundTripped, edited)
        XCTAssertEqual(roundTripped.defaultBundleID, "com.example.app")
    }
}
