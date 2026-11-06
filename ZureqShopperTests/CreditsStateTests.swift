import XCTest
@testable import ZureqShopper

final class CreditsStateTests: XCTestCase {
    func testHealthyUsageIsOk() {
        XCTAssertEqual(Credits.state(of: Usage(used: 10, included: 100, remaining: 90)), .ok)
    }

    func testUnderFivePercentIsLow() {
        XCTAssertEqual(Credits.state(of: Usage(used: 96, included: 100, remaining: 4)), .low)
    }

    func testZeroOrExceededIsExhausted() {
        XCTAssertEqual(Credits.state(of: Usage(used: 100, included: 100, remaining: 0)), .exhausted)
        XCTAssertEqual(Credits.state(of: Usage(used: 50, included: 100, remaining: 50, exceeded: true)), .exhausted)
    }

    func testUnknownIncludedIsOk() {
        XCTAssertEqual(Credits.state(of: Usage(remaining: 3)), .ok)
    }
}
