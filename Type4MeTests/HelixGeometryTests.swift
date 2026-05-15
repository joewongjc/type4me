import XCTest
@testable import Type4Me

final class HelixGeometryTests: XCTestCase {
    func test_computeParticles_returnsTwoPerPair() {
        let particles = HelixGeometry.computeParticles(
            pairs: 22, turns: 2.4, phase: 0,
            amp: 10, helixSpan: 100, cy: 19, time: 0
        )
        XCTAssertEqual(particles.count, 44)
    }

    func test_computeParticles_strandsMirrorAroundCenter() {
        let particles = HelixGeometry.computeParticles(
            pairs: 10, turns: 1.0, phase: 0,
            amp: 10, helixSpan: 100, cy: 0, time: 0
        )
        // cos(angle) and cos(angle + π) = -cos(angle) → yA + yB == 2*cy == 0
        for i in 0..<10 {
            let sum = particles[i * 2].y + particles[i * 2 + 1].y
            XCTAssertEqual(Double(sum), 0, accuracy: 0.0001, "pair \(i)")
        }
    }

    func test_baseAmplitude_silence() {
        XCTAssertEqual(HelixGeometry.baseAmplitude(audio: 0, ampMax: 100, ampScale: 0.4),
                       40, accuracy: 0.01)
    }
    func test_baseAmplitude_peak() {
        XCTAssertEqual(HelixGeometry.baseAmplitude(audio: 1, ampMax: 100, ampScale: 0.4),
                       100, accuracy: 0.01)
    }
    func test_baseAmplitude_mid() {
        // 100 * (0.4 + 0.6 * 0.5) = 70
        XCTAssertEqual(HelixGeometry.baseAmplitude(audio: 0.5, ampMax: 100, ampScale: 0.4),
                       70, accuracy: 0.01)
    }

    func test_rungIndices_count() {
        XCTAssertEqual(HelixGeometry.rungIndices(rungs: 6, pairs: 22).count, 6)
    }
    func test_rungIndices_inRangeAndSorted() {
        let idx = HelixGeometry.rungIndices(rungs: 6, pairs: 22)
        XCTAssertEqual(idx, idx.sorted())
        for i in idx { XCTAssertTrue(i >= 0 && i < 22) }
    }
    func test_rungIndices_evenlySpaced() {
        // (r+0.5)/4 → [.125,.375,.625,.875] × 19 → [2.375,7.125,11.875,16.625] → round
        XCTAssertEqual(HelixGeometry.rungIndices(rungs: 4, pairs: 20), [2, 7, 12, 17])
    }
}
