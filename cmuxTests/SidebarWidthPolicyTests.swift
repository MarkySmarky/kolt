import XCTest

#if canImport(Kolt_DEV)
@testable import Kolt_DEV
#elseif canImport(Kolt)
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
