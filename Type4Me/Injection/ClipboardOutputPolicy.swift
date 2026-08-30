import Foundation

/// Decides whether Type4Me results remain on the system clipboard after a
/// normal completion or a user-requested cancellation.
enum ClipboardOutputPolicy: String, CaseIterable, Identifiable {
    case alwaysCopy
    case cancelProcessed
    case cancelRawTranscript
    case neverCopy

    static let storageKey = "tf_clipboardOutputPolicy"
    private static let legacyStorageKey = "tf_preserveClipboard"
    static let defaultValue: Self = .cancelProcessed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysCopy: return L("总是复制", "Always Copy")
        case .cancelProcessed: return L("仅取消：处理后复制", "On Cancel: Processed")
        case .cancelRawTranscript: return L("仅取消：复制原始识别", "On Cancel: Raw Transcript")
        case .neverCopy: return L("从不复制", "Never Copy")
        }
    }

    var detail: String {
        switch self {
        case .alwaysCopy:
            return L(
                "正常完成或取消后，都将结果复制到剪贴板。",
                "Copy results to the clipboard after completion or cancellation."
            )
        case .cancelProcessed:
            return L(
                "正常完成后不保留；取消后经 AI 处理并复制结果。",
                "Don't keep results after completion. On cancel, process with AI and copy the result."
            )
        case .cancelRawTranscript:
            return L(
                "正常完成后不保留；取消后直接复制原始识别文本。",
                "Don't keep results after completion. On cancel, copy the raw transcript directly."
            )
        case .neverCopy:
            return L(
                "不将结果保留在剪贴板；取消后也不进行 AI 处理。",
                "Never keep results in the clipboard. AI processing is also skipped on cancel."
            )
        }
    }

    /// Only Always Copy leaves a normally completed result on the clipboard.
    var retainsNormalResult: Bool { self == .alwaysCopy }

    /// Three policies keep a user-cancelled result so it can be pasted manually.
    var retainsCancelledResult: Bool { self != .neverCopy }

    /// Raw and never-copy cancellation intentionally avoid LLM work.
    var processesCancelledResult: Bool {
        self == .alwaysCopy || self == .cancelProcessed
    }

    /// User-facing cancellation retention modes for granular Settings UI.
    enum CancellationRetentionMode: String, CaseIterable, Identifiable {
        case processed
        case raw
        case none

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .processed: return L("AI 润色", "AI Processed")
            case .raw: return L("原始文本", "Raw Text")
            case .none: return L("不留存", "None")
            }
        }
    }

    /// Derived cancellation retention mode from the composite policy.
    var cancellationMode: CancellationRetentionMode {
        switch self {
        case .alwaysCopy, .cancelProcessed:
            return .processed
        case .cancelRawTranscript:
            return .raw
        case .neverCopy:
            return .none
        }
    }

    /// Map individual normal and cancellation preferences back to the canonical storage policy.
    static func policy(
        retainsNormal: Bool,
        cancellationMode: CancellationRetentionMode
    ) -> ClipboardOutputPolicy {
        if retainsNormal {
            return .alwaysCopy
        }
        switch cancellationMode {
        case .processed:
            return .cancelProcessed
        case .raw:
            return .cancelRawTranscript
        case .none:
            return .neverCopy
        }
    }

    /// Resolve clipboard retention from the frozen completion intent.
    func retainsResult(forCancellation isCancelled: Bool) -> Bool {
        isCancelled ? retainsCancelledResult : retainsNormalResult
    }

    /// Distinguishes cancelled history rows without requiring presentation code
    /// to infer whether an LLM was used.
    var cancelledHistoryStatus: String {
        if processesCancelledResult {
            return "cancelled_processed"
        }
        return self == .cancelRawTranscript
            ? "cancelled_raw"
            : "cancelled_unprocessed"
    }

    static func migrateIfNeeded(userDefaults: UserDefaults = .standard) {
        guard userDefaults.string(forKey: storageKey) == nil else { return }

        let migrated: Self
        if userDefaults.object(forKey: legacyStorageKey) == nil {
            migrated = defaultValue
        } else {
            // The legacy key was inverse: false meant "always copy".
            migrated = userDefaults.bool(forKey: legacyStorageKey)
                ? .cancelProcessed
                : .alwaysCopy
        }
        userDefaults.set(migrated.rawValue, forKey: storageKey)
    }

    static func current(userDefaults: UserDefaults = .standard) -> Self {
        migrateIfNeeded(userDefaults: userDefaults)
        guard let rawValue = userDefaults.string(forKey: storageKey),
              let policy = Self(rawValue: rawValue)
        else { return defaultValue }
        return policy
    }
}
