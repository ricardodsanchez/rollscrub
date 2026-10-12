import Foundation
import Security

/// Licensing, through Creem.
///
/// The design goal is that a network problem never costs someone the use of
/// software they paid for. An activated licence keeps working offline, and only
/// an explicit "this key is no longer valid" answer from the server — not a
/// timeout, not a 500, not a missing Wi-Fi connection — ever revokes it.
///
/// The app does not talk to Creem directly. Creem's licence endpoints
/// authenticate with a store-wide secret that cannot ship inside a
/// downloadable binary, so `worker/license.js` on rollscrub.com holds the key
/// and answers in its own small vocabulary. That Worker also decides whether a
/// key belongs to this product — a check that used to live here, where a
/// patched binary could simply skip it.
public enum License {

    /// Removing files is the paid action. Scanning, reviewing and the reports
    /// are free forever, so anyone can see exactly what RollScrub found before
    /// deciding whether it is worth paying for.
    ///
    /// Both the app and the CLI send people to `/buy`, which counts the click
    /// and redirects straight to checkout. They used to send them to the
    /// site's pricing section, which meant a second Buy click on the way to
    /// checkout, and every in-app click was counted as a site click.
    /// `ref` is what lets the stats page tell the three apart; the Worker
    /// only accepts the values `PurchaseEntry` spells.
    public enum PurchaseEntry: String {
        case app, cli
    }

    public static func purchaseURL(from entry: PurchaseEntry) -> URL {
        URL(string: "https://rollscrub.com/buy?ref=\(entry.rawValue)")!
    }

    /// Shown in the unlock window. Has to match the Creem product, and a
    /// price change needs a release to reach it.
    public static let displayPrice = "$19"

    static let endpoint = URL(string: "https://rollscrub.com/license/")!

    public struct State: Codable, Equatable, Sendable {
        public var key: String
        public var instanceID: String
        /// Last time the server confirmed this key. Nil means never reached.
        public var lastValidated: Date?
    }

