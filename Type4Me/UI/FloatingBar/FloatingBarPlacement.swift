import Foundation

/// Persistent position center for the floating bar indicator.
struct FloatingBarPlacement: Codable, Equatable, Sendable {
    enum Horizontal: Codable, Equatable, Sendable {
        case `default`
        /// Center X as a fraction of visibleFrame width, 0...1.
        case fraction(Double)
    }

    enum Vertical: Codable, Equatable, Sendable {
        case `default`
        /// Distance in points from visibleFrame.minY to the base capsule center.
        case fromBottom(Double)
        /// Distance in points from visibleFrame.maxY to the base capsule center.
        case fromTop(Double)
    }

    var version = 1
    var horizontal: Horizontal = .default
    var vertical: Vertical = .default

    static let `default` = FloatingBarPlacement()
    var isDefault: Bool { horizontal == .default && vertical == .default }
}

extension Notification.Name {
    static let floatingBarPlacementDidChange = Notification.Name("FloatingBarPlacementDidChangeNotification")
}

enum FloatingBarPlacementStore {
    static let storageKey = "tf_floatingBarPlacement"

    static func decode(_ raw: String) -> FloatingBarPlacement {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return .default
        }
        do {
            let decoded = try JSONDecoder().decode(FloatingBarPlacement.self, from: data)
            guard decoded.version == 1 else { return .default }
            return decoded
        } catch {
            return .default
        }
    }

    static func encode(_ placement: FloatingBarPlacement) -> String? {
        do {
            let data = try JSONEncoder().encode(placement)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    static func load(_ defaults: UserDefaults = .standard) -> FloatingBarPlacement {
        guard let raw = defaults.string(forKey: storageKey) else {
            return .default
        }
        return decode(raw)
    }

    static func save(_ placement: FloatingBarPlacement, _ defaults: UserDefaults = .standard) {
        if placement.isDefault {
            reset(defaults)
            return
        }
        if let jsonString = encode(placement) {
            defaults.set(jsonString, forKey: storageKey)
        }
        NotificationCenter.default.post(name: .floatingBarPlacementDidChange, object: nil)
    }

    static func reset(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
        NotificationCenter.default.post(name: .floatingBarPlacementDidChange, object: nil)
    }
}
