import XCTest
@testable import Type4Me

final class MagpieAgentModelWriterTests: XCTestCase {

    private var tempDirectory: URL!
    private var agentFileURL: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MagpieWriterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        agentFileURL = tempDirectory.appendingPathComponent("magpie-agent.json")
        MagpieAgentFile.clearCache()
        MagpieModelCatalog.setAllowedModelsForTesting(nil)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        MagpieAgentFile.clearCache()
        MagpieModelCatalog.setAllowedModelsForTesting(nil)
        super.tearDown()
    }

    func testWriteModelUpdatesOnlyModel() throws {
        let originalJSON = """
        {
            "model": "old/model",
            "baseURL": "http://127.0.0.1:3425/v1",
            "apiKey": "agent-secret-key",
            "extraKey": "stay"
        }
        """.data(using: .utf8)!
        try originalJSON.write(to: agentFileURL)

        MagpieModelCatalog.setAllowedModelsForTesting(["new/model"])

        try MagpieAgentModelWriter.writeModel("new/model", to: agentFileURL)

        let reloadedData = try Data(contentsOf: agentFileURL)
        let json = try JSONSerialization.jsonObject(with: reloadedData) as! [String: Any]

        XCTAssertEqual(json["model"] as? String, "new/model")
        XCTAssertEqual(json["baseURL"] as? String, "http://127.0.0.1:3425/v1")
        XCTAssertEqual(json["apiKey"] as? String, "agent-secret-key")
        XCTAssertEqual(json["extraKey"] as? String, "stay")
    }

    func testWriteModelNotInCatalogThrows() throws {
        let originalJSON = """
        {
            "model": "model-1",
            "baseURL": "http://127.0.0.1:3425/v1",
            "apiKey": "agent-secret-key"
        }
        """.data(using: .utf8)!
        try originalJSON.write(to: agentFileURL)

        MagpieModelCatalog.setAllowedModelsForTesting(["model-1", "model-2"])

        XCTAssertThrowsError(try MagpieAgentModelWriter.writeModel("model-not-allowed", to: agentFileURL)) { error in
            XCTAssertEqual(error as? MagpieAgentModelWriter.Failure, .notInCatalog)
        }
    }

    func testWriteModelNotManagedThrows() throws {
        // File does not exist
        MagpieModelCatalog.setAllowedModelsForTesting(["some/model"])
        XCTAssertThrowsError(try MagpieAgentModelWriter.writeModel("some/model", to: agentFileURL)) { error in
            XCTAssertEqual(error as? MagpieAgentModelWriter.Failure, .notManaged)
        }
    }

    func testLockTimeoutThrowsBusy() throws {
        let lockURL = tempDirectory.appendingPathComponent("magpie-agent.json.lock")
        let lock = MagpieAgentWriteLock(lockFileURL: lockURL)

        let held = try lock.acquire(timeout: .seconds(1))
        defer { held.release() }

        let anotherLock = MagpieAgentWriteLock(lockFileURL: lockURL)
        XCTAssertThrowsError(try anotherLock.acquire(timeout: .milliseconds(50))) { error in
            XCTAssertEqual(error as? MagpieAgentModelWriter.Failure, .busy)
        }
    }
}

private final class MockMagpieRunner: MagpieCommandRunner, @unchecked Sendable {
    var executedArguments: [[String]] = []
    var delay: TimeInterval = 0
    var returnStatus: Int32 = 0

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> Int32 {
        executedArguments.append(arguments)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return returnStatus
    }
}
