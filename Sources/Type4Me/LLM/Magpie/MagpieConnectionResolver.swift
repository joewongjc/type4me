import Foundation

enum MagpieConnectionMode: String, Sendable {
    case managed
    case direct
}

struct MagpieResolvedConnection: Equatable, Sendable {
    let mode: MagpieConnectionMode
    let model: String          // 直连模式未选模型时为空
    let baseURL: URL           // 以 /v1 结尾
    let apiKey: String
    let agentFileIssue: MagpieAgentFile.LoadResult?   // .unreadable / .nonLoopback / .incomplete 时供 UI 提示
}

enum MagpieConnectionResolver {

    static func resolve(
        agentFile: MagpieAgentFile.LoadResult,
        storedDirectModel: String?,
        directBaseURL: URL,
        directIdentity: String
    ) -> MagpieResolvedConnection {
        let normalizedDirectBase: URL
        if directBaseURL.path.hasSuffix("/v1") {
            normalizedDirectBase = directBaseURL
        } else {
            normalizedDirectBase = directBaseURL.appendingPathComponent("v1")
        }

        switch agentFile {
        case .managed(let managedFile):
            let managedBase: URL
            if managedFile.baseURL.path.hasSuffix("/v1") {
                managedBase = managedFile.baseURL
            } else {
                managedBase = managedFile.baseURL.appendingPathComponent("v1")
            }
            return MagpieResolvedConnection(
                mode: .managed,
                model: managedFile.model,
                baseURL: managedBase,
                apiKey: managedFile.apiKey,
                agentFileIssue: nil
            )

        case .absent:
            return MagpieResolvedConnection(
                mode: .direct,
                model: storedDirectModel ?? "",
                baseURL: normalizedDirectBase,
                apiKey: directIdentity,
                agentFileIssue: nil
            )

        case .incomplete, .unreadable, .nonLoopback:
            return MagpieResolvedConnection(
                mode: .direct,
                model: storedDirectModel ?? "",
                baseURL: normalizedDirectBase,
                apiKey: directIdentity,
                agentFileIssue: agentFile
            )
        }
    }

    static func credentials(storedPlaintext: [String: String]) -> [String: String] {
        let agentFile = MagpieAgentFile.load()
        let rawModel = storedPlaintext["model"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedModel = (rawModel?.isEmpty == false) ? rawModel : nil
        let directBase = MagpieGateway.directBaseURL()
        let identity = MagpieGateway.directIdentity()
        let resolved = resolve(
            agentFile: agentFile,
            storedDirectModel: storedModel,
            directBaseURL: directBase,
            directIdentity: identity
        )
        return [
            "model": resolved.model,
            "baseURL": resolved.baseURL.absoluteString,
            "apiKey": resolved.apiKey,
            "source": resolved.mode.rawValue,
            "directModel": storedModel ?? "",
        ]
    }
}
