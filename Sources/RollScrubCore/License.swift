import Foundation
import Security

/// Lemon Squeezy licensing.
///
/// The design goal is that a network problem never costs someone the use of
/// software they paid for. An activated licence keeps working offline, and only
/// an explicit "this key is no longer valid" answer from the server — not a
/// timeout, not a 500, not a missing Wi-Fi connection — ever revokes it.
public enum License {

    /// Removing files is the paid action. Scanning, reviewing and the reports
    /// are free forever, so anyone can see exactly what RollScrub found before
    /// deciding whether it is worth paying for.
    public static let purchaseURL = URL(string: "https://rollscrub.com/#pricing")!

    /// The Lemon Squeezy product these keys must belong to.
    ///
    /// The licence API answers for the whole platform, not for one store: it
    /// will happily confirm that someone else's $3 key is valid. Without this
    /// check, any key bought from any seller on Lemon Squeezy would unlock
    /// RollScrub.
    static let productID = 1_358_068

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

    // MARK: - Activation

    public static func activate(key raw: String, deviceName: String) async throws -> State {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ActivationError.empty }

        let body = [
            "license_key": key,
            "instance_name": deviceName,
        ]
        let json = try await post("activate", body)

        guard let activated = json["activated"] as? Bool, activated else {
            throw ActivationError.refused(
                (json["error"] as? String) ?? "That licence key was not accepted.")
        }
        guard let instance = json["instance"] as? [String: Any],
              let id = instance["id"] as? String
        else {
            throw ActivationError.refused("The licence server sent an unexpected reply.")
        }

        // Checked after activating rather than before, so the happy path stays
        // one round trip — but the instance we just created on someone else's
        // licence is released again, rather than silently eating one of their
        // activations because they mistyped a key here.
        guard isOurs(json) else {
            _ = try? await post("deactivate", ["license_key": key, "instance_id": id])
            throw ActivationError.refused(
                "That key is for a different product, not RollScrub.")
        }

        let state = State(key: key, instanceID: id, lastValidated: Date())
        try store(state)
        return state
    }

    /// Re-checks in the background. Silent on success, and silent on failure
    /// too unless the server positively says the key is no longer valid.
    public static func revalidate() async {
        guard var state = stored() else { return }

        let json: [String: Any]
        do {
            json = try await post("validate", [
                "license_key": state.key,
                "instance_id": state.instanceID,
            ])
        } catch {
            return  // unreachable: the grace window covers this
        }

        if let valid = json["valid"] as? Bool, valid {
            // Re-checked on every validation, not just at activation: a key
            // stored by an older build that lacked this check should stop
            // unlocking removal the first time it is re-examined.
            guard isOurs(json) else { forget(); return }
            state.lastValidated = Date()
            try? store(state)
        } else if json["error"] != nil {
            // An explicit refusal — refunded, revoked, or deactivated elsewhere.
            forget()
        }
    }

    public static func deactivate() async {
        guard let state = stored() else { return }
        _ = try? await post("deactivate", [
            "license_key": state.key,
            "instance_id": state.instanceID,
        ])
        forget()
    }

    /// Whether a licence-API reply describes a key for this product.
    ///
    /// Absent or unparseable metadata counts as "not ours". The server always
    /// sends it, so its absence means something other than Lemon Squeezy
    /// answered — which is exactly when refusing is the safe direction.
    static func isOurs(_ json: [String: Any]) -> Bool {
        guard let meta = json["meta"] as? [String: Any],
              let product = meta["product_id"] as? Int
        else { return false }
        return product == productID
    }

    // MARK: - Transport

    private static func post(_ path: String, _ fields: [String: String]) async throws
        -> [String: Any]
    {
        var request = URLRequest(
            url: URL(string: "https://api.lemonsqueezy.com/v1/licenses/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = fields
            .map { "\($0.key)=\(urlEncoded($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw ActivationError.unreachable
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ActivationError.refused("The licence server sent an unexpected reply.")
        }
        return json
    }

    private static func urlEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
