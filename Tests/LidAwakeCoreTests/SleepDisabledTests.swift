import XCTest
@testable import LidAwakeCore

final class SleepDisabledTests: XCTestCase {
    func testReadsEnabledSleepDisabledValue() throws {
        let output = """
        System-wide power settings:
         SleepDisabled        1
        Currently in use:
         sleep                1
        """

        XCTAssertEqual(try sleepDisabledValue(fromPMSetOutput: output), 1)
    }

    func testMissingSleepDisabledLineMeansDisabledInValidPMSetOutput() throws {
        let output = """
        System-wide power settings:
        Currently in use:
         sleep                1
        """

        XCTAssertEqual(try sleepDisabledValue(fromPMSetOutput: output), 0)
    }

    func testRejectsInvalidSleepDisabledValue() {
        let output = """
        System-wide power settings:
         SleepDisabled        unknown
        Currently in use:
         sleep                1
        """

        XCTAssertThrowsError(try sleepDisabledValue(fromPMSetOutput: output))
    }

    func testRejectsUnexpectedPMSetOutput() {
        XCTAssertThrowsError(try sleepDisabledValue(fromPMSetOutput: "SleepDisabled 1"))
    }
}
