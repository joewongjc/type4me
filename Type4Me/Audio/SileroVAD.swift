import Foundation
import OnnxRuntimeBindings
import os

/// Wraps the Silero VAD v5 ONNX model for real-time voice activity detection.
/// Not thread-safe — call from a single queue (the audio capture queue).
final class SileroVAD {

    /// Silero VAD requires one of: 512, 1024, 1536 samples per chunk @16kHz.
    static let chunkSize = 1536
    private static let sampleRate: Int64 = 16000
    private static let stateSize = 128  // [2, 1, 64] = 128 floats

    private let env: ORTEnv
    private let session: ORTSession
    private var hState: [Float]
    private var cState: [Float]

    private let logger = Logger(subsystem: "com.type4me.vad", category: "SileroVAD")

    init(modelPath: String) throws {
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        hState = [Float](repeating: 0, count: Self.stateSize)
        cState = [Float](repeating: 0, count: Self.stateSize)
        logger.info("Silero VAD loaded from \(modelPath)")
    }

    /// Convenience initializer: loads model from app bundle.
    convenience init() throws {
        guard let url = Bundle.main.url(forResource: "silero_vad", withExtension: "onnx") else {
            throw SileroVADError.modelNotFound
        }
        try self.init(modelPath: url.path)
    }

    /// Run VAD on a chunk of Float32 audio samples.
    /// - Parameter chunk: Exactly `chunkSize` (1536) Float32 samples, range [-1, 1].
    /// - Returns: Speech probability in [0, 1].
    func process(_ chunk: [Float]) throws -> Float {
        precondition(chunk.count == Self.chunkSize,
                     "SileroVAD requires \(Self.chunkSize) samples, got \(chunk.count)")

        // Input audio: [1, chunkSize]
        let inputData = NSMutableData(bytes: chunk, length: chunk.count * MemoryLayout<Float>.size)
        let inputTensor = try ORTValue(
            tensorData: inputData,
            elementType: .float,
            shape: [1, NSNumber(value: Self.chunkSize)]
        )

        // Sample rate: [1]
        var sr = Self.sampleRate
        let srData = NSMutableData(bytes: &sr, length: MemoryLayout<Int64>.size)
        let srTensor = try ORTValue(tensorData: srData, elementType: .int64, shape: [1])

        // LSTM hidden state: [2, 1, 64]
        let hData = NSMutableData(bytes: &hState, length: hState.count * MemoryLayout<Float>.size)
        let hTensor = try ORTValue(tensorData: hData, elementType: .float, shape: [2, 1, 64])

        // LSTM cell state: [2, 1, 64]
        let cData = NSMutableData(bytes: &cState, length: cState.count * MemoryLayout<Float>.size)
        let cTensor = try ORTValue(tensorData: cData, elementType: .float, shape: [2, 1, 64])

        let inputs: [String: ORTValue] = [
            "input": inputTensor,
            "sr": srTensor,
            "h": hTensor,
            "c": cTensor,
        ]

        let outputNames: Set<String> = ["output", "hn", "cn"]
        let results = try session.run(
            withInputs: inputs,
            outputNames: outputNames,
            runOptions: nil
        )

        // Extract speech probability
        guard let outputValue = results["output"] else {
            throw SileroVADError.missingOutput("output")
        }
        let outputData = try outputValue.tensorData() as Data
        let probability = outputData.withUnsafeBytes { $0.load(as: Float.self) }

        // Update LSTM states for next call
        if let hnValue = results["hn"] {
            let hnData = try hnValue.tensorData() as Data
            hnData.withUnsafeBytes { ptr in
                let floats = ptr.bindMemory(to: Float.self)
                for i in 0..<Self.stateSize { hState[i] = floats[i] }
            }
        }
        if let cnValue = results["cn"] {
            let cnData = try cnValue.tensorData() as Data
            cnData.withUnsafeBytes { ptr in
                let floats = ptr.bindMemory(to: Float.self)
                for i in 0..<Self.stateSize { cState[i] = floats[i] }
            }
        }

        return probability
    }

    /// Reset LSTM states. Call when starting a new recording session.
    func reset() {
        hState = [Float](repeating: 0, count: Self.stateSize)
        cState = [Float](repeating: 0, count: Self.stateSize)
    }
}

enum SileroVADError: Error, LocalizedError {
    case modelNotFound
    case missingOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            "silero_vad.onnx not found in app bundle"
        case .missingOutput(let name):
            "Missing output tensor: \(name)"
        }
    }
}
