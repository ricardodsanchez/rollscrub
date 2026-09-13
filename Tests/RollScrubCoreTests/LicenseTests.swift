import XCTest

@testable import RollScrubCore

/// The licence API answers for every seller on Lemon Squeezy, so "this key is
/// valid" is not the same question as "this key is for RollScrub". These cover
/// the second one, which is the only thing standing between a stranger's $3
/// key and a free copy of the paid feature.
final class LicenseTests: XCTestCase {

    private func reply(productID: Any?) -> [String: Any] {
        var meta: [String: Any] = ["store_id": 42, "product_name": "Something"]
        if let productID { meta["product_id"] = productID }
        return ["valid": true, "meta": meta]
    }

    func testAcceptsAKeyForThisProduct() {
        XCTAssertTrue(License.isOurs(reply(productID: License.productID)))
    }

    func testRejectsAValidKeyForSomebodyElsesProduct() {
        XCTAssertFalse(License.isOurs(reply(productID: License.productID + 1)))
    }

    func testRejectsAReplyWithNoProductMetadata() {
        XCTAssertFalse(License.isOurs(reply(productID: nil)))
        XCTAssertFalse(License.isOurs(["valid": true]))
    }

    /// A captive portal or a hijacked DNS answer returns something that parses
    /// as JSON but carries no metadata. Refusing is the safe direction: the
    /// worst case is asking someone to activate again on a real network.
    func testRejectsAReplyThatIsNotFromTheLicenceServer() {
        XCTAssertFalse(License.isOurs(["meta": "not an object"]))
        XCTAssertFalse(License.isOurs(reply(productID: "1358068")))
    }
}
