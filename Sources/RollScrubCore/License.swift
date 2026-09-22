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
    public static let purchaseURL = URL(string: "https://rollscrub.com/#pricing")!

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

    public static var isActivated: Bool {
        stored() != nil
    }

    /// True when removal is unlocked. An activated licence that has not been
    /// re-checked inside the grace window still counts, because the failure
    /// mode of being wrong here is taking away something already bought.
    public static func isPro(now: Date = Date()) -> Bool {
        guard let state = stored() else { return false }
        guard let validated = state.lastValidated else { return true }
        return now.timeIntervalSince(validated) < offlineGrace
    }

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
            // have forgotten this licence while the request was in flight.
            // Writing unconditionally would resurrect it for another day.
            guard stored() != nil else { return }
            state.lastValidated = Date()
            try? store(state)
        case .refused:
            // Refunded, revoked, or this Mac's activation removed elsewhere.
            forget()
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
