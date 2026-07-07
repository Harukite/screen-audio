import XCTest
@testable import ScreenAudioCore

/// Smoke test for the SwiftPM scaffold.
///
/// Verifies the `ScreenAudioTests` target compiles and links against
/// `ScreenAudioCore` (the dependency edge declared in `Package.swift`).
/// Real tests arrive with the later TDD tasks (PerceivedVolume, GainRamp, ...).
final class ScaffoldSmokeTests: XCTestCase {
    func testTestTargetLinksAgainstCore() {
        // If this compiles and runs, the @testable import ScreenAudioCore wiring is intact.
        XCTAssertTrue(true, "scaffold links against ScreenAudioCore")
    }
}
