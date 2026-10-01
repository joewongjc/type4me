import Foundation
import AppKit

let destinationDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Type4Me/Resources/Icons")

try? FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

struct ProviderIconSource {
    let filename: String
    let urls: [String]
    let fallbackSVG: String?
}

let sources: [ProviderIconSource] = [
    ProviderIconSource(
        filename: "openai.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/openai.svg",
            "https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/openai.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "claude.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/claude-color.svg",
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/claude.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "gemini.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/gemini-color.svg",
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/gemini.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "deepseek.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/deepseek-color.svg",
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/deepseek.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "doubao.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/doubao-color.svg",
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/doubao.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "kimi.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/moonshot.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "minimax.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/minimax-color.svg",
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/minimax.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "zhipu.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/zhipu-color.svg",
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/zhipu.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "ollama.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/ollama.svg",
            "https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/ollama.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "volcano.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/volcengine-color.svg",
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/volcengine.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "bailian.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/qwen-color.svg",
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/qwen.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "grok.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/grok.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "stepfun.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/stepfun-color.svg",
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/stepfun.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "openrouter.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/openrouter.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "apple.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/apple.svg",
            "https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/apple.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "baidu.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/baidu-color.svg",
            "https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/baidu.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "mimo.png",
        urls: [
            "https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/xiaomi.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "elevenlabs.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/elevenlabs.svg",
            "https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/elevenlabs.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "assemblyai.png",
        urls: [
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/assemblyai-color.svg",
            "https://unpkg.com/@lobehub/icons-static-svg@latest/icons/assemblyai.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "deepgram.png",
        urls: [
            "https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/deepgram.svg"
        ],
        fallbackSVG: nil
    ),
    ProviderIconSource(
        filename: "cartesia.png",
        urls: [],
        fallbackSVG: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
          <rect width="128" height="128" rx="28" fill="#5F3DC4"/>
          <path d="M64 24L76 52L104 64L76 76L64 104L52 76L24 64L52 52Z" fill="#FFFFFF"/>
          <circle cx="64" cy="64" r="10" fill="#B197FC"/>
        </svg>
        """
    ),
    ProviderIconSource(
        filename: "soniox.png",
        urls: [],
        fallbackSVG: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
          <rect width="128" height="128" rx="28" fill="#099268"/>
          <rect x="28" y="52" width="10" height="24" rx="5" fill="#FFFFFF"/>
          <rect x="44" y="38" width="10" height="52" rx="5" fill="#FFFFFF"/>
          <rect x="60" y="26" width="10" height="76" rx="5" fill="#E6FCF5"/>
          <rect x="76" y="42" width="10" height="44" rx="5" fill="#FFFFFF"/>
          <rect x="92" y="56" width="10" height="16" rx="5" fill="#FFFFFF"/>
        </svg>
        """
    ),
    ProviderIconSource(
        filename: "sherpa.png",
        urls: [],
        fallbackSVG: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
          <rect width="128" height="128" rx="28" fill="#1C2833"/>
          <rect x="36" y="36" width="56" height="56" rx="12" fill="#2E4053" stroke="#5DADE2" stroke-width="6"/>
          <circle cx="64" cy="64" r="14" fill="#5DADE2"/>
          <path d="M22 64h10M96 64h10M64 22v10M64 96v10" stroke="#5DADE2" stroke-width="6" stroke-linecap="round"/>
        </svg>
        """
    ),
    ProviderIconSource(
        filename: "codex.png",
        urls: [],
        fallbackSVG: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
          <rect width="128" height="128" rx="28" fill="#1E293B"/>
          <path d="M36 44L56 64L36 84" stroke="#4ADE80" stroke-width="10" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
          <path d="M68 84H92" stroke="#4ADE80" stroke-width="10" stroke-linecap="round"/>
        </svg>
        """
    ),
    ProviderIconSource(
        filename: "custom.png",
        urls: [],
        fallbackSVG: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
          <rect width="128" height="128" rx="28" fill="#475569"/>
          <path d="M40 44h48M40 64h48M40 84h48" stroke="#FFFFFF" stroke-width="8" stroke-linecap="round"/>
          <circle cx="52" cy="44" r="7" fill="#38BDF8"/>
          <circle cx="76" cy="64" r="7" fill="#38BDF8"/>
          <circle cx="58" cy="84" r="7" fill="#38BDF8"/>
        </svg>
        """
    )
]

func renderToPNG(data: Data, targetSize: Int = 128) -> Data? {
    guard let image = NSImage(data: data) else { return nil }
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: targetSize,
        pixelsHigh: targetSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
    guard let bitmapRep = rep else { return nil }
    bitmapRep.size = NSSize(width: targetSize, height: targetSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: targetSize, height: targetSize),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    return bitmapRep.representation(using: .png, properties: [:])
}

for item in sources {
    let destFile = destinationDir.appendingPathComponent(item.filename)
    var downloadedData: Data? = nil

    for urlStr in item.urls {
        guard let url = URL(string: urlStr) else { continue }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200, let d = data, !d.isEmpty {
                downloadedData = d
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if downloadedData != nil {
            print("[\(item.filename)] Downloaded from \(urlStr)")
            break
        }
    }

    if downloadedData == nil, let fallback = item.fallbackSVG, let d = fallback.data(using: .utf8) {
        downloadedData = d
        print("[\(item.filename)] Used fallback vector")
    }

    if let raw = downloadedData, let png = renderToPNG(data: raw, targetSize: 128) {
        try? png.write(to: destFile)
        print("✅ Saved \(item.filename) (\(png.count) bytes)")
    } else {
        print("❌ Failed \(item.filename)")
    }
}

print("Done processing all icons.")
