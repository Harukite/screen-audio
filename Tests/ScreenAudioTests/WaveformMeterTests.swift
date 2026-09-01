import XCTest
@testable import ScreenAudioCore

final class WaveformMeterTests: XCTestCase {
    func testSourceLevelKeepsRangeAndClamps() {
        XCTAssertEqual(WaveformMeter.sourceLevel(fromRMS: -0.1), 0)
        XCTAssertEqual(WaveformMeter.sourceLevel(fromRMS: 0.05), 0.3, accuracy: 0.0001)
        XCTAssertEqual(WaveformMeter.sourceLevel(fromRMS: 1), 1)
    }

    func testDisplayLevelBoostsQuietAudioAndClamps() {
        let quiet = WaveformMeter.displayLevel(fromSourceLevel: 0.06)
        XCTAssertGreaterThan(quiet, 0.2)
        XCTAssertEqual(WaveformMeter.displayLevel(fromSourceLevel: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(WaveformMeter.displayLevel(fromSourceLevel: 2), 1, accuracy: 0.0001)
    }

    func testPixelLevelHasVisibleBaselineAndFiveLevelCeiling() {
        XCTAssertEqual(WaveformMeter.pixelLevel(displayLevel: 0, weight: 1), 1)
        XCTAssertEqual(WaveformMeter.pixelLevel(displayLevel: 1, weight: 1), 5)
        XCTAssertEqual(WaveformMeter.pixelLevel(displayLevel: 1, weight: 2), 5)
    }

    func testDecayCoefficientPreservesTimeConstantAcrossRates() {
        let base: Float = 0.1
        let adjusted = WaveformMeter.decayCoefficient(base: base, sourceRate: 30, displayRate: 24)
        let afterThirtyFrames = pow(1 - base, 30)
        let afterTwentyFourFrames = pow(1 - adjusted, 24)
        XCTAssertEqual(afterTwentyFourFrames, afterThirtyFrames, accuracy: 0.0001)
    }

    func testIconLayoutCentersThreeFiveSevenColumns() {
        for count in [3, 5, 7] {
            let layout = WaveformMeter.iconLayout(barCount: count)
            XCTAssertEqual(layout.canvasWidth, 24)
            XCTAssertEqual(layout.canvasHeight, 18)
            XCTAssertEqual(layout.barCount, count)
            XCTAssertEqual(layout.startX, (layout.canvasWidth - layout.totalBarWidth) / 2)
            XCTAssertLessThanOrEqual(layout.startX + layout.totalBarWidth, layout.canvasWidth)
            XCTAssertGreaterThanOrEqual(layout.startX, 0)
            XCTAssertEqual(layout.barWidth, 2)
        }
        XCTAssertEqual(WaveformMeter.iconLayout(barCount: 3).totalBarWidth, 12)
        XCTAssertEqual(WaveformMeter.iconLayout(barCount: 5).totalBarWidth, 18)
        XCTAssertEqual(WaveformMeter.iconLayout(barCount: 7).totalBarWidth, 20)
    }

    func testBarRectsStayOnPixelGrid() {
        let layout = WaveformMeter.iconLayout(barCount: 3)
        let rects = WaveformMeter.barRects(levels: [1, 5, 3], layout: layout)
        XCTAssertEqual(rects.count, 9)
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.x, layout.startX)
            XCTAssertLessThanOrEqual(rect.x + rect.width, layout.startX + layout.totalBarWidth)
            XCTAssertGreaterThanOrEqual(rect.y, layout.baselineY)
            XCTAssertLessThan(rect.y + rect.height, layout.canvasHeight)
        }
        XCTAssertEqual(rects.first?.width, 2)
        XCTAssertEqual(rects.first?.height, 2)
    }

