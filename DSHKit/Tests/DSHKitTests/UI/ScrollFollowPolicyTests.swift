import XCTest
import CoreGraphics
@testable import DSHKit

final class ScrollFollowPolicyTests: XCTestCase {
    func testAtBottomOnlyWithinEightPoints() {
        XCTAssertTrue(ScrollFollowPolicy.isAtBottom(distanceFromBottom: 0))
        XCTAssertTrue(ScrollFollowPolicy.isAtBottom(distanceFromBottom: 8))
        XCTAssertFalse(ScrollFollowPolicy.isAtBottom(distanceFromBottom: 8.5))
        XCTAssertFalse(ScrollFollowPolicy.isAtBottom(distanceFromBottom: 48))
    }

    func testBottomRestoresFollowWhenNotDragging() {
        XCTAssertEqual(
            ScrollFollowPolicy.action(distanceFromBottom: 2, drag: .none, followsLatest: false),
            .follow
        )
    }

    func testDraggingUpNeverRefollowsEvenAtBottom() {
        XCTAssertEqual(
            ScrollFollowPolicy.action(distanceFromBottom: 0, drag: .up, followsLatest: true),
            .stopFollow
        )
        XCTAssertEqual(
            ScrollFollowPolicy.action(distanceFromBottom: 2, drag: .up, followsLatest: false),
            .stopFollow
        )
    }

    func testDraggingDownAtBottomRefollows() {
        XCTAssertEqual(
            ScrollFollowPolicy.action(distanceFromBottom: 1, drag: .down, followsLatest: false),
            .follow
        )
    }

    /// 贴底时轻微上划 = 内容被拽出边界（距离为负）。这时用户意图是"离开底部看历史"，
    /// 不能因为负数仍满足 isAtBottom 就把跟随重新打开 —— 那就是"滑一下被弹回去"。
    func testOverscrollAboveBottomStopsFollow() {
        XCTAssertEqual(
            ScrollFollowPolicy.action(distanceFromBottom: -5, drag: .none, followsLatest: true),
            .stopFollow
        )
        XCTAssertEqual(
            ScrollFollowPolicy.action(distanceFromBottom: -0.5, drag: .none, followsLatest: true),
            .stopFollow
        )
    }

    /// 回归：真正贴底（距离正好 0）时，不拖动的状态下仍应恢复跟随。
    func testExactBottomStillRefollows() {
        XCTAssertEqual(
            ScrollFollowPolicy.action(distanceFromBottom: 0, drag: .none, followsLatest: false),
            .follow
        )
    }

    func testLeavingBottomStopsFollow() {
        XCTAssertEqual(
            ScrollFollowPolicy.action(distanceFromBottom: 30, drag: .up, followsLatest: true),
            .stopFollow
        )
    }

    func testGrowthPinsOnlyWhileFollowing() {
        XCTAssertEqual(
            ScrollFollowPolicy.action(distanceFromBottom: 30, drag: .none, followsLatest: true),
            .pinToBottom
        )
        XCTAssertEqual(
            ScrollFollowPolicy.action(distanceFromBottom: 30, drag: .none, followsLatest: false),
            .keep
        )
    }

    func testAutoScrollForbiddenWhileDraggingEvenIfForced() {
        XCTAssertFalse(ScrollFollowPolicy.canAutoScroll(isDragging: true, followsLatest: true, force: true))
        XCTAssertFalse(ScrollFollowPolicy.canAutoScroll(isDragging: true, followsLatest: false, force: false))
    }

    func testAutoScrollAllowedWhenFollowingOrForced() {
        XCTAssertTrue(ScrollFollowPolicy.canAutoScroll(isDragging: false, followsLatest: true, force: false))
        XCTAssertTrue(ScrollFollowPolicy.canAutoScroll(isDragging: false, followsLatest: false, force: true))
        XCTAssertFalse(ScrollFollowPolicy.canAutoScroll(isDragging: false, followsLatest: false, force: false))
    }
}
