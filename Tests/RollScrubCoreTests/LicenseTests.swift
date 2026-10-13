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

    /// Buy has to land on `/buy`, the route that counts the click and
    /// redirects to checkout. Anywhere else on the site and the buyer needs a
    /// second click to reach checkout, and the stats page never hears about
    /// it. The `ref` values must match the ones `buySource` in
    /// worker/index.js accepts, or every click is filed as "site".
    func testBuyGoesStraightToCheckoutAndSaysWhereItCameFrom() {
        let app = URLComponents(url: License.purchaseURL(from: .app), resolvingAgainstBaseURL: false)
        let cli = URLComponents(url: License.purchaseURL(from: .cli), resolvingAgainstBaseURL: false)

        XCTAssertEqual(app?.host, "rollscrub.com")
        XCTAssertEqual(app?.path, "/buy")
        XCTAssertEqual(app?.queryItems, [URLQueryItem(name: "ref", value: "app")])
        XCTAssertEqual(cli?.path, "/buy")
        XCTAssertEqual(cli?.queryItems, [URLQueryItem(name: "ref", value: "cli")])
    }
}

/// Which licence a re-check's reply is about. The keychain can change while
/// the request is in flight, and acting on the wrong licence either deletes
/// one somebody just paid for or writes a stale one back over it.
final class LicenseReplacementTests: XCTestCase {

    private func state(_ key: String, _ instance: String) -> License.State {
        License.State(key: key, instanceID: instance, lastValidated: nil)
    }

    /// The everyday case: the reply is about the licence on this Mac, so a
    /// refusal must still revoke it. If this failed, refunds would never lock.
    func testActsOnAReplyAboutTheLicenceStillStored() {
        let s = state("K", "inst_1")
        XCTAssertTrue(License.isStillStored(s, current: s))
    }

    /// A re-check of the old activation lands after the person deactivated
    /// and activated another key. Acting on it would delete the fresh licence
    /// on a refusal, or write the stale one back over it on a confirmation.
    func testIgnoresAReplyAboutAnActivationThatHasSinceBeenReplaced() {
        XCTAssertFalse(License.isStillStored(state("K", "inst_1"), current: state("K", "inst_2")))
    }

    /// Same instance id under a different key is a different licence, however
    /// unlikely, and must not be treated as the one that was checked.
    func testIgnoresAReplyWhenTheKeyHasChanged() {
        XCTAssertFalse(License.isStillStored(state("K", "inst_1"), current: state("J", "inst_1")))
    }

    /// Deactivated while the check was in flight: a confirmation arriving now
    /// would bring the licence back for another day.
    func testIgnoresAReplyAfterTheLicenceWasRemoved() {
        XCTAssertFalse(License.isStillStored(state("K", "inst_1"), current: nil))
    }
}

/// When an open window sends its automatic re-check. The window wakes every
/// hour; these walk those wakes with an injected clock.
final class LicenseAutomaticCheckTests: XCTestCase {

    private let hour: TimeInterval = 60 * 60
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// The hours after `t0` at which a request goes out, recording an attempt
    /// only then, as `LicenseModel.revalidateQuietly` does.
    private func wakesThatSend(_ state: License.State, lastAttempt: Date?, hours: Int) -> [Int] {
        var lastAttempt = lastAttempt
        var sent: [Int] = []
        for h in 1...hours {
            let now = t0.addingTimeInterval(Double(h) * hour)
            guard License.automaticCheckIsDue(state, lastAttempt: lastAttempt, now: now) else {
                continue
            }
            // A wake that claims the day's attempt while the licence is not
            // due sends nothing, and that is how the check slipped to 46h.
            XCTAssertTrue(License.shouldRecheck(state, now: now), "attempt spent at hour \(h)")
            lastAttempt = now
            sent.append(h)
        }
        return sent
    }

    /// A window left open after a successful check must ask again about a day
    /// later. If this slips, a refunded licence keeps removing files for an
    /// extra day in any session that is never relaunched.
    func testAnOpenWindowChecksAgainADayAfterASuccessNotTwo() {
        // Confirmed a couple of seconds after the attempt began, as in life.
        let state = License.State(
            key: "K", instanceID: "inst_1", lastValidated: t0.addingTimeInterval(2))
        XCTAssertEqual(wakesThatSend(state, lastAttempt: t0, hours: 40), [25])
    }

    /// The server is unreachable, so the licence stays due on every wake. The
    /// proxy forwards to an API we are billed on and rate limited by: an open
    /// window must not call it every hour for as long as the outage lasts.
    func testAnUnreachableServerIsAskedOnceADayNotEveryHour() {
        let stale = License.State(
            key: "K", instanceID: "inst_1", lastValidated: t0.addingTimeInterval(-3 * 24 * hour))
        XCTAssertEqual(wakesThatSend(stale, lastAttempt: t0, hours: 50), [24, 48])
    }

