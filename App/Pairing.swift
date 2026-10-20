import Foundation
import Security

/// What the PC's pairing QR code contains: where to reach it, its certificate pin, and this phone's token.
/// Stored in the Keychain (this device only, never in backups).
struct Pairing: Codable {
    var hosts: [String]
    var port: Int
    var fingerprint: String
    var token: String
    var pcName: String

    /// Parses celloai://pair?h=..&p=..&fp=..&t=..&n=..; nil if anything is off.
    static func parse(_ text: String) -> Pairing? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "celloai", c.host == "pair" else { return nil }
        func q(_ name: String) -> String? { c.queryItems?.first { $0.name == name }?.value }
        let hosts = (q("h") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !hosts.isEmpty,
              let port = q("p").flatMap(Int.init), (1...65535).contains(port),
              let fp = q("fp")?.lowercased(), fp.count == 64, fp.allSatisfy(\.isHexDigit),
              let token = q("t"), token.count >= 32 else { return nil }
        return Pairing(hosts: hosts, port: port, fingerprint: fp, token: token, pcName: q("n") ?? "PC")
    }

    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.celloai.cindy",
        kSecAttrAccount as String: "pairing",
    ]

    static func load() -> Pairing? {
        var query = base
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    func save() {
        Pairing.clear()
        var item = Pairing.base
        item[kSecValueData as String] = try? JSONEncoder().encode(self)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(base as CFDictionary)
    }
}
