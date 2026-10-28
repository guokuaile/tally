import XCTest
@testable import Tally

final class GhosttyMatchTests: XCTestCase {

    func testCodexCandidatesExcludeClaudeAndUnknownTTY() {
        let codex = GhosttyTerminal(id: "codex", name: "same", workingDirectory: "/tmp", tty: "ttys002")
        let claude = GhosttyTerminal(id: "claude", name: "same", workingDirectory: "/tmp", tty: "/dev/ttys001")
        let unknown = GhosttyTerminal(id: "unknown", name: "same", workingDirectory: "/tmp")
        XCTAssertEqual(GhosttyMatch.codexCandidates([codex, claude, unknown], ttys: ["/dev/ttys002"]), [codex])
        XCTAssertTrue(GhosttyMatch.codexCandidates([codex, claude, unknown], ttys: []).isEmpty)
    }

    private let a = GhosttyTerminal(id: "A", name: "✳ Foo", workingDirectory: "/Users/me/workspace/x")
    private let b = GhosttyTerminal(id: "B", name: "◐ Bar", workingDirectory: "/Users/me/workspace/x")
    private let c = GhosttyTerminal(id: "C", name: "⠇ Baz", workingDirectory: "/Users/me/workspace/y")

    func testTitleAloneIsEnoughEvenWhenCwdDiffers() {
        // 实测的 bug：会话里 cd 进了子目录，hook 记的 cwd 是 .../MacAppProject/tally，终端报的是 .../MacAppProject。
        let t = GhosttyTerminal(id: "T", name: "◐ Mac应用开发和开源项目评估", workingDirectory: "/Users/me/workspace/MacAppProject")
        XCTAssertEqual(
            GhosttyMatch.pick(terminals: [a, t, c], cwd: "/Users/me/workspace/MacAppProject/tally", title: "Mac应用开发和开源项目评估"),
            .found(id: "T")
        )
    }

    func testSameTitleTwiceUsesDirectoryToBreakTie() {
        let t1 = GhosttyTerminal(id: "T1", name: "✳ 同名", workingDirectory: "/Users/me/one")
        let t2 = GhosttyTerminal(id: "T2", name: "✳ 同名", workingDirectory: "/Users/me/two")
        XCTAssertEqual(GhosttyMatch.pick(terminals: [t1, t2], cwd: "/Users/me/two/sub", title: "同名"), .found(id: "T2"))
    }

    func testSameCwdPicksByTitleSuffix() {
        XCTAssertEqual(GhosttyMatch.pick(terminals: [a, b, c], cwd: "/Users/me/workspace/x", title: "Bar"), .found(id: "B"))
    }

    func testTitleMissDoesNotChooseArbitraryTerminal() {
        XCTAssertEqual(GhosttyMatch.pick(terminals: [a, b], cwd: "/Users/me/workspace/x", title: "Nope"), .ambiguous)
        XCTAssertEqual(GhosttyMatch.pick(terminals: [a, b], cwd: "/Users/me/workspace/x", title: nil), .ambiguous)
        XCTAssertEqual(GhosttyMatch.pick(terminals: [a], cwd: "/Users/me/workspace/x", title: "Nope"), .found(id: "A"))
    }

    func testDuplicateTitlesInSameDirectoryAreAmbiguous() {
        let t1 = GhosttyTerminal(id: "T1", name: "✳ 同名", workingDirectory: "/Users/me/one")
        let t2 = GhosttyTerminal(id: "T2", name: "◐ 同名", workingDirectory: "/Users/me/one")
        XCTAssertEqual(GhosttyMatch.pick(terminals: [t1, t2], cwd: "/Users/me/one", title: "同名"), .ambiguous)
    }

