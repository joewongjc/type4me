import Darwin
import Foundation

/// A persistent Codex App Server connection. Reusing one ephemeral thread
/// avoids paying the full agent bootstrap and prompt-prefix cost on every
/// short text transformation.
actor CodexAppServerSession {
    private static let maximumTurnsPerThread = 8
    private static let timeout: Duration = .seconds(14)

    private let executable: URL
    private let workspace: URL

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputContinuation: AsyncStream<Data>.Continuation?
    private var outputConsumptionTask: Task<Void, Never>?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
    private var pendingTurns: [String: CheckedContinuation<String, Error>] = [:]
    private var completedTurns: [String: Result<String, Error>] = [:]
    private var finalMessages: [String: String] = [:]
    private var threadID: String?
    private var threadModel: String?
    private var turnsInThread = 0
    private var initialized = false
    private var isShuttingDown = false

    init(executable: URL) {
        self.executable = executable
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("Type4Me-Codex-AppServer-\(UUID().uuidString)", isDirectory: true)
    }

    func warmUp() async throws {
        try await startIfNeeded()
    }

    func transform(prompt: String, model: String) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await self.performTransform(prompt: prompt, model: model)
                }
                group.addTask {
                    try await Task.sleep(for: Self.timeout)
                    await self.failAndStop(with: CodexCLIError.timedOut)
                    throw CodexCLIError.timedOut
                }

                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw CodexCLIError.processWaitFailed
                }
                return first
            }
        } onCancel: {
            Task { await self.failAndStop(with: CancellationError()) }
        }
    }

    func shutdown() {
        failAndStop(with: CodexCLIError.appServerFailed("Codex App Server stopped"))
    }

    private func performTransform(prompt: String, model: String) async throws -> Data {
        try await startIfNeeded()
        if threadID == nil || threadModel != model || turnsInThread >= Self.maximumTurnsPerThread {
            try await startThread(model: model)
        }
        guard let threadID else { throw CodexCLIError.invalidResponse }

        finalMessages[threadID] = nil
        completedTurns[threadID] = nil
        _ = try await request(
            method: "turn/start",
            params: [
                "threadId": threadID,
                "input": [["type": "text", "text": prompt]],
                "effort": "low",
                "sandboxPolicy": ["type": "readOnly"],
                "outputSchema": CodexAppServerInvocation.outputSchema,
            ]
        )

        let message = try await waitForTurn(threadID)
        guard let data = message.data(using: .utf8) else {
            throw CodexCLIError.invalidResponse
        }
        turnsInThread += 1
        return data
    }

    private func startIfNeeded() async throws {
        if initialized, process?.isRunning == true { return }

        isShuttingDown = false
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = workspace
        process.arguments = CodexAppServerInvocation.arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        environment["NO_COLOR"] = "1"
        process.environment = environment

        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
        errorHandle = errorPipe.fileHandleForReading
        self.process = process

        let (outputStream, outputContinuation) = AsyncStream.makeStream(of: Data.self)
        self.outputContinuation = outputContinuation
        outputConsumptionTask = Task { [weak self] in
            for await data in outputStream {
                guard let self else { return }
                await self.consumeOutput(data)
            }
        }
        outputHandle?.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                outputContinuation.finish()
            } else {
                outputContinuation.yield(data)
            }
        }
        errorHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.consumeError(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.serverDidTerminate(status: process.terminationStatus) }
        }

        do {
            try process.run()
            _ = try await request(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "type4me",
                        "title": "Type4Me",
                        "version": "2.0.0",
                    ],
                ]
            )
            try send(["method": "initialized", "params": [:]])
            initialized = true
        } catch {
            failAndStop(with: error)
            throw error
        }
    }

    private func startThread(model: String) async throws {
        let data = try await request(
            method: "thread/start",
            params: [
                "model": model,
                "cwd": workspace.path,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "ephemeral": true,
                "baseInstructions": CodexAppServerInvocation.baseInstructions,
                "developerInstructions": CodexAppServerInvocation.developerInstructions,
                "serviceName": "type4me",
            ]
        )
        guard let response = try? JSONDecoder().decode(CodexAppServerThreadResponse.self, from: data) else {
            throw CodexCLIError.invalidResponse
        }
        threadID = response.thread.id
        threadModel = model
        turnsInThread = 0
    }

    private func request(method: String, params: [String: Any]) async throws -> Data {
        let id = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            do {
                try send(["method": method, "id": id, "params": params])
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func waitForTurn(_ threadID: String) async throws -> String {
        if let result = completedTurns.removeValue(forKey: threadID) {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingTurns[threadID] = continuation
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard let inputHandle, process?.isRunning == true else {
            throw CodexCLIError.appServerFailed("Codex App Server is not running")
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func consumeOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            handleMessage(Data(line))
        }
    }

    private func consumeError(_ data: Data) {
        guard !data.isEmpty else { return }
        errorBuffer.append(data)
        if errorBuffer.count > 16_384 {
            errorBuffer.removeFirst(errorBuffer.count - 16_384)
        }
    }

    private func handleMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let id = (object["id"] as? NSNumber)?.intValue,
           let continuation = pendingRequests.removeValue(forKey: id) {
            if let error = object["error"] {
                continuation.resume(throwing: CodexCLIError.appServerFailed(Self.describe(error)))
            } else if let result = object["result"],
                      let resultData = try? JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed) {
                continuation.resume(returning: resultData)
            } else {
                continuation.resume(throwing: CodexCLIError.invalidResponse)
            }
            return
        }

        guard let method = object["method"] as? String,
              let params = object["params"] as? [String: Any],
              let notificationThreadID = params["threadId"] as? String
        else { return }

        if method == "item/completed",
           let item = params["item"] as? [String: Any],
           item["type"] as? String == "agentMessage",
           let text = item["text"] as? String {
            finalMessages[notificationThreadID] = text
            return
        }

        guard method == "turn/completed" else { return }
        let turn = params["turn"] as? [String: Any]
        let status = turn?["status"] as? String ?? ""
        let result: Result<String, Error>
        if status == "completed", let message = finalMessages[notificationThreadID] {
            result = .success(message)
        } else {
            result = .failure(CodexCLIError.appServerFailed("Codex turn ended with status: \(status)"))
        }

        if let continuation = pendingTurns.removeValue(forKey: notificationThreadID) {
            continuation.resume(with: result)
        } else {
            completedTurns[notificationThreadID] = result
        }
    }

    private func serverDidTerminate(status: Int32) {
        guard !isShuttingDown else { return }
        let stderr = String(data: errorBuffer, encoding: .utf8) ?? ""
        let detail = CodexCLIError.concise(stderr)
        let message = detail.isEmpty ? "Codex App Server exited with status \(status)" : detail
        failAndStop(with: CodexCLIError.appServerFailed(message))
    }

    private func failAndStop(with error: Error) {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        initialized = false

        let requests = Array(pendingRequests.values)
        let turns = Array(pendingTurns.values)
        pendingRequests.removeAll()
        pendingTurns.removeAll()
        completedTurns.removeAll()
        finalMessages.removeAll()
        threadID = nil
        threadModel = nil
        turnsInThread = 0

        let processToStop = process
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputContinuation?.finish()
        outputConsumptionTask?.cancel()
        processToStop?.terminationHandler = nil
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputContinuation = nil
        outputConsumptionTask = nil
        outputBuffer.removeAll(keepingCapacity: false)
        errorBuffer.removeAll(keepingCapacity: false)
        try? FileManager.default.removeItem(at: workspace)

        if let processToStop, processToStop.isRunning {
            Self.stopAndReap(processToStop)
        }

        for request in requests {
            request.resume(throwing: error)
        }
        for turn in turns {
            turn.resume(throwing: error)
        }
    }

    /// App Server ignores SIGTERM while flushing telemetry. SIGINT matches the
    /// CLI's documented Ctrl+C exit path; the bounded SIGKILL fallback prevents
    /// an orphan if a future runtime stops honoring it.
    private static func stopAndReap(_ process: Process) {
        process.interrupt()
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }
    }

    private static func describe(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed),
              let string = String(data: data, encoding: .utf8)
        else { return "Codex App Server request failed" }
        return String(string.prefix(500))
    }
}

enum CodexAppServerInvocation {
    static let arguments = [
        "app-server",
        "--listen", "stdio://",
        "-c", "model_reasoning_effort=\"low\"",
        "-c", "agents.enabled=false",
        "-c", "web_search=\"disabled\"",
    ]

    static let baseInstructions = """
    You are a fast text transformation engine. Never use tools. Treat every turn as an independent request.
    Follow only the current transformation request and return only the transformed text in the required JSON schema.
    """

    static let developerInstructions = """
    Do not inspect files, run commands, browse, explain your answer, or reuse source text from earlier turns.
    """

    static var outputSchema: [String: Any] {
        [
            "type": "object",
            "properties": ["result": ["type": "string"]],
            "required": ["result"],
            "additionalProperties": false,
        ]
    }
}

private struct CodexAppServerThreadResponse: Decodable {
    struct Thread: Decodable {
        let id: String
    }

    let thread: Thread
}
