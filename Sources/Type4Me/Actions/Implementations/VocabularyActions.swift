import AppKit
import Foundation

private enum VocabularyActionNavigation {
    @MainActor
    static func open(_ request: VocabularyNavigationRequest) {
        VocabularyNavigationCenter.shared.submit(request)
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.presentSettings()
        } else {
            AppDelegate.openSettingsAction?()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct OpenVocabularyAction: MacAction {
    let name = "open_vocabulary"
    let description = "Open Type4Me vocabulary settings. Use hotwords for dictionary or ASR hotword requests, and snippets for text replacement requests."
    let parametersSchema: [String: String] = [
        "section": "Required section: hotwords or snippets"
    ]

    func execute(args: [String: Any]) async -> MacActionResult {
        guard let rawSection = (args["section"] as? String)?.lowercased(),
              let section = VocabularySection(rawValue: rawSection) else {
            return .failure(L("缺少或无效的词汇类型", "Missing or invalid vocabulary section"))
        }
        await VocabularyActionNavigation.open(VocabularyNavigationRequest(section: section))
        switch section {
        case .hotwords:
            return .ok(L("已打开 ASR 热词", "Opened ASR Hotwords"))
        case .snippets:
            return .ok(L("已打开片段替换", "Opened Snippets"))
        }
    }
}

struct PrepareSnippetFromSelectionAction: ContextualMacAction {
    let name = "prepare_snippet_from_selection"
    let description = "Open Type4Me Snippets and use the currently selected text as the trigger. The user will enter the replacement and save it."
    let parametersSchema: [String: String] = [:]

    func execute(args: [String: Any], context: MacActionContext) async -> MacActionResult {
        guard let selectedText = VocabularyCommandService.validated(
            context.selectedText,
            maximumLength: VocabularyURLCommandParser.maximumTermLength
        ) else {
            return .failure(L("请先选中要替换的文本", "Select the text to replace first"))
        }
        await VocabularyActionNavigation.open(VocabularyNavigationRequest(
            section: .snippets,
            trigger: selectedText
        ))
        return .ok(L("请补充替换内容并保存", "Enter the replacement and save"))
    }
}

struct AddSelectedHotwordAction: ContextualMacAction {
    let name = "add_selected_hotword"
    let description = "Add the currently selected text to Type4Me ASR hotwords without opening Settings."
    let parametersSchema: [String: String] = [:]

    func execute(args: [String: Any], context: MacActionContext) async -> MacActionResult {
        let result = VocabularyCommandService.live.addHotword(context.selectedText)
        switch result {
        case .added:
            return .ok(L("已添加热词", "Hotword added"))
        case .alreadyExists:
            return .ok(L("热词已存在", "Hotword already exists"))
        case .invalidInput:
            return .failure(L("请先选中有效文本", "Select valid text first"))
        case .saveFailed:
            return .failure(L("热词保存失败", "Failed to save hotword"))
        case .conflict:
            return .failure(L("热词添加失败", "Failed to add hotword"))
        }
    }
}
