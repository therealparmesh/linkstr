import XCTest

@testable import linkstr

@MainActor
final class LinkstrToastTests: XCTestCase {
  func testOldToastCannotDismissReplacementRelayAlert() throws {
    let presenter = LinkstrToastPresenter()
    presenter.show("note saved", isSuccess: true)
    let previous = try XCTUnwrap(presenter.message?.id)
    presenter.show("offline", isSuccess: false, opensRelaySettings: true)
    let current = try XCTUnwrap(presenter.message?.id)

    presenter.dismiss(previous)
    XCTAssertEqual(presenter.message?.id, current)
    presenter.dismiss(current, tapped: true)
    XCTAssertNil(presenter.message)
    XCTAssertNotNil(presenter.relaySettingsRequest)
  }
}