    func testSteppedLevelJumpsUpThenFallsOnePixelAtATime() {
        let jump = WaveformMeter.steppedLevel(
            current: 1,
            target: 4,
            framesUntilFall: 1,
            fallInterval: 2
        )
        XCTAssertEqual(jump.level, 4)
        XCTAssertEqual(jump.framesUntilFall, 2)

        let hold = WaveformMeter.steppedLevel(
            current: 4,
            target: 1,
            framesUntilFall: 2,
            fallInterval: 2
        )
        XCTAssertEqual(hold.level, 4)
        XCTAssertEqual(hold.framesUntilFall, 1)

        let fall = WaveformMeter.steppedLevel(
            current: 4,
            target: 1,
            framesUntilFall: 1,
            fallInterval: 2
        )
        XCTAssertEqual(fall.level, 3)
        XCTAssertEqual(fall.framesUntilFall, 2)
    }

    func testColumnTargetStaysInPixelRangeAndStaggers() {
        let loud = WaveformMeter.columnTarget(displayLevel: 1, weight: 1, column: 0, tick: 0)
        let dipped = WaveformMeter.columnTarget(displayLevel: 1, weight: 1, column: 0, tick: 4)
        XCTAssertEqual(loud, 5)
        XCTAssertEqual(dipped, 4)
        XCTAssertEqual(WaveformMeter.columnTarget(displayLevel: 0, weight: 1, column: 0, tick: 4), 1)
    }

    func testBounceParticlesRiseAboveBarsAndClearAtBaseline() {
        let layout = WaveformMeter.iconLayout(barCount: 3)
        XCTAssertTrue(
            WaveformMeter.bounceParticles(levels: [1, 1, 1], rising: [false, false, false], tick: 0, layout: layout).isEmpty
        )

        let particles = WaveformMeter.bounceParticles(
            levels: [1, 4, 3],
            rising: [false, true, false],
            tick: 0,
            layout: layout
        )
        XCTAssertFalse(particles.isEmpty)
        let barTop = layout.baselineY + 3 * (layout.pixelHeight + layout.rowGap) + layout.pixelHeight
        XCTAssertTrue(particles.contains(where: { $0.y >= barTop }))
        for particle in particles {
            XCTAssertEqual(particle.size, 1)
            XCTAssertGreaterThanOrEqual(particle.x, 0)
            XCTAssertGreaterThanOrEqual(particle.y, 0)
            XCTAssertLessThanOrEqual(particle.x + particle.size, layout.canvasWidth)
            XCTAssertLessThanOrEqual(particle.y + particle.size, layout.canvasHeight)
            XCTAssertGreaterThan(particle.alpha, 0)
            XCTAssertLessThanOrEqual(particle.alpha, 1)
        }
    }

    func testBounceParticlesStaggerVerticallyAcrossColumns() {
        let layout = WaveformMeter.iconLayout(barCount: 3)
        let tickZero = WaveformMeter.bounceParticles(
            levels: [4, 4, 4],
            rising: [false, false, false],
            tick: 0,
            layout: layout
        )
        let later = WaveformMeter.bounceParticles(
            levels: [4, 4, 4],
            rising: [false, false, false],
            tick: 3,
            layout: layout
        )
        XCTAssertGreaterThan(Set(tickZero.map(\.y)).count, 1)
        XCTAssertNotEqual(Set(tickZero.map(\.y)), Set(later.map(\.y)))
    }

    func testMouseWheelStepsVolumeAndPreciseScrollAccumulates() {
        var accumulator = WaveformMeter.ScrollAccumulator()
        XCTAssertEqual(
            accumulator.consume(scrollingDeltaY: 1, isPrecise: false, fineControl: false),
            4
        )
        XCTAssertEqual(
            accumulator.consume(scrollingDeltaY: -1, isPrecise: false, fineControl: true),
            -1
        )
        XCTAssertEqual(accumulator.remainder, 0, accuracy: 0.0001)

        var precise = WaveformMeter.ScrollAccumulator()
        XCTAssertEqual(
            precise.consume(scrollingDeltaY: 0.5, isPrecise: true, fineControl: false),
            0
        )
        XCTAssertEqual(
            precise.consume(scrollingDeltaY: 1.2, isPrecise: true, fineControl: false),
            1
        )
        XCTAssertEqual(precise.remainder, 0.1, accuracy: 0.0001)
        XCTAssertEqual(
            precise.consume(scrollingDeltaY: -3.3, isPrecise: true, fineControl: false),
            -2
        )
    }
}