    func testTTYDistinguishesSameDirectoryAndSameTitle() {
        let first = GhosttyTerminal(id: "A", name: "✳ Claude Code", workingDirectory: "/tmp", tty: "/dev/ttys005")
        let second = GhosttyTerminal(id: "B", name: "✳ Claude Code", workingDirectory: "/tmp", tty: "/dev/ttys008")
        XCTAssertEqual(GhosttyMatch.pick(terminals: [first, second], cwd: "/tmp", title: nil, tty: "ttys008"), .found(id: "B"))
        XCTAssertEqual(GhosttyMatch.pick(terminals: [first, second], cwd: "/tmp", title: nil, tty: "ttys009"), .notFound)
        XCTAssertEqual(GhosttyMatch.pick(terminals: [first, second], cwd: "/tmp", title: nil, tty: nil), .ambiguous)
        XCTAssertEqual(GhosttyMatch.pick(terminals: [first, second], cwd: "/elsewhere", title: "Claude Code", tty: "/dev/ttys008"), .found(id: "B"))
        let unavailable = GhosttyTerminal(id: "C", name: "✳ Claude Code", workingDirectory: "/tmp", tty: "")
        XCTAssertEqual(GhosttyMatch.pick(terminals: [unavailable], cwd: "/tmp", title: nil, tty: "ttys005"), .notFound)
        XCTAssertEqual(GhosttyMatch.pick(terminals: [a], cwd: "/Users/me/workspace/x", title: nil, tty: "ttys005"), .found(id: "A"))
        XCTAssertEqual(GhosttyMatch.pick(terminals: [first, first], cwd: "/tmp", title: nil, tty: "ttys005"), .ambiguous)
    }

    func testAncestorDirectoryMatchesAndDeepestWins() {
        let root = GhosttyTerminal(id: "R", name: "zsh", workingDirectory: "/Users/me")
        let mid = GhosttyTerminal(id: "M", name: "zsh", workingDirectory: "/Users/me/workspace")
        XCTAssertEqual(GhosttyMatch.pick(terminals: [root, mid, c], cwd: "/Users/me/workspace/x/deep", title: nil), .found(id: "M"))
        // 同名前缀不算祖先
        XCTAssertFalse(GhosttyMatch.isAncestor("/Users/me/workspace/x", of: "/Users/me/workspace/xy"))
        XCTAssertTrue(GhosttyMatch.isAncestor("/", of: "/anything"))
    }

    func testSymlinkedTmpMatchesPrivateTmp() {
        let t = GhosttyTerminal(id: "T", name: "✳ Tmp", workingDirectory: "/private/tmp")
        XCTAssertEqual(GhosttyMatch.pick(terminals: [t], cwd: "/tmp/", title: nil), .found(id: "T"))
    }

    func testNoCandidateIsNotFound() {
        XCTAssertEqual(GhosttyMatch.pick(terminals: [a, b], cwd: "/elsewhere", title: "Foo2"), .notFound)
    }

    func testTitleSuffixRequiresSeparatingSpace() {
        // "✳ FooBar" 不该被标题 "Bar" 命中：标题前必须是空格。
        let tricky = GhosttyTerminal(id: "X", name: "✳ FooBar", workingDirectory: "/Users/me/workspace/x")
        XCTAssertEqual(GhosttyMatch.pick(terminals: [tricky, b], cwd: "/Users/me/workspace/x", title: "Bar"), .found(id: "B"))
    }

    func testCodexWithoutTitleMatchesDirectoryNameInTerminalTitle() {
        // 同一目录：Codex 忙时终端叫「⠦ GoldFever」，旁边是个跑 caffeinate 的普通 shell；该选前者。
        let plain = GhosttyTerminal(id: "PL", name: "caffeinate -dims", workingDirectory: "/Users/me/workspace/GoldFever")
        let codexBusy = GhosttyTerminal(id: "CX", name: "⠦ GoldFever", workingDirectory: "/Users/me/workspace/GoldFever")
        XCTAssertEqual(
            GhosttyMatch.pick(terminals: [plain, codexBusy], cwd: "/Users/me/workspace/GoldFever", title: nil, provider: "codex"),
            .found(id: "CX")
        )
        let codexIdle = GhosttyTerminal(id: "CI", name: "GoldFever", workingDirectory: "/Users/me/workspace/GoldFever")
        XCTAssertEqual(
            GhosttyMatch.pick(terminals: [plain, codexIdle], cwd: "/Users/me/workspace/GoldFever", title: nil, provider: "codex"),
            .found(id: "CI")
        )
        let other = GhosttyTerminal(id: "OT", name: "vim", workingDirectory: "/Users/me/workspace/GoldFever")
        XCTAssertEqual(
            GhosttyMatch.pick(terminals: [plain, other], cwd: "/Users/me/workspace/GoldFever", title: nil, provider: "codex"),
            .ambiguous
        )
    }
}
