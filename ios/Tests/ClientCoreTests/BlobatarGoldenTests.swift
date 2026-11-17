import Foundation
import Testing
@testable import ClientCore

/// The port's contract with the original: the same name must produce the same
/// creature.
///
/// Fixtures are generated from the published `blobatar` package (2.7.0 — the
/// seed→look mapping is frozen for the major, and 2.8.0 only added an option
/// and an adapter). Path data is compared numerically rather than as strings:
/// both sides round to two decimals, and a float one ulp apart can land the
/// other side of a rounding boundary without the drawing differing at all.
///
/// Palettes are compared exactly — those are integers per channel.
@Suite @MainActor struct BlobatarGoldenTests {
    private struct Golden: Decodable {
        let version: String
        let cases: [Case]
    }

    private struct Case: Decodable {
        let seed: String
        let bg: String
        let head: String
        let eye: String
        let petals: [[Double]]
        let extras: [String]
        let body: String
        let eyes: [String]
    }

    private let tolerance = 0.02

    private func golden() throws -> Golden {
        let url = try #require(Bundle.module.url(forResource: "blobatar-golden",
                                                 withExtension: "json",
                                                 subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    @Test func everySeedMatchesTheOfficialRender() throws {
        let golden = try golden()
        #expect(golden.cases.count >= 20, "fixture corpus is too small to mean anything")

        for entry in golden.cases {
            let layout = BlobatarComposer.layout(seed: entry.seed)

            #expect(layout.palette.bg == entry.bg, "bg for “\(entry.seed)”")
            #expect(layout.palette.head == entry.head, "head for “\(entry.seed)”")
            #expect(layout.palette.eye == entry.eye, "eye for “\(entry.seed)”")

            #expect(layout.petals.count == entry.petals.count, "petal count for “\(entry.seed)”")
            for (index, petal) in layout.petals.enumerated() where index < entry.petals.count {
                expectClose(petal.cx, entry.petals[index][0], "petal cx “\(entry.seed)”")
                expectClose(petal.cy, entry.petals[index][1], "petal cy “\(entry.seed)”")
                expectClose(petal.r, entry.petals[index][2], "petal r “\(entry.seed)”")
            }

            #expect(layout.extras.count == entry.extras.count, "extra count for “\(entry.seed)”")
            for (index, extra) in layout.extras.enumerated() where index < entry.extras.count {
                expectPath(extra.d, entry.extras[index], "extra \(index) “\(entry.seed)”")
            }

            expectPath(layout.bodyPath.d, entry.body, "body “\(entry.seed)”")

            let eyes = layout.eyes.map { eye in
                BlobatarPathBuilder.superellipse(cx: eye.cx, cy: eye.cy,
                                                 rx: eye.rx, ry: eye.ry,
                                                 n: eye.n, rot: eye.rot).d
            }
            #expect(eyes.count == entry.eyes.count)
            for index in 0..<min(eyes.count, entry.eyes.count) {
                expectPath(eyes[index], entry.eyes[index], "eye \(index) “\(entry.seed)”")
            }
        }
    }

    @Test func normalizationMatchesTheOriginal() throws {
        let golden = try golden()
        // The corpus carries “Alain00” and “  alain00  ”; if normalization
        // drifted, their palettes would diverge from “alain00”.
        let plain = try #require(golden.cases.first { $0.seed == "alain00" })
        for variant in ["Alain00", "  alain00  "] {
            let layout = BlobatarComposer.layout(seed: variant)
            #expect(layout.palette.head == plain.head, "head for “\(variant)”")
            #expect(layout.palette.eye == plain.eye, "eye for “\(variant)”")
        }
    }

    @Test func everyExpressionBakesInsideTheFrame() {
        for pose in BlobatarExpressions.roster {
            #expect(pose.esx > 0 && pose.esy > 0)
            for eye in pose.baked([
                BlobatarEye(cx: 40, cy: 50, rx: 6, ry: 12, n: 4, rot: 5),
                BlobatarEye(cx: 60, cy: 50, rx: 6, ry: 12, n: 4, rot: 5),
            ]) {
                #expect(eye.rx.isFinite && eye.ry.isFinite && eye.rx > 0 && eye.ry > 0)
                #expect(eye.cx.isFinite && eye.cy.isFinite && eye.rot.isFinite)
            }
        }
    }

    @Test func idleFrameIsFiniteAndBlinksClose() {
        let traits = BlobatarTraits(seed: "alain00")
        let seeds = BlobatarIdleSeeds(traits: traits)
        for step in stride(from: 0.0, through: 12_000, by: 37) {
            let frame = BlobatarIdle.frame(seeds, time: step, amplitude: 1, shakeAmount: 1)
            #expect(frame.breathe.0.isFinite && frame.bob.isFinite)
            #expect(frame.saccade.0.isFinite && frame.saccade.1.isFinite)
            #expect(frame.blink <= 1 && frame.blink > 0)
            #expect(frame.rockp >= -1 && frame.rockp <= 1)
        }
    }

    private func expectPath(_ actual: String, _ expected: String, _ label: String) {
        let left = numbers(in: actual)
        let right = numbers(in: expected)
        #expect(left.count == right.count, "\(label): number count \(left.count) vs \(right.count)")
        for index in 0..<min(left.count, right.count) {
            expectClose(left[index], right[index], "\(label) value \(index)")
        }
    }

    private func expectClose(_ actual: Double, _ expected: Double, _ label: String) {
        if abs(actual - expected) > tolerance {
            Issue.record("\(label): \(actual) vs \(expected) (tolerance \(tolerance))")
        }
    }

    private func numbers(in path: String) -> [Double] {
        var values: [Double] = []
        var buffer = ""
        for character in path {
            if character.isNumber || character == "-" || character == "." {
                buffer.append(character)
            } else if !buffer.isEmpty {
                values.append(Double(buffer) ?? .nan)
                buffer = ""
            }
        }
        if !buffer.isEmpty { values.append(Double(buffer) ?? .nan) }
        return values
    }
}
