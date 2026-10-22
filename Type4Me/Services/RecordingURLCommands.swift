import Foundation

enum RecordingURLCommand: String, Equatable, Sendable, CaseIterable {
    case start
    case stop
    case toggle
}

enum RecordingURLCommandError: Error, Equatable, Sendable {
    case unsupportedScheme
    case urlTooLong
    case invalidPath
    case unsupportedParameter
    case unknownCommand
}

enum RecordingURLCommandParser {
    static let maximumURLBytes = 8 * 1024

    static func parse(
        _ url: URL,
        allowedSchemes: Set<String>
    ) -> Result<RecordingURLCommand, RecordingURLCommandError> {
        guard url.absoluteString.utf8.count <= maximumURLBytes else {
            return .failure(.urlTooLong)
        }
        guard let scheme = url.scheme?.lowercased(),
              allowedSchemes.map({ $0.lowercased() }).contains(scheme) else {
            return .failure(.unsupportedScheme)
        }
        guard let host = url.host?.lowercased(),
              let command = RecordingURLCommand(rawValue: host) else {
            return .failure(.unknownCommand)
        }

        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty || path == "/" else {
            return .failure(.invalidPath)
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems,
           !queryItems.isEmpty {
            return .failure(.unsupportedParameter)
        }

        return .success(command)
    }
}

enum RecordingURLDecision: Equatable, Sendable {
    case start
    case finish
    case ignore

    static func decide(
        for command: RecordingURLCommand,
        phase: FloatingBarPhase
    ) -> RecordingURLDecision {
        switch command {
        case .start:
            switch phase {
            case .hidden, .done, .error:
                return .start
            case .preparing, .recording, .finishing, .processing, .recovering:
                return .ignore
            }
        case .stop:
            switch phase {
            case .preparing, .recording:
                return .finish
            case .hidden, .done, .error, .finishing, .processing, .recovering:
                return .ignore
            }
        case .toggle:
            switch phase {
            case .hidden, .done, .error:
                return .start
            case .preparing, .recording:
                return .finish
            case .finishing, .processing, .recovering:
                return .ignore
            }
        }
    }
}
