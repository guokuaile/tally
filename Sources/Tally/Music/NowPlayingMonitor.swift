import AppKit
import Observation

/// 「正在播放」的来源：把自带的小 dylib 交给 /usr/bin/perl 加载，读它的 stdout、往它的 stdin 写命令。
/// 为什么绕这一圈、助手的约定是什么，见 docs/music.md 与 Sources/TallyMedia/helper.m。
@MainActor
@Observable
final class NowPlayingMonitor {

    static let shared = NowPlayingMonitor()

    enum Command: String {
        case toggle, next, prev
    }

    private(set) var track: NowPlaying?
    /// 封面解码一次存着：面板每次重画都 `NSImage(data:)` 太浪费。
    private(set) var artwork: NSImage?
    /// 助手起不来的原因。非 nil 时整页藏起来，设置「音乐」里亮出来；改一下开关或重开 Tally 再试。
    private(set) var failure: String?
    /// 页签该不该出现可能变了（会话出现 / 消失、起不来了）：控制器据此把停在音乐页的面板挪回 AI 页。
    @ObservationIgnored var visibilityChanged: (() -> Void)?

    /// 起来不到这么久就退的算一次「起不来」，连着这么多次就不再试：perl 没了、或者苹果把这条路堵了，一直重起只是空转。
    /// 给到一分钟：只认「几秒内就退」的话，每次撑个七八秒再崩的助手会被一直重起下去，设置里还什么都不说。
    static let quickExit: TimeInterval = 60
    static let maxQuickExits = 3

    static let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libtallymedia.dylib")
    /// dylib 的构造函数里起线程干活，perl 这边只要活着别退。
    static let loader = "use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0x01) or die; while (1) { sleep 3600; }"

    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var commands: FileHandle?
    @ObservationIgnored private var output: FileHandle?
    @ObservationIgnored private var launchedAt = Date.distantPast
    @ObservationIgnored private var quickExits = 0

    /// 页签出不出现：关着不出；起不来不出；常驻一直出；不常驻要有「正在播放」的会话（暂停着也算）。
    nonisolated static func showsPage(enabled: Bool, resident: Bool, hasTrack: Bool, failed: Bool) -> Bool {
        enabled && !failed && (resident || hasTrack)
    }

    var pageVisible: Bool {
        let prefs = PreferencesStore.shared.prefs
        return Self.showsPage(enabled: prefs.musicEnabled, resident: prefs.musicResident, hasTrack: track != nil, failed: failure != nil)
    }

    /// 播放器那个 app：名字和图标。
    var player: NSRunningApplication? {
        track?.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
    }

    /// 幂等：每次改设置都会调。关了再开会重新试一遍起不来的助手。
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        quickExits = 0
        failure = nil
        if on { launch() } else { shutDown() }
    }

    func send(_ command: Command) {
        write(command.rawValue)
    }

    /// 点卡片：把播放器叫到前台。走 `openApplication` 而不是 `activate()`：它带 reopen，
    /// 窗口关着、只剩 Dock 图标的播放器（酷狗关掉主窗口后就是这样）也会把主窗口弹出来。
    func openPlayer() {
        guard let url = player?.bundleURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.error("打开播放器失败: \(error.localizedDescription)") }
        }
    }

    /// 让助手忘掉发过什么，重发一份完整的（含封面）。
    func refreshNow() {
        write("get")
    }

    // MARK: 助手进程

    /// readabilityHandler 在后台队列上一块一块地来，缓冲得跟着它走；同一个 FileHandle 的回调是串行的。
    private final class Chunks: @unchecked Sendable {
        var buffer = LineBuffer()
    }

    private func launch() {
        guard FileManager.default.fileExists(atPath: Self.helperURL.path) else {
            fail("app 包里没有音乐助手（Contents/Frameworks/libtallymedia.dylib），怎么编见 docs/music.md")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = ["-e", Self.loader, Self.helperURL.path]
        let input = Pipe()
        let outputPipe = Pipe()
        task.standardInput = input
        task.standardOutput = outputPipe
        task.standardError = FileHandle.nullDevice
        // 助手已经没了的那一刻按按钮：不设这个，SIGPIPE 直接带走整个 Tally
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let chunks = Chunks()
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = chunks.buffer.append(chunk)
            guard !lines.isEmpty else { return }
            // 不用 Task：几行连着到时要按顺序进主线程
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(lines, from: task) } }
        }
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(finished) } }
        }
        do {
            try task.run()
        } catch {
            fail("起不来 /usr/bin/perl：\(error.localizedDescription)")
            return
        }
        process = task
        commands = input.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        launchedAt = Date()
    }

    /// 关管道助手自己就退；`terminate` 是给「dylib 根本没加载上、perl 还在睡」那种情况的。
    private func shutDown() {
        let task = process
        process = nil
        output?.readabilityHandler = nil
        output = nil
        try? commands?.close()
        commands = nil
        task?.terminate()
        apply(nil)
    }

    private func consume(_ lines: [Data], from task: Process) {
        guard task === process else { return }
        for line in lines {
            switch NowPlayingFeed.parse(line, previous: track) {
            case .track(let next): apply(next)
            case .failed(let reason):
                fail("音乐助手读不了「正在播放」（\(reason)）：这个 macOS 可能已经不让 perl 走这条路了")
                return
            case nil: break
            }
        }
    }

    private func exited(_ task: Process) {
        // 自己关掉的那个已经不是 process 了
        guard task === process else { return }
        shutDown()
        quickExits = Date().timeIntervalSince(launchedAt) < Self.quickExit ? quickExits + 1 : 0
        guard quickExits < Self.maxQuickExits else {
            fail("音乐助手连着 \(Self.maxQuickExits) 次起不来：/usr/bin/perl 加载不了它，或者这个 macOS 已经不让走这条路了")
            return
        }
        Log.error("音乐助手退出了（状态 \(task.terminationStatus)），1 秒后重起")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.enabled, self.process == nil, self.failure == nil else { return }
                self.launch()
            }
        }
    }

    private func fail(_ reason: String) {
        Log.error(reason)
        shutDown()
        failure = reason
        visibilityChanged?()
    }

    private func apply(_ next: NowPlaying?) {
        let presenceChanged = (next == nil) != (track == nil)
        if next?.artwork != track?.artwork {
            artwork = next?.artwork.flatMap { NSImage(data: $0) }
        }
        track = next
        if presenceChanged { visibilityChanged?() }
    }

    private func write(_ command: String) {
        guard let commands else {
            // 助手退了还没重起的那一秒里按的：按钮没反应得有处可查
            Log.error("音乐助手没在跑，命令丢了：\(command)")
            return
        }
        do {
            try commands.write(contentsOf: Data((command + "\n").utf8))
        } catch {
            // 助手刚好没了：退出回调会重起它，这一下按钮就算没按上
            Log.error("音乐助手的管道写不进去：\(error.localizedDescription)")
        }
    }
}
