import SwiftUI
import AppKit

// MARK: - Brand Icon Cache & Resolver

private final class BrandIconCache: @unchecked Sendable {
    static let shared = BrandIconCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(named name: String) -> NSImage? {
        let key = name as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // 1. Check App Bundle Resources/Icons/
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons"),
           let img = NSImage(contentsOf: url) {
            cache.setObject(img, forKey: key)
            return img
        }

        // 2. Check App Bundle Contents/Resources/Icons/
        if let resourceURL = Bundle.main.resourceURL {
            let directURL = resourceURL.appendingPathComponent("Icons/\(name).png")
            if let img = NSImage(contentsOf: directURL) {
                cache.setObject(img, forKey: key)
                return img
            }
        }

        // 3. Check App Bundle flat Resources
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            cache.setObject(img, forKey: key)
            return img
        }

        // 4. Development fallback: local source repository path
        let sourceDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Icons")
        let devURL = sourceDir.appendingPathComponent("\(name).png")
        if let img = NSImage(contentsOf: devURL) {
            cache.setObject(img, forKey: key)
            return img
        }

        return nil
    }
}

// MARK: - Brand Icon View

struct BrandIconView: View {
    enum ProviderKind {
        case asr(ASRProvider)
        case llm(LLMProvider)
    }

    let kind: ProviderKind
    var size: CGFloat = 18

    init(asr provider: ASRProvider, size: CGFloat = 18) {
        self.kind = .asr(provider)
        self.size = size
    }

    init(llm provider: LLMProvider, size: CGFloat = 18) {
        self.kind = .llm(provider)
        self.size = size
    }

    private var iconName: String {
        switch kind {
        case .asr(let provider):
            switch provider {
            case .apple:       return "apple"
            case .sherpa:      return "sherpa"
            case .volcano:     return "volcano"
            case .soniox:      return "soniox"
            case .deepgram:    return "deepgram"
            case .cartesia:    return "cartesia"
            case .assemblyai:  return "assemblyai"
            case .elevenlabs:  return "elevenlabs"
            case .gemini:      return "gemini"
            case .grok:        return "grok"
            case .stepfun,
                 .stepfunBatch: return "stepfun"
            case .mimo:        return "mimo"
            case .bailian:     return "bailian"
            case .baidu:       return "baidu"
            case .openai:      return "openai"
            default:           return "custom"
            }
        case .llm(let provider):
            switch provider {
            case .doubao:      return "doubao"
            case .deepseek:    return "deepseek"
            case .kimi:        return "kimi"
            case .minimaxCN,
                 .minimaxIntl: return "minimax"
            case .bailian:     return "bailian"
            case .openrouter:  return "openrouter"
            case .openai:      return "openai"
            case .gemini:      return "gemini"
            case .zhipu:       return "zhipu"
            case .claude:      return "claude"
            case .codexCLI:    return "codex"
            case .ollama:      return "ollama"
            case .custom:      return "custom"
            }
        }
    }

    var body: some View {
        Group {
            if let nsImage = BrandIconCache.shared.image(named: iconName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Fallback Icon

    @ViewBuilder
    private var fallbackIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(TF.settingsCardAlt)
            Image(systemName: fallbackSymbolName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(TF.settingsTextSecondary)
                .padding(size * 0.2)
        }
    }

    private var fallbackSymbolName: String {
        switch kind {
        case .asr(let provider):
            return ModelSettingsHelpers.icon(for: provider)
        case .llm(let provider):
            return ModelSettingsHelpers.icon(for: provider)
        }
    }
}
