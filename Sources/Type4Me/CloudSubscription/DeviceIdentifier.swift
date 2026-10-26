import Foundation
import IOKit

enum DeviceIdentifier {
    static var deviceID: String {
        if let hwUUID = hardwareUUID() {
            return hwUUID
        }
        return keychainFallbackUUID()
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service, "IOPlatformUUID" as CFString,
            kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
    }

    private static func keychainFallbackUUID() -> String {
        let service = "com.type4me.device-id"
        let account = "device-uuid"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let uuid = String(data: data, encoding: .utf8) {
            return uuid
        }

        let uuid = UUID().uuidString
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: uuid.data(using: .utf8)!
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
        return uuid
    }
}