    /// Launch: nothing has been attempted yet in this process, so a licence
    /// that is due is checked at once rather than a day into the session.
    func testTheFirstCheckAfterLaunchIsNotHeldBack() {
        let stale = License.State(
            key: "K", instanceID: "inst_1", lastValidated: t0.addingTimeInterval(-2 * 24 * hour))
        XCTAssertTrue(License.automaticCheckIsDue(stale, lastAttempt: nil, now: t0))
    }

    /// Launch with a licence confirmed an hour ago. Saying yes here records an
    /// attempt for a request `revalidate()` then declines to send, and the
    /// real check slips a day, on every launch.
    func testAFreshLicenceIsNotCheckedAtLaunch() {
        let fresh = License.State(
            key: "K", instanceID: "inst_1", lastValidated: t0.addingTimeInterval(-hour))
        XCTAssertFalse(License.automaticCheckIsDue(fresh, lastAttempt: nil, now: t0))
    }

    /// The clock was wrong when the last attempt was recorded, so that attempt
    /// now sits in the future. Waiting for the clock to catch up could park a
    /// due licence for as long as the clock was off by.
    func testAnAttemptRecordedInTheFutureDoesNotHoldACheckBack() {
        let stale = License.State(
            key: "K", instanceID: "inst_1", lastValidated: t0.addingTimeInterval(-2 * 24 * hour))
        let future = t0.addingTimeInterval(400 * 24 * hour)
        XCTAssertTrue(License.automaticCheckIsDue(stale, lastAttempt: future, now: t0))
    }
}

/// Reading the keychain. "Would not answer" and "nothing there" used to be
/// the same value, and the difference is a customer's activation slot.
final class LicenseStandingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 60 * 60 * 24

    private func licence(validatedDaysAgo days: Double?) -> License.Reading {
        .licence(License.State(
            key: "K", instanceID: "inst_1",
            lastValidated: days.map { now.addingTimeInterval(-$0 * day) }))
    }

    private func data(_ state: License.State) throws -> Data {
        try JSONEncoder().encode(state)
    }

    /// Only "item not found" means no licence. If a locked keychain or a
    /// refused permission prompt read as absent, a paying customer would be
    /// shown Buy and a key field, and pasting the key takes a second slot.
    func testAKeychainThatWouldNotAnswerIsNotAMacWithNoLicence() {
        XCTAssertEqual(License.reading(status: errSecItemNotFound, data: nil), .absent)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled,
                       errSecNotAvailable, errSecIO] {
            XCTAssertEqual(License.reading(status: status, data: nil), .unreadable, "\(status)")
        }
    }

    /// The ordinary read. If this broke, nobody's licence would be found.
    func testAStoredLicenceIsRead() throws {
        let state = License.State(key: "K", instanceID: "inst_1", lastValidated: now)
        XCTAssertEqual(
            License.reading(status: errSecSuccess, data: try data(state)), .licence(state))
    }

    /// An item that cannot be decoded can never work again. Calling it
    /// unreadable would leave its owner at a window with no key field, with
    /// no way back in but an email.
    func testACorruptItemIsTreatedAsNoLicenceSoAKeyCanBeEntered() {
        XCTAssertEqual(
            License.reading(status: errSecSuccess, data: Data("not json".utf8)), .absent)
    }

    /// The four answers the window and the CLI branch on. `unreadable` must
    /// never fall into `unlicensed`, which is the layout with the key field,
    /// and it must never unlock removal either.
    func testStandingKeepsUnreadableApartFromUnlicensed() {
        func standing(_ reading: License.Reading) -> License.Standing {
            License.standing(reading, now: now, developerUnlocked: false)
        }
        XCTAssertEqual(standing(.absent), .unlicensed)
        XCTAssertEqual(standing(.unreadable), .unreadable)
        XCTAssertEqual(standing(licence(validatedDaysAgo: 1)), .licensed)
        XCTAssertEqual(standing(licence(validatedDaysAgo: nil)), .licensed)
        XCTAssertEqual(standing(licence(validatedDaysAgo: 31)), .needsRecheck)

        XCTAssertFalse(License.Standing.unreadable.unlocksRemoval)
        XCTAssertFalse(License.Standing.needsRecheck.unlocksRemoval)
        XCTAssertFalse(License.Standing.unlicensed.unlocksRemoval)
        XCTAssertFalse(License.Standing.unreadable.hasLicence)
    }

    /// A real licence is never reported as the developer unlock, or a debug
    /// build would hide the Deactivate button from someone who holds one.
    func testDeveloperUnlockDoesNotMaskARealLicence() {
        XCTAssertEqual(
            License.standing(licence(validatedDaysAgo: 1), now: now, developerUnlocked: true),
            .licensed)
        XCTAssertEqual(
            License.standing(.absent, now: now, developerUnlocked: true), .developerUnlocked)
    }

    /// Mid-session, a read that fails after one that found a licence changes
    /// nothing: the customer was licensed a moment ago and a keychain hiccup
    /// is not evidence otherwise. Without this, Remove locks at random.
    func testAFailedReadDoesNotUndoALicenceAlreadySeen() {
        XCTAssertEqual(License.settled(.unreadable, after: .licensed), .licensed)
        XCTAssertEqual(License.settled(.unreadable, after: .needsRecheck), .needsRecheck)
    }

    /// The opposite direction is not carried over. "No licence" followed by a
    /// read that fails means something may be stored now, and keeping the Buy
    /// layout would put the key field over it.
    func testAFailedReadIsNotPaperedOverWithAnEarlierNoLicence() {
        XCTAssertEqual(License.settled(.unreadable, after: .unlicensed), .unreadable)
        XCTAssertEqual(License.settled(.unreadable, after: nil), .unreadable)
        XCTAssertEqual(License.settled(.unreadable, after: .developerUnlocked), .unreadable)
    }

    /// A read that works always wins, in both directions: a lapse must lock
    /// and a fresh activation must unlock.
    func testAReadThatAnswersReplacesWhatWasBelieved() {
        XCTAssertEqual(License.settled(.unlicensed, after: .licensed), .unlicensed)
        XCTAssertEqual(License.settled(.needsRecheck, after: .licensed), .needsRecheck)
        XCTAssertEqual(License.settled(.licensed, after: .unreadable), .licensed)
    }
}

