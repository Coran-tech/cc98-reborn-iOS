import XCTest
@testable import CC98RebornShell

final class NativeTopicPagingTests: XCTestCase {
    func testInitialFailureDoesNotCreateReadingProgress() {
        let paging = NativeTopicPaging(initialPage: 3)
        XCTAssertEqual(paging.requestedPage, 3)
        XCTAssertEqual(paging.visiblePage, 3)
        XCTAssertNil(paging.displayedPage)
        XCTAssertFalse(paging.isShowingRequestedPage)
    }

    func testFailedNextPageKeepsDisplayedPageAndRetryTarget() {
        var paging = NativeTopicPaging(initialPage: 1)
        XCTAssertTrue(paging.accept(1))
        paging.request(2)
        // A transport failure never calls accept: the UI and progress stay on 1.
        XCTAssertEqual(paging.requestedPage, 2)
        XCTAssertEqual(paging.visiblePage, 1)
        XCTAssertEqual(paging.displayedPage, 1)
        XCTAssertFalse(paging.isShowingRequestedPage)
        XCTAssertTrue(paging.accept(2))
        XCTAssertEqual(paging.visiblePage, 2)
        XCTAssertEqual(paging.displayedPage, 2)
        XCTAssertTrue(paging.isShowingRequestedPage)
    }

    func testFailedPreviousPageKeepsTheCurrentPage() {
        var paging = NativeTopicPaging(initialPage: 4)
        paging.accept(4)
        paging.request(3)
        XCTAssertEqual(paging.visiblePage, 4)
        XCTAssertEqual(paging.displayedPage, 4)
        XCTAssertEqual(paging.requestedPage, 3)
    }

    func testNewFloorJumpRejectsAnOlderPageResponse() {
        var paging = NativeTopicPaging(initialPage: 1)
        paging.accept(1)
        paging.request(2)
        paging.request(8)
        XCTAssertFalse(paging.accept(2))
        XCTAssertEqual(paging.displayedPage, 1)
        XCTAssertEqual(paging.requestedPage, 8)
        XCTAssertTrue(paging.accept(8))
        XCTAssertTrue(paging.isShowingRequestedPage)
    }

    func testReturningToDisplayedPageRestoresItsScrollTarget() {
        var paging = NativeTopicPaging(initialPage: 2)
        paging.accept(2)
        paging.request(7)
        paging.request(2)
        XCTAssertTrue(paging.isShowingRequestedPage)
        XCTAssertEqual(paging.displayedPage, 2)
    }
}
