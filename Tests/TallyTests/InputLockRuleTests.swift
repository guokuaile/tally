import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import Tally

/// 清洁锁的判定、掩码与倒计时文案（docs/monitors.md「清洁锁」）。
/// 真拦截器不在这里建：测试进程挂上它，会把跑测试这台机器的键盘一起锁住。
final class InputLockRuleTests: XCTestCase {

    private let keyDown = CGEventType.keyDown.rawValue
    private let t = Int64(kVK_ANSI_T)
    private let chord: CGEventFlags = [.maskAlternate, .maskShift]

    private let keyUp = CGEventType.keyUp.rawValue

    private func verdict(_ type: UInt32, keyCode: Int64 = 0, modifiers: CGEventFlags = [], auxSubtype: Int? = nil,
                         chordHeld: Bool = false, mode: InputLockRule.Mode) -> InputLockRule.Verdict {
        InputLockRule.verdict(type: type, keyCode: keyCode, modifiers: modifiers, auxSubtype: auxSubtype,
                              chordHeld: chordHeld, mode: mode)
    }

    func testChordPressOnlyArmsAndReleaseUnlocksInBothModes() {
        for mode in [InputLockRule.Mode.keyboard, .all] {
            XCTAssertEqual(verdict(keyDown, keyCode: t, modifiers: chord, mode: mode), .chord,
                           "按下只记账不解锁：当场拆拦截器的话，按住不放补发的重复键全漏出去")
            XCTAssertEqual(verdict(keyDown, keyCode: t, modifiers: chord, chordHeld: true, mode: mode), .chord, "按住时补发的重复键照样吞")
            XCTAssertEqual(verdict(keyUp, keyCode: t, modifiers: chord, chordHeld: true, mode: mode), .unlock, "松开 T 才解锁")
        }
    }

    func testReleaseUnlocksWhateverOrderTheKeysComeUp() {
        XCTAssertEqual(verdict(keyUp, keyCode: t, chordHeld: true, mode: .all), .unlock, "先松修饰键再松 T 也要能解")
        XCTAssertEqual(verdict(keyDown, keyCode: t, modifiers: .maskAlternate, chordHeld: true, mode: .all), .swallow,
                       "先松了 ⇧ 之后补发的重复键不再是组合，照样吞")
    }

    func testReleaseWithoutChordDoesNotUnlock() {
        XCTAssertEqual(verdict(keyUp, keyCode: t, modifiers: chord, mode: .all), .swallow, "没按过组合，松开 T 不算")
        XCTAssertEqual(verdict(keyUp, keyCode: Int64(kVK_ANSI_R), chordHeld: true, mode: .all), .swallow, "松开的不是 T 不算")
    }

    func testChordNeedsExactlyOptionShift() {
        XCTAssertEqual(verdict(keyDown, keyCode: t, mode: .all), .swallow, "单按 T 不算组合")
        XCTAssertEqual(verdict(keyDown, keyCode: t, modifiers: .maskAlternate, mode: .all), .swallow, "少一个修饰键不算")
        XCTAssertEqual(verdict(keyDown, keyCode: t, modifiers: [.maskAlternate, .maskShift, .maskCommand], mode: .all), .swallow,
                       "多一个修饰键不算：抹布压住一片时不该误开")
        XCTAssertEqual(verdict(keyDown, keyCode: Int64(kVK_ANSI_R), modifiers: chord, mode: .all), .swallow, "别的键不算")
    }

    func testCapsLockAndFnDoNotBlockTheChord() {
        XCTAssertEqual(verdict(keyDown, keyCode: t, modifiers: [.maskAlternate, .maskShift, .maskAlphaShift, .maskSecondaryFn],
                               mode: .keyboard), .chord, "擦的时候大写锁定很可能被按开，不能因此解不了锁")
    }

