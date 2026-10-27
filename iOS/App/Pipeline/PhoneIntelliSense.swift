import Foundation
import Type4MeIntelliSenseCore
import UIKit

/// Intelli Sense on the iPhone: the Mac's prompt and output guard, fed with
/// what the keyboard saw of the field instead of the Mac's accessibility
/// read. iOS doesn't tell a keyboard which app it's in, so the scene comes
/// from the field's keyboard type, return key and content type.
enum PhoneIntelliSense {
    struct Request {
        let prompt: ModePrompts.Request
        let snapshot: IntelliSenseContextSnapshot

        /// For Diagnostics: the scene and how much context went along.
        var summary: String {
            let context = snapshot.availability == .full
                ? L("上下文 \(snapshot.contextBeforeCursor.count)+\(snapshot.contextAfterCursor.count) 字", "context \(snapshot.contextBeforeCursor.count)+\(snapshot.contextAfterCursor.count) chars")
                : snapshot.availability.rawValue
            return "\(snapshot.appCategory.rawValue)/\(snapshot.controlCategory.rawValue), \(context)"
        }
    }

    static func request(text: String, field: FieldContext?) -> Request {
        let snapshot = snapshot(for: field)
        // Expression learning watches edits in the target app, which a
        // keyboard can't; correction detection feeds that learning.
        let settings = IntelliSenseSettings(
            applicationAwarenessEnabled: true,
            contextAwarenessEnabled: SharedSettings.intelliSenseContext
        )
        let prompt = IntelliSensePromptBuilder.build(request: IntelliSenseRequest(
            text: text,
            context: snapshot,
            settings: settings
        ))
        // The template carries the transcript inline, as on the Mac.
        return Request(prompt: ModePrompts.Request(system: nil, user: prompt), snapshot: snapshot)
    }

    /// The Mac guard: a reply that drops facts, answers the dictation or
    /// otherwise can't be trusted gives way to the words as spoken.
    static func check(_ output: String, input: String, request: Request) -> (text: String, rejection: String?) {
        let result = IntelliSenseOutputValidator.process(input: input, candidate: output, context: request.snapshot)
        if case .reject(let reason) = result.decision { return (result.finalText, reason.rawValue) }
        return (result.finalText, nil)
    }

    static func snapshot(for field: FieldContext?) -> IntelliSenseContextSnapshot {
        var snapshot = IntelliSenseContextSnapshot(
            bundleIdentifier: nil,
            appName: nil,
            appCategory: .other,
            controlCategory: .unknown,
            contextBeforeCursor: "",
            contextAfterCursor: "",
            availability: .unavailable,
            wasTruncated: false
        )
        guard let field else { return snapshot }
        (snapshot.appCategory, snapshot.controlCategory) = scene(for: field)
        let combined = field.before + field.after
        if field.isSensitive || IntelliSenseSensitiveTextScanner.containsSensitiveContent(combined) {
            snapshot.availability = .sensitive
            return snapshot
        }
        snapshot.contextBeforeCursor = field.before
        snapshot.contextAfterCursor = field.after
        snapshot.availability = combined.isEmpty ? .appAndControl : .full
        snapshot.wasTruncated = field.before.count >= FieldContext.beforeLimit
            || field.after.count >= FieldContext.afterLimit
        return snapshot
    }

    /// The scene a field implies. A Send return key is a chat composer;
    /// search keys and web-search keyboards are search boxes; URL and
    /// address fields are single lines. Everything else is general writing.
    static func scene(for field: FieldContext) -> (ApplicationCategory, InputControlCategory) {
        let keyboard = UIKeyboardType(rawValue: field.keyboardType) ?? .default
        let returnKey = UIReturnKeyType(rawValue: field.returnKeyType) ?? .default
        let content = field.textContentType.map(UITextContentType.init(rawValue:))
        if keyboard == .webSearch || [.search, .google, .yahoo].contains(returnKey) {
            return (.browser, .search)
        }
        if keyboard == .URL || content == .URL {
            return (.browser, .singleLine)
        }
        if keyboard == .emailAddress || content == .emailAddress {
            return (.other, .singleLine)
        }
        if returnKey == .send {
            return (.messaging, .multiLine)
        }
        return (.other, .unknown)
    }
}
