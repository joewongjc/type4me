import Foundation

/// Central registry of macOS actions exposed to the LLM in Mac Action mode.
enum ActionRegistry {

    /// All actions available to the LLM. Add new actions here.
    static let allActions: [any MacAction] = [
        OpenAppAction(),
        SetVolumeAction(),
        SetBrightnessAction(),
        ToggleDarkModeAction(),
        ScreenshotAction(),
        ClipboardWriteAction(),
        LockScreenAction(),
        SearchWebAction(),
        GetBatteryAction(),
        MinimizeWindowAction(),
        FullscreenWindowAction(),
        CloseWindowAction(),
        CreateReminderAction(),
        ScrollDownAction(),
        ScrollUpAction(),
        OpenVocabularyAction(),
        PrepareSnippetFromSelectionAction(),
        AddSelectedHotwordAction(),
    ]

    /// Renders the JSON tool list block injected into the LLM system prompt.
    static func toolsJSON() -> String {
        let items: [[String: Any]] = allActions.map { action in
            [
                "name": action.name,
                "description": action.description,
                "parameters": action.parametersSchema,
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: items,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        ), let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    /// Look up an action by name and execute it. Returns nil if no action with
    /// the given name is registered.
    static func dispatch(
        name: String,
        args: [String: Any],
        context: MacActionContext = .empty
    ) async -> MacActionResult? {
        guard let action = allActions.first(where: { $0.name == name }) else {
            return nil
        }
        if let contextualAction = action as? any ContextualMacAction {
            return await contextualAction.execute(args: args, context: context)
        }
        return await action.execute(args: args)
    }
}