    public enum ActivationError: LocalizedError {
        case empty
        case refused(String)
        case unreachable

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter the licence key from your purchase email."
            case .refused(let reason):
                return reason
            case .unreachable:
                return "Could not reach the licence server. Check your connection and try again."
            }
        }
    }

    // MARK: - Status

    /// How long an activated licence keeps working without a successful check.
    ///
    /// Generous on purpose: laptops go offline for weeks, and someone who paid
    /// should not be locked out of their own files by a flaky airport network.
    static let offlineGrace: TimeInterval = 60 * 60 * 24 * 30

    /// How long a confirmation is good for before the app asks again.
    ///
    /// The re-check exists to notice a refund or a revocation, and a day is
    /// soon enough for that. Asking on every launch instead would put a
    /// third-party API in the path of opening the app dozens of times a day,
    /// for a licence we already believe in for another month — spending
    /// somebody else's rate limit, and our money, to learn nothing.
    static let recheckInterval: TimeInterval = 60 * 60 * 24

    /// Whether a stored licence is due to be confirmed again.
    static func shouldRecheck(_ state: State, now: Date = Date()) -> Bool {
        guard let validated = state.lastValidated else { return true }
        // A clock that has gone backwards — a timezone fix, a dead battery —
        // must not park a licence in a state that never re-checks again.
        return !(0..<recheckInterval).contains(now.timeIntervalSince(validated))
    }

    /// Whether the app's automatic check should send a request now.
    ///
    /// Two things have to be true. The licence must be due (`shouldRecheck`),
    /// and the last attempt must be at least a day old. The second is what
    /// stops an open window from calling every hour while the server is
    /// unreachable, since a failed check leaves the licence due.
    ///
    /// The caller records an attempt only when this says yes. Recording one
    /// for a wake on which the licence was not yet due spends the day's
    /// attempt on nothing, and the next real check lands two days out.
    static func automaticCheckIsDue(_ state: State, lastAttempt: Date?, now: Date) -> Bool {
        guard shouldRecheck(state, now: now) else { return false }
        guard let lastAttempt else { return true }
        // A clock that has gone backwards counts as due, as in `shouldRecheck`.
        return !(0..<recheckInterval).contains(now.timeIntervalSince(lastAttempt))
    }

    public static func automaticCheckIsDue(lastAttempt: Date?, now: Date = Date()) -> Bool {
        guard let state = stored() else { return false }
        return automaticCheckIsDue(state, lastAttempt: lastAttempt, now: now)
    }

    public static var isActivated: Bool {
        stored() != nil
    }

    /// True when removal is unlocked. An activated licence that has not been
    /// re-checked inside the grace window still counts, because the failure
    /// mode of being wrong here is taking away something already bought.
    public static func isPro(now: Date = Date()) -> Bool {
        if isDeveloperUnlocked { return true }
        guard let state = stored() else { return false }
        guard let validated = state.lastValidated else { return true }
        return now.timeIntervalSince(validated) < offlineGrace
    }

    // MARK: - Developer unlock

    /// Unlocks removal in a **debug build** when `ROLLSCRUB_DEVELOPER_UNLOCK=1`
    /// is set, so the paid path can be worked on without spending a real key.
    ///
    /// Always false in a release build: `swift build -c release` does not
    /// define `DEBUG`, so the lookup below — and the variable's name with it —
    /// is not compiled at all. `release.sh` then greps the built binary for
    /// that name and refuses to ship if it is there, because a release that
    /// carried this would hand the paid feature to everybody, and would look
    /// no different from a correct one.
    ///
    /// It deliberately writes nothing to the keychain. A forged stored licence
    /// would outlive the debug build that made it, would read as genuine in
    /// the UI, and `revalidate()` would ask Creem about a key that does not
    /// exist — whose answer is a refusal, which deletes licences.
    public static var isDeveloperUnlocked: Bool {
        #if DEBUG
        return developerUnlock(in: ProcessInfo.processInfo.environment)
        #else
        return false
        #endif
    }

    /// What to tell the developer, naming the variable so they can unset it.
    ///
    /// Lives here rather than in the view because the variable's name is one
    /// of the strings that must not reach a release binary — `release.sh`
    /// greps for it — so every mention of it belongs behind the same `#if`.
    public static var developerUnlockNotice: String {
        #if DEBUG
        return "Removal is unlocked because \(developerUnlockVariable) is set. "
            + "No licence is stored, and a release build ignores it entirely."
        #else
        return ""
        #endif
    }

    #if DEBUG
    static let developerUnlockVariable = "ROLLSCRUB_DEVELOPER_UNLOCK"

    /// Split from the environment lookup so the rule can be tested without
    /// mutating the test process's own environment.
    ///
    /// Exactly `"1"`, and nothing else. `swift test` runs in debug too, so a
    /// lenient reading here — anything non-empty, say — would risk the whole
    /// suite running unlocked and never again seeing what a customer sees.
    static func developerUnlock(in environment: [String: String]) -> Bool {
        environment[developerUnlockVariable] == "1"
    }
    #endif

    // MARK: - What the server told us

    /// The three things a reply can mean.
    ///
    /// Modelled as a type rather than read out of a status code at each call
    /// site, because the whole correctness of this file is the difference
    /// between `refused` and `cannotTell`: the first may revoke a licence, and
    /// the second must never do anything at all.
    enum Verdict: Equatable {
        case ok(instanceID: String?)
        case refused(String)
        case cannotTell
    }

    /// Reads a reply from the licence Worker.
    ///
    /// Anything unrecognised is `cannotTell`. A captive portal, a hijacked DNS
    /// answer or a future version of the Worker all produce JSON that parses
    /// and means nothing; treating that as a refusal would delete a paying
    /// customer's licence on a hotel network.
    static func verdict(from json: [String: Any]) -> Verdict {
        switch json["verdict"] as? String {
        case "ok":
            return .ok(instanceID: json["instance_id"] as? String)
        case "refused":
            return .refused(
                (json["reason"] as? String) ?? "That licence key was not accepted.")
        default:
            return .cannotTell
        }
    }

    // MARK: - Which licence a reply is about

    /// Whether the licence a request was about is still the one stored.
    ///
    /// A re-check can take up to twenty seconds, and in that time the person
    /// may activate a different key or deactivate. A reply that lands
    /// afterwards describes a licence that is no longer here: acting on it
    /// would either delete the new one (on a refusal) or write the old one
    /// back over it (on a confirmation). So it changes nothing.
    static func isStillStored(_ checked: State, current: State?) -> Bool {
        guard let current else { return false }
        return current.key == checked.key && current.instanceID == checked.instanceID
    }

    // MARK: - Activation

    public static func activate(key raw: String, deviceName: String) async throws -> State {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ActivationError.empty }

        let json = try await post("activate", [
            "key": key,
            "instance_name": deviceName,
        ])

        switch verdict(from: json) {
        case .ok(let instanceID):
            guard let instanceID else {
                throw ActivationError.refused("The licence server sent an unexpected reply.")
            }
            let state = State(key: key, instanceID: instanceID, lastValidated: Date())
            try store(state)
            return state
        case .refused(let reason):
            throw ActivationError.refused(reason)
        case .cannotTell:
            throw ActivationError.unreachable
        }
    }

    /// Re-checks in the background. Silent on success, and silent on failure
    /// too unless the server positively says the key is no longer valid.
    public static func revalidate(now: Date = Date()) async {
        guard var state = stored() else { return }
        guard shouldRecheck(state, now: now) else { return }

        let json: [String: Any]
        do {
            json = try await post("validate", [
                "key": state.key,
                "instance_id": state.instanceID,
            ])
        } catch {
            return  // unreachable: the grace window covers this
        }

        switch verdict(from: json) {
        case .ok:
            // Another copy of the app, or the person hitting Deactivate, may
            // have forgotten this licence while the request was in flight, or
            // replaced it with a new activation. Writing unconditionally would
            // resurrect the old one, or overwrite the new one with it.
            guard isStillStored(state, current: stored()) else { return }
            state.lastValidated = Date()
            try? store(state)
        case .refused:
            // Refunded, revoked, or this Mac's activation removed elsewhere.
            // Only if it is still the licence that was asked about: a key
            // activated while this request was in flight is not the one refused.
            if isStillStored(state, current: stored()) { forget() }
        case .cannotTell:
            break  // change nothing
        }
    }

    public static func deactivate() async {
        guard let state = stored() else { return }
        _ = try? await post("deactivate", [
            "key": state.key,
            "instance_id": state.instanceID,
        ])
        forget()
    }

    // MARK: - Transport

    private static func post(_ path: String, _ fields: [String: String]) async throws
        -> [String: Any]
    {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try? JSONSerialization.data(withJSONObject: fields)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw ActivationError.unreachable
        }

        // The Worker sends its verdict in the body on every path, including
        // its error statuses, so the status code is deliberately not consulted
        // here — `verdict(from:)` is the single place that decides meaning.
        // Unreachable, not refused. A captive portal or an ISP interstitial
        // answers with HTML, and calling that a refusal would be one edit away
        // from a hotel network deleting a licence: `revalidate()` happens to
        // swallow every thrown error today, but the label is what a later
        // reader will trust.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ActivationError.unreachable
        }
        return json
    }

    // MARK: - Keychain

    // The keychain rather than UserDefaults: a licence key is the customer's
    // property and is worth the same protection as a password. The CLI reads
    // the same item, so activating in the app licenses both.
    private static let account = "com.rollscrub.license"
    private static let service = "RollScrub"

    static func store(_ state: State) throws {
        let data = try JSONEncoder().encode(state)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ActivationError.refused("Could not save the licence to your keychain.")
        }
    }

    static func stored() -> State? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    public static func forget() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
