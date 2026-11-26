import XCTest
@testable import Tally

/// 真起子进程：截止时间、管道灌满、不理 SIGTERM、后台进程占着 stdout，这些只有真进程才测得出来。
final class SubprocessTests: XCTestCase {

    private let sh = URL(fileURLWithPath: "/bin/sh")

    private func timed(_ body: () throws -> Subprocess.Result) rethrows -> (Subprocess.Result, TimeInterval) {
        let start = Date()
        let result = try body()
        return (result, Date().timeIntervalSince(start))
    }

    func testDeadlineHoldsWhenChildSaysNothing() throws {
        // hook 安装卡死的那种：子进程不出声，原来的 availableData 循环会一直等下去
        let (result, elapsed) = try timed { try Subprocess.run(sh, ["-c", "sleep 5"], deadline: 0.5) }
        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.status)
        XCTAssertLessThan(elapsed, 2.5)
    }

    func testStderrFloodDoesNotBlockTheChild() throws {
        // 200 KB 写进 stderr：只读 stdout 的话子进程会卡在写 stderr 上
        let (result, _) = try timed { try Subprocess.run(sh, ["-c", "head -c 200000 /dev/zero >&2; echo done"], deadline: 5) }
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done\n")
        XCTAssertEqual(result.stderr.count, 200_000)
    }

    func testChildIgnoringTerminateIsKilled() throws {
        let (result, elapsed) = try timed { try Subprocess.run(sh, ["-c", "trap '' TERM; sleep 5"], deadline: 0.3) }
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(elapsed, 3, "SIGTERM 不理就 SIGKILL")
    }

    func testBackgroundProcessHoldingStdoutDoesNotHoldUsUntilDeadline() throws {
        // 启动脚本起了个后台进程、继承了 stdout：shell 早退了，管道却一直不关
        let (result, elapsed) = try timed { try Subprocess.run(sh, ["-c", "sleep 5 & echo hi"], deadline: 10) }
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hi\n")
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(elapsed, 3)
    }

    func testInputReachesEOFWithoutExtraBytes() throws {
        let payload = Data("a\u{0}b\n".utf8)
        let result = try Subprocess.run(sh, ["-c", "cat"], deadline: 2, input: payload)
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout, payload)
    }

    func testBlockedInputHonorsDeadline() throws {
        let payload = Data(repeating: 65, count: 4 * 1024 * 1024)
        let (result, elapsed) = try timed {
            try Subprocess.run(sh, ["-c", "sleep 5"], deadline: 0.3, input: payload)
        }
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(elapsed, 2.5)
    }

    func testEarlyChildExitDuringInputDoesNotSignalParent() throws {
        let payload = Data(repeating: 65, count: 4 * 1024 * 1024)
        let result = try Subprocess.run(sh, ["-c", "exit 7"], deadline: 2, input: payload)
        XCTAssertEqual(result.status, 7)
        XCTAssertFalse(result.timedOut)
    }

    func testConcurrentUnrelatedCallerIsUnaffectedByInputFailure() throws {
        let group = DispatchGroup()
        var unrelated: Subprocess.Result?
        group.enter()
        DispatchQueue.global().async {
            unrelated = try? Subprocess.run(self.sh, ["-c", "echo healthy"], deadline: 2)
            group.leave()
        }
        let failed = try Subprocess.run(sh, ["-c", "exit 7"], deadline: 2,
                                        input: Data(repeating: 65, count: 1024 * 1024))
        XCTAssertEqual(failed.status, 7)
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(String(decoding: unrelated?.stdout ?? Data(), as: UTF8.self), "healthy\n")
    }

    func testBackgroundChildHoldingStdinDoesNotRetainWriter() throws {
        let input = Data(repeating: 65, count: 4 * 1024 * 1024)
        let (result, elapsed) = try timed {
            try Subprocess.run(sh, ["-c", "sleep 5 <&0 & exit 0"], deadline: 2, input: input)
        }
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(elapsed, 2)
    }
}
