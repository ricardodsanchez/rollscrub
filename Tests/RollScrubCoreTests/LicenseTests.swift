import XCTest

@testable import RollScrubCore

/// The licence Worker answers in exactly three words, and this file is about
/// keeping them apart. `refused` deletes a licence from the keychain;
/// `cannotTell` must do nothing whatsoever. Confusing the second for the first
/// takes the paid feature away from somebody who bought it, on the strength of
/// a bad network — which is the failure this whole design exists to prevent.
final class LicenseTests: XCTestCase {

    func testAcceptsAnActivationThatCarriesAnInstanceID() {
        XCTAssertEqual(
            License.verdict(from: ["verdict": "ok", "instance_id": "inst_1"]),
            .ok(instanceID: "inst_1"))
    }

    /// Activation needs somewhere to record which slot this Mac took. Reading
    /// a missing id as a successful activation would store a licence whose
    /// every later re-check is unanswerable.
    func testReportsAnActivationWithNoInstanceIDAsSuchRatherThanInventingOne() {
        XCTAssertEqual(License.verdict(from: ["verdict": "ok"]), .ok(instanceID: nil))
    }

    func testPassesTheServersReasonThroughSoThePersonReadsWhyItWasRefused() {
        XCTAssertEqual(
            License.verdict(from: ["verdict": "refused", "reason": "That licence is expired."]),
            .refused("That licence is expired."))
    }

    func testStillRefusesWhenTheServerGaveNoReason() {
        XCTAssertEqual(
            License.verdict(from: ["verdict": "refused"]),
            .refused("That licence key was not accepted."))
    }

    /// The Worker returns an error *body* on its failure statuses — a rotated
    /// Creem API key, a missing binding, Creem itself down. Those say nothing
    /// about the customer, and reading the word "error" as a refusal would
    /// revoke every licence in the field the first time each copy re-checked.
    func testTreatsAnErrorReplyAsNoAnswerRatherThanAsARefusal() {
        XCTAssertEqual(License.verdict(from: ["verdict": "error", "reason": "nope"]), .cannotTell)
        XCTAssertEqual(License.verdict(from: ["error": "Forbidden", "status": 403]), .cannotTell)
    }

    /// A captive portal, a hijacked DNS answer, or an ISP interstitial returns
    /// something that parses as JSON and means nothing. Doing nothing is the
    /// only safe reading: the worst case is re-checking again later.
    func testTreatsAnUnrecognisedReplyAsNoAnswer() {
        XCTAssertEqual(License.verdict(from: [:]), .cannotTell)
        XCTAssertEqual(License.verdict(from: ["verdict": "maybe"]), .cannotTell)
        XCTAssertEqual(License.verdict(from: ["verdict": 1]), .cannotTell)
    }

    /// Belongs to the old Lemon Squeezy vocabulary, where a bare `valid: true`
    /// unlocked the app. Nothing should honour it now: it is the shape a
    /// forged reply would take if someone read a shipped copy's old code.
    func testDoesNotHonourTheOldLemonSqueezyVocabulary() {
        XCTAssertEqual(License.verdict(from: ["valid": true]), .cannotTell)
        XCTAssertEqual(
            License.verdict(from: ["activated": true, "instance": ["id": "x"]]), .cannotTell)
    }
}

/// When the app is willing to spend a network round trip — and somebody
/// else's rate limit — to re-confirm a licence it already believes in.
final class LicenseRecheckTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func state(validated: Date?) -> License.State {
        License.State(key: "K", instanceID: "inst_1", lastValidated: validated)
    }

    /// Opening the app twenty times in an afternoon must not be twenty calls
    /// to Creem. The licence is already good for another month.
    func testDoesNotRecheckALicenceConfirmedAnHourAgo() {
        XCTAssertFalse(
            License.shouldRecheck(state(validated: epoch.addingTimeInterval(-3600)), now: epoch))
    }

    /// A refund has to be noticed reasonably soon, or the refund policy is
    /// unenforceable.
    func testRechecksALicenceConfirmedMoreThanADayAgo() {
        XCTAssertTrue(
            License.shouldRecheck(
                state(validated: epoch.addingTimeInterval(-60 * 60 * 25)), now: epoch))
    }

    /// A clock that jumped backwards — a timezone correction, a dead battery,
    /// a restored backup — would otherwise leave a licence parked forever in
    /// a state that never re-checks, and it would then expire silently when
    /// the grace window ran out.
    func testRechecksWhenTheClockHasGoneBackwards() {
        XCTAssertTrue(
            License.shouldRecheck(
                state(validated: epoch.addingTimeInterval(60 * 60 * 24 * 365)), now: epoch))
    }

    func testRechecksALicenceThatHasNeverBeenConfirmed() {
        XCTAssertTrue(License.shouldRecheck(state(validated: nil), now: epoch))
    }

    // MARK: - Developer unlock

    // These two reach for `developerUnlockVariable` and `developerUnlock(in:)`,
    // which only exist when DEBUG is defined. `swift test` builds in debug, so
    // an unguarded reference compiles today and would stop the *whole* target
    // — all 77 tests — from building the first time anyone runs the suite in
    // release configuration.
    #if DEBUG

    /// The unlock exists so the paid path can be exercised without a real key.
    /// If it ever read as "on" for anything but the exact opt-in, every debug
    /// build would quietly be a Pro build — and a developer would stop seeing
    /// the locked app that customers actually get.
    func testTheDeveloperUnlockNeedsTheExactOptIn() {
        XCTAssertTrue(License.developerUnlock(in: ["ROLLSCRUB_DEVELOPER_UNLOCK": "1"]))

        XCTAssertFalse(License.developerUnlock(in: [:]))
        XCTAssertFalse(License.developerUnlock(in: ["ROLLSCRUB_DEVELOPER_UNLOCK": ""]))
        XCTAssertFalse(License.developerUnlock(in: ["ROLLSCRUB_DEVELOPER_UNLOCK": "0"]))
        XCTAssertFalse(License.developerUnlock(in: ["ROLLSCRUB_DEVELOPER_UNLOCK": "true"]))
        XCTAssertFalse(License.developerUnlock(in: ["ROLLSCRUB_DEVELOPER_UNLOCK": " 1"]))
    }

    /// The name is what `release.sh` greps the shipped binary for. Changing it
    /// in one place and not the other would leave a check that always passes.
    func testTheUnlockVariableIsTheNameTheReleaseCheckLooksFor() {
        XCTAssertEqual(License.developerUnlockVariable, "ROLLSCRUB_DEVELOPER_UNLOCK")
    }

    #endif

    /// `swift test` builds in debug, so the unlock is compiled into this very
    /// run. A suite that happened to run unlocked would assert nothing about
    /// the gate it is here to protect.
    func testTheSuiteIsNotItselfRunningUnlocked() {
        XCTAssertFalse(
            License.isDeveloperUnlocked,
            "ROLLSCRUB_DEVELOPER_UNLOCK is set in this shell — unset it before running tests")
    }
}
