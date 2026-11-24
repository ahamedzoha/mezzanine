import Foundation
import Testing
@testable import MezzanineKit

@Suite("Volume boost")
struct VolumeLevelTests {
    /// Builds the boost for a run of volumes, as the player does, and counts the rebuilds.
    func rebuilds(_ percents: [Double], from start: Double = 0, passthrough: Bool = false) -> Int {
        var current = start
        var count = 0
        for percent in percents {
            let next = VolumeLevel(percent: percent).builtInBoostDB(current: current, passthrough: passthrough)
            if next != current { count += 1 }
            current = next
        }
        return count
    }

    @Test func stepsRoundUp() {
        let step = VolumeLevel.boostStepDB
        func built(_ percent: Double) -> Double {
            (VolumeLevel(percent: percent).builtInBoostDB(current: 0, passthrough: true) / step).rounded()
        }
        #expect(built(0) == 0)
        #expect(built(100) == 0)
        #expect(built(110) == 1)
        #expect(built(141) == 1)
        #expect(built(150) == 2)
        #expect(built(200) == 2)
        #expect(built(210) == 3)
        #expect(built(400) == 4)
    }

    /// The owner's 110, 120, 130 and back on 2026-11-24 rebuilt the session six times.
    @Test func upAndBackRebuildsOnce() {
        #expect(rebuilds([110, 120, 130, 120, 110, 100]) == 1)
        #expect(rebuilds([110, 100, 110, 100, 50, 110]) == 1)
        // The whole range, up and down: one per step up, and down again a step late.
        let up = stride(from: 100.0, through: 400, by: 10)
        #expect(rebuilds(Array(up)) == 4)
        #expect(rebuilds(Array(up) + up.reversed()) == 7)
    }

    /// An untouched profile passes Atmos through again at 100 %.
    @Test func passthroughReturnsToNoBoost() {
        let step = VolumeLevel.boostStepDB
        #expect(VolumeLevel(percent: 100).builtInBoostDB(current: step, passthrough: true) == 0)
        #expect(VolumeLevel(percent: 40).builtInBoostDB(current: step, passthrough: true) == 0)
        #expect(VolumeLevel(percent: 100).builtInBoostDB(current: step, passthrough: false) == step)
        #expect(VolumeLevel(percent: 100).builtInBoostDB(current: 2 * step, passthrough: false) == 0)
    }

    /// Built-in boost times the player's volume is always the level asked for.
    @Test func loudnessIsExact() {
        var current = 0.0
        let run = Array(stride(from: 0.0, through: 400, by: 10))
        for percent in run + run.reversed() {
            let level = VolumeLevel(percent: percent)
            current = level.builtInBoostDB(current: current, passthrough: false)
            let gain = level.playerVolume(builtInBoostDB: current) * pow(10, current / 20)
            #expect(abs(gain - percent / 100) < 1e-5, "\(percent) %")
        }
    }

    /// Before a rebuild lands the player's volume never exceeds its maximum.
    @Test func playerVolumeIsCapped() {
        #expect(VolumeLevel(percent: 200).playerVolume(builtInBoostDB: 0) == 1)
        #expect(VolumeLevel(percent: 100).playerVolume(builtInBoostDB: 0) == 1)
        #expect(VolumeLevel(percent: 0).playerVolume(builtInBoostDB: 3) == 0)
    }
}
