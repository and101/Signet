import XCTest
@testable import Signet

final class KeychainTests: XCTestCase {
    func testSetReplacesAndDeleteRemoves() throws {
        let account = UUID().uuidString
        defer { Keychain.delete(account) }
        XCTAssertNil(Keychain.get(account))

        try Keychain.set("first", for: account)
        XCTAssertEqual(Keychain.get(account), "first")
        try Keychain.set("second", for: account)
        XCTAssertEqual(Keychain.get(account), "second")

        Keychain.delete(account)
        XCTAssertNil(Keychain.get(account))
    }
}
