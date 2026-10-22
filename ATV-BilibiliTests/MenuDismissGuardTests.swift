//
//  MenuDismissGuardTests.swift
//  ATV-BilibiliTests
//

@testable import ATV_Bilibili
import XCTest

/// 返回键防误触：进度条可见或刚收起时，第一次 Menu 不应退出播放器。
final class MenuDismissGuardTests: XCTestCase {
    private let grace: CFTimeInterval = 1.0

    private func makeGuard() -> MenuDismissGuard {
        MenuDismissGuard(graceInterval: grace)
    }

    func test_exitsImmediatelyWhenTransportBarHasBeenHiddenForLong() {
        var guardState = makeGuard()
        guardState.updateTransportBarVisibility(true, now: 0)
        guardState.updateTransportBarVisibility(false, now: 5)

        XCTAssertFalse(guardState.shouldShieldDismissPress(now: 6.5))
    }

    func test_firstPressWhileBarVisibleIsShieldedAndSecondExits() {
        var guardState = makeGuard()
        guardState.updateTransportBarVisibility(true, now: 0)

        XCTAssertTrue(guardState.shouldShieldDismissPress(now: 2))
        XCTAssertFalse(guardState.shouldShieldDismissPress(now: 2.3), "同一轮可见态第二次按下应放行退出")
    }

    func test_secondPressExitsEvenIfBarStaysVisible() {
        var guardState = makeGuard()
        guardState.updateTransportBarVisibility(true, now: 0)

        XCTAssertTrue(guardState.shouldShieldDismissPress(now: 2))
        // 系统没有收起进度条也不能永远拦住退出
        XCTAssertFalse(guardState.shouldShieldDismissPress(now: 3))
    }

    func test_pressRightAfterAutoHideIsShieldedOnce() {
        var guardState = makeGuard()
        guardState.updateTransportBarVisibility(true, now: 0)
        guardState.updateTransportBarVisibility(false, now: 5)

        XCTAssertTrue(guardState.shouldShieldDismissPress(now: 5.3), "自动收起瞬间的返回应只收进度条")
        XCTAssertFalse(guardState.shouldShieldDismissPress(now: 5.6), "紧接着再按应退出")
    }

    func test_pressAfterGraceExits() {
        var guardState = makeGuard()
        guardState.updateTransportBarVisibility(true, now: 0)
        guardState.updateTransportBarVisibility(false, now: 5)

        XCTAssertFalse(guardState.shouldShieldDismissPress(now: 5 + grace))
    }

    func test_shieldedVisiblePressMakesFollowUpHidePressExit() {
        var guardState = makeGuard()
        guardState.updateTransportBarVisibility(true, now: 0)
        XCTAssertTrue(guardState.shouldShieldDismissPress(now: 2))
        // 系统随后才收起进度条：这次收起是被上一次按键吞掉的结果，下一次 Menu 直接退出
        guardState.updateTransportBarVisibility(false, now: 2.2)

        XCTAssertFalse(guardState.shouldShieldDismissPress(now: 2.4))
    }

    func test_hideByUserPressWithoutShieldStillGetsOneGraceShield() {
        var guardState = makeGuard()
        guardState.updateTransportBarVisibility(true, now: 0)
        // 系统自己消费了收起动作，未走 shouldDismiss
        guardState.updateTransportBarVisibility(false, now: 2)

        XCTAssertTrue(guardState.shouldShieldDismissPress(now: 2.2))
        XCTAssertFalse(guardState.shouldShieldDismissPress(now: 2.5))
    }

    func test_initialHiddenCallbackDoesNotStartGrace() {
        var guardState = makeGuard()
        guardState.updateTransportBarVisibility(false, now: 0)

        XCTAssertFalse(guardState.shouldShieldDismissPress(now: 0.2), "进度条从未出现时不应拦截退出")
    }

    func test_repeatedHiddenCallbacksDoNotRestartGrace() {
        var guardState = makeGuard()
        guardState.updateTransportBarVisibility(true, now: 0)
        guardState.updateTransportBarVisibility(false, now: 5)
        guardState.updateTransportBarVisibility(false, now: 5.5)

        XCTAssertFalse(guardState.shouldShieldDismissPress(now: 6.2))
    }

    func test_barVisibleAgainResetsShieldState() {
        var guardState = makeGuard()
        guardState.updateTransportBarVisibility(true, now: 0)
        guardState.updateTransportBarVisibility(false, now: 5)
        XCTAssertTrue(guardState.shouldShieldDismissPress(now: 5.2))

        guardState.updateTransportBarVisibility(true, now: 6)
        XCTAssertTrue(guardState.shouldShieldDismissPress(now: 9), "重新打开进度条后应重新获得一次保护")
        XCTAssertFalse(guardState.shouldShieldDismissPress(now: 9.2))
    }
}
