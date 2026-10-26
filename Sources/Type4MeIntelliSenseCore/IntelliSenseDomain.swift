import Foundation

public enum ApplicationCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case messaging
    case email
    case document
    case browser
    case development
    case terminal
    case other
}

public enum InputControlCategory: String, Codable, Sendable {
    case singleLine
    case multiLine
    case search
    case title
    case code
    case terminal
    case unknown
}

public enum ContextAvailability: String, Codable, Sendable {
    case none
    case appOnly
    case appAndControl
    case full
    case blacklisted
    case unavailable
    case sensitive
}

public struct IntelliSenseContextSnapshot: Equatable, Codable, Sendable {
    public var bundleIdentifier: String?
    public var appName: String?
    public var appCategory: ApplicationCategory
    public var controlCategory: InputControlCategory
    public var contextBeforeCursor: String
    public var contextAfterCursor: String
    public var availability: ContextAvailability
    public var wasTruncated: Bool

    public init(
        bundleIdentifier: String?,
        appName: String?,
        appCategory: ApplicationCategory,
        controlCategory: InputControlCategory,
        contextBeforeCursor: String,
        contextAfterCursor: String,
        availability: ContextAvailability,
        wasTruncated: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.appCategory = appCategory
        self.controlCategory = controlCategory
        self.contextBeforeCursor = contextBeforeCursor
        self.contextAfterCursor = contextAfterCursor
        self.availability = availability
        self.wasTruncated = wasTruncated
    }

    public static let unavailable = Self(
        bundleIdentifier: nil,
        appName: nil,
        appCategory: .other,
        controlCategory: .unknown,
        contextBeforeCursor: "",
        contextAfterCursor: "",
        availability: .unavailable,
        wasTruncated: false
    )
}

public enum AppContextClassifier {
    public static func classify(bundleIdentifier: String?, appName: String?) -> ApplicationCategory {
        let bundle = (bundleIdentifier ?? "").lowercased()
        let name = (appName ?? "").lowercased()
        let identity = bundle + " " + name

        if containsAny(identity, [
            "slack", "wechat", "weixin", "lark", "feishu", "discord",
            "telegram", "whatsapp", "messages", "mobilesms", "微信", "飞书",
        ]) {
            return .messaging
        }
        if containsAny(identity, ["mail", "outlook", "spark", "smartemail", "airmail", "mimestream"]) {
            return .email
        }
        if containsAny(identity, [
            "notion", "word", "pages", "notes", "drafts", "obsidian",
            "bear", "ulysses", "agiletortoise",
        ]) {
            return .document
        }
        if containsAny(identity, [
            "safari", "chrome", "chromium", "firefox", "arc", "edge",
            "company.thebrowser.dia", " dia",
        ]) {
            return .browser
        }
        if containsAny(identity, [
            "xcode", "vscode", "visual-studio-code", "jetbrains", "zed",
            "sublimetext", "nova", "textmate", "openai.codex", "codex",
        ]) {
            return .development
        }
        if containsAny(identity, ["terminal", "iterm", "ghostty", "wezterm", "alacritty", "kitty"]) {
            return .terminal
        }
        return .other
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}

public struct BlacklistedApp: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var bundleIdentifier: String
    public var displayName: String

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

public struct IntelliSenseSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = currentSchemaVersion
    public var applicationAwarenessEnabled = false
    public var contextAwarenessEnabled = false
    public var correctionDetectionEnabled = false
    public var expressionLearningEnabled = false
    public var blacklistedApps: [BlacklistedApp] = []

    public init(
        schemaVersion: Int = currentSchemaVersion,
        applicationAwarenessEnabled: Bool = false,
        contextAwarenessEnabled: Bool = false,
        correctionDetectionEnabled: Bool = false,
        expressionLearningEnabled: Bool = false,
        blacklistedApps: [BlacklistedApp] = []
    ) {
        self.schemaVersion = schemaVersion
        self.applicationAwarenessEnabled = applicationAwarenessEnabled
        self.contextAwarenessEnabled = contextAwarenessEnabled
        self.correctionDetectionEnabled = correctionDetectionEnabled
        self.expressionLearningEnabled = expressionLearningEnabled
        self.blacklistedApps = blacklistedApps
    }

    public func isBlacklisted(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return blacklistedApps.contains {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    public func normalized() -> Self {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        var seen = Set<String>()
        copy.blacklistedApps = blacklistedApps.compactMap { app in
            let bundleID = app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty else { return nil }
            let key = bundleID.lowercased()
            guard seen.insert(key).inserted else { return nil }
            let displayName = app.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return BlacklistedApp(
                bundleIdentifier: bundleID,
                displayName: displayName.isEmpty ? bundleID : displayName
            )
        }
        return copy
    }
}

public struct EffectiveExpressionProfile: Equatable, Codable, Sendable {
    public var directives: [String]
    public var sourceScope: String?

    public init(directives: [String], sourceScope: String? = nil) {
        self.directives = directives
        self.sourceScope = sourceScope
    }
}

public struct IntelliSenseRequest: Equatable, Codable, Sendable {
    public var text: String
    public var context: IntelliSenseContextSnapshot
    public var settings: IntelliSenseSettings
    public var expressionProfile: EffectiveExpressionProfile?

    public init(
        text: String,
        context: IntelliSenseContextSnapshot,
        settings: IntelliSenseSettings,
        expressionProfile: EffectiveExpressionProfile? = nil
    ) {
        self.text = text
        self.context = context
        self.settings = settings
        self.expressionProfile = expressionProfile
    }
}

public struct IntelliSensePromptInput: Equatable, Sendable {
    public let context: IntelliSenseContextSnapshot
    public let settings: IntelliSenseSettings
    public let expressionProfile: EffectiveExpressionProfile?

    public init(
        context: IntelliSenseContextSnapshot,
        settings: IntelliSenseSettings,
        expressionProfile: EffectiveExpressionProfile?
    ) {
        self.context = context
        self.settings = settings
        self.expressionProfile = expressionProfile
    }
}
