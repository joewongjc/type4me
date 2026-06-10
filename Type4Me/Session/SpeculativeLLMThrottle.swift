import Foundation

struct SpeculativeLLMThrottle: Sendable {
    static let minimumTextLength = 8
    static let minimumCharacterIncrement = 8
    static let debounceDuration: Duration = .milliseconds(600)

    enum Submission: Equatable, Sendable {
        case tooShort
        case deltaTooSmall
        case debounce
        case queued
        case duplicate
    }

    private(set) var lastStartedText = ""
    private(set) var debounceText: String?
    private(set) var pendingText: String?
    private(set) var inFlight = false

    mutating func submit(_ text: String) -> Submission {
        guard text.count >= Self.minimumTextLength else {
            debounceText = nil
            pendingText = nil
            return .tooShort
        }
        guard text != lastStartedText else {
            debounceText = nil
            pendingText = nil
            return .duplicate
        }
        guard lastStartedText.isEmpty
                || text.count - lastStartedText.count >= Self.minimumCharacterIncrement
        else {
            debounceText = nil
            pendingText = nil
            return .deltaTooSmall
        }

        if inFlight {
            pendingText = text
            debounceText = nil
            return .queued
        }

        debounceText = text
        return .debounce
    }

    mutating func beginDebouncedRequest(for text: String) -> Bool {
        guard !inFlight, debounceText == text else { return false }
        debounceText = nil
        pendingText = nil
        lastStartedText = text
        inFlight = true
        return true
    }

    mutating func requestCompleted(input: String) -> String? {
        guard inFlight, input == lastStartedText else { return nil }
        inFlight = false
        let next = pendingText
        pendingText = nil
        return next
    }

    mutating func prepareForStop() {
        debounceText = nil
        pendingText = nil
    }

    mutating func markStopTimeRequestStarted(input: String) {
        prepareForStop()
        lastStartedText = input
        inFlight = true
    }

    mutating func reset() {
        lastStartedText = ""
        debounceText = nil
        pendingText = nil
        inFlight = false
    }
}

struct FinalInjectionGuard: Sendable {
    private var claimedGeneration: Int?

    mutating func claim(generation: Int) -> Bool {
        guard claimedGeneration != generation else { return false }
        claimedGeneration = generation
        return true
    }

    mutating func reset() {
        claimedGeneration = nil
    }
}