    func testKeysAreSwallowedInBothModes() {
        for mode in [InputLockRule.Mode.keyboard, .all] {
            XCTAssertEqual(verdict(keyDown, keyCode: Int64(kVK_ANSI_A), mode: mode), .swallow)
            XCTAssertEqual(verdict(CGEventType.keyUp.rawValue, keyCode: Int64(kVK_ANSI_A), mode: mode), .swallow)
            XCTAssertEqual(verdict(CGEventType.flagsChanged.rawValue, modifiers: .maskCommand, mode: mode), .swallow)
            XCTAssertEqual(verdict(InputLockRule.systemDefined, auxSubtype: InputLockRule.auxControlSubtype, mode: mode), .swallow,
                           "亮度、音量这些功能键")
        }
    }

    func testOtherSystemDefinedOnlySwallowedWhenEverythingIsLocked() {
        // 子类型 7 是鼠标按键状态，跟着每次点击来：只锁键盘时吞它等于动了触控板
        XCTAssertEqual(verdict(InputLockRule.systemDefined, auxSubtype: 7, mode: .keyboard), .pass)
        XCTAssertEqual(verdict(InputLockRule.systemDefined, auxSubtype: nil, mode: .keyboard), .pass)
        XCTAssertEqual(verdict(InputLockRule.systemDefined, auxSubtype: 7, mode: .all), .swallow)
    }

    func testPointerEventsOnlySwallowedWhenEverythingIsLocked() {
        // 29 是手势，CGEventType 里没有名字
        let pointer = [CGEventType.leftMouseDown.rawValue, CGEventType.leftMouseUp.rawValue, CGEventType.rightMouseDown.rawValue,
                       CGEventType.leftMouseDragged.rawValue, CGEventType.scrollWheel.rawValue, 29]
        for type in pointer {
            XCTAssertEqual(verdict(type, mode: .keyboard), .pass)
            XCTAssertEqual(verdict(type, mode: .all), .swallow)
        }
    }

    func testCursorMovementOnlySwallowedWhenEverythingIsLocked() {
        XCTAssertEqual(verdict(CGEventType.mouseMoved.rawValue, mode: .keyboard), .pass)
        XCTAssertEqual(verdict(CGEventType.mouseMoved.rawValue, mode: .all), .swallow, "擦触控板时光标不该跟着乱跑")
    }

    func testOnlyMovesAndDragsPullTheCursorBack() {
        for type in [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged] {
            XCTAssertTrue(InputLockRule.movesCursor(type.rawValue))
        }
        for type in [CGEventType.leftMouseDown.rawValue, CGEventType.scrollWheel.rawValue, CGEventType.keyDown.rawValue, 29] {
            XCTAssertFalse(InputLockRule.movesCursor(type), "不带动光标的事件不用拽")
        }
    }

    func testKeyboardMaskLeavesPointerEventsOutOfTheCallback() {
        let mask = InputLockRule.mask(for: .keyboard)
        for type in [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, InputLockRule.systemDefined] {
            XCTAssertNotEqual(mask & (CGEventMask(1) << type), 0)
        }
        for type in [CGEventType.mouseMoved.rawValue, CGEventType.leftMouseDown.rawValue, CGEventType.scrollWheel.rawValue] {
            XCTAssertEqual(mask & (CGEventMask(1) << type), 0, "触控板的事件不该经过回调")
        }
    }

    func testFullMaskCoversEverything() {
        let mask = InputLockRule.mask(for: .all)
        for type in [CGEventType.keyDown.rawValue, CGEventType.mouseMoved.rawValue, CGEventType.leftMouseDown.rawValue,
                     CGEventType.scrollWheel.rawValue, InputLockRule.systemDefined, 29, 34] {
            XCTAssertNotEqual(mask & (CGEventMask(1) << type), 0)
        }
    }

    func testCountdownText() {
        XCTAssertEqual(InputLockRule.countdown(120), "2:00")
        XCTAssertEqual(InputLockRule.countdown(107), "1:47")
        XCTAssertEqual(InputLockRule.countdown(9), "0:09")
        XCTAssertEqual(InputLockRule.countdown(0), "0:00")
    }
}