/// Deactivating, and what a failed check says to the person who ran it.
final class LicenseOutcomeTests: XCTestCase {

    /// Offline, or the server could not say. Forgetting the licence here
    /// leaves the activation on Creem with nothing on this Mac that knows its
    /// instance id, so the slot is lost for good while the window claims it
    /// was freed.
    func testDeactivatingWithoutAReleaseKeepsTheLicence() {
        XCTAssertEqual(License.deactivation(nil), .unreachable)
        XCTAssertEqual(License.deactivation(.cannotTell), .notReleased)
    }

    /// The Worker refuses a deactivation before removing anything, when it
    /// does not recognise the key as ours. For a key that activated here that
    /// is the Worker misreading a reply, and forgetting on it would drop the
    /// licence from this Mac while its slot stays taken.
    func testARefusedDeactivationKeepsTheLicenceBecauseNothingWasReleased() {
        XCTAssertEqual(License.deactivation(.refused("different product")), .notReleased)
    }

    /// Only a released slot removes the licence, and then it must: otherwise
    /// a Mac being sold could never be signed out.
    func testOnlyAReleasedSlotRemovesTheLicence() {
        XCTAssertEqual(License.deactivation(.ok(instanceID: nil)), .removed)
        XCTAssertNil(License.DeactivationOutcome.removed.explanation)
    }

    /// Both ways of failing say the licence is still here, and only the one
    /// with no reply blames the connection.
    func testAFailedDeactivationSaysTheLicenceIsStillActive() throws {
        let unreachable = try XCTUnwrap(License.DeactivationOutcome.unreachable.explanation)
        let notReleased = try XCTUnwrap(License.DeactivationOutcome.notReleased.explanation)
        XCTAssertTrue(unreachable.contains("Could not reach"))
        XCTAssertFalse(notReleased.contains("Could not reach"))
        for message in [unreachable, notReleased] {
            XCTAssertTrue(message.contains("still active here"))
        }
    }

    /// "Could not reach the server" sends people to check a connection that
    /// works. When the server did answer, the message has to say the fault is
    /// ours, and neither message may suggest the licence is gone.
    func testAFailedCheckSaysWhetherTheServerWasReached() throws {
        let unreachable = try XCTUnwrap(License.RecheckOutcome.unreachable.explanation)
        let noVerdict = try XCTUnwrap(License.RecheckOutcome.noVerdict.explanation)
        XCTAssertNotEqual(unreachable, noVerdict)
        XCTAssertTrue(unreachable.contains("Could not reach"))
        XCTAssertFalse(noVerdict.contains("Could not reach"))
        for message in [unreachable, noVerdict] {
            XCTAssertTrue(message.contains("still saved on this Mac"))
        }
    }

    /// A refusal removes the licence, and the window then offers Buy. Without
    /// the reason, someone whose key was deactivated from another Mac sees a
    /// purchase screen and nothing else.
    func testARevokedLicenceExplainsItselfAndCarriesTheServersReason() throws {
        let message = try XCTUnwrap(
            License.RecheckOutcome.revoked(reason: "This licence was refunded.").explanation)
        XCTAssertTrue(message.contains("has been removed"))
        XCTAssertTrue(message.contains("This licence was refunded."))
        XCTAssertNil(License.RecheckOutcome.confirmed.explanation)
        XCTAssertNil(License.RecheckOutcome.notNeeded.explanation)
    }
}
