import XCTest

#if canImport(cmux_DEV)
@testable import Kolt_DEV
#elseif canImport(cmux)
@testable import Kolt
#endif

final class SidebarWidthPolicyTests: XCTestCase {
    func testContentViewClampAllowsNarrowSidebarBelowLegacyMinimum() {
        XCTAssertEqual(
            ContentView.clampedSidebarWidth(184, maximumWidth: 600),
            184,
            accuracy: 0.001
        )
    }
}
