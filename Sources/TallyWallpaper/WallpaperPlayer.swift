import AppKit
import AVFoundation
import ImageIO
import TallyWallpaperKit

private let paths = WallpaperPaths()

private func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
    var data = (try? Data(contentsOf: paths.log)) ?? Data()
    data.append(contentsOf: line.utf8)
    if data.count > 65_536 {
        data = data.suffix(32_768)
        if let newline = data.firstIndex(of: 10) { data = data.suffix(from: newline + 1) }
    }
    try? data.write(to: paths.log, options: .atomic)
}

private func fade(_ layer: CALayer, to value: Float) {
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
    animation.toValue = value
    animation.duration = 1
    layer.opacity = value
    layer.add(animation, forKey: "fade")
}

private final class Shown {
    let layer: CALayer
    let player: AVQueuePlayer?
    let looper: AVPlayerLooper?
    var ready: Bool
    var queueObservation: NSKeyValueObservation?
    var itemObservation: NSKeyValueObservation?
    var preparationTimer: Timer?
    init(_ layer: CALayer, _ player: AVQueuePlayer? = nil, _ looper: AVPlayerLooper? = nil) {
        self.layer = layer; self.player = player; self.looper = looper
        self.ready = player == nil
    }
}

private final class ScreenView {
    let window: NSWindow
    let host: CALayer
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
    let maxPixel: Int
    var current: Shown?
    var currentURL: URL?

    static func id(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    init(_ screen: NSScreen) {
        displayID = Self.id(screen); frame = screen.frame; scale = screen.backingScaleFactor
        maxPixel = Int(max(frame.width, frame.height) * scale)
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        host = view.layer!
        host.backgroundColor = NSColor.black.cgColor
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = true; window.hasShadow = false; window.backgroundColor = .black
        window.ignoresMouseEvents = true; window.contentView = view; window.alphaValue = 0
        window.orderFront(nil)
    }

    func show(_ url: URL, paused: Bool, mediaFailure: @escaping (URL, String) -> Void) -> Bool {
        let shown: Shown
        if WallpaperPlaylist.videoExtensions.contains(url.pathExtension.lowercased()) {
            let player = AVQueuePlayer()
            let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            player.isMuted = true
            if !paused { player.play() }
            shown = Shown(layer, player, looper)
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCache: false,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
            let layer = CALayer()
            layer.contentsGravity = .resizeAspectFill; layer.masksToBounds = true; layer.contents = image
            shown = Shown(layer)
        }
        let old = current
        current = shown
        shown.layer.frame = host.bounds
        shown.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        shown.layer.opacity = 0
        host.addSublayer(shown.layer)
        let reveal = { [weak self, weak shown] in
            guard let self, let shown, self.current === shown else { return }
            if shown.player != nil && shown.ready { return }
            shown.ready = true
            shown.preparationTimer?.invalidate()
            shown.preparationTimer = nil
            shown.queueObservation?.invalidate()
            shown.queueObservation = nil
            // Preparation observers capture the previous frame; release them after readiness.
            shown.itemObservation?.invalidate()
            shown.itemObservation = nil
            self.currentURL = url
            CATransaction.begin()
            CATransaction.setCompletionBlock { old?.player?.pause(); old?.layer.removeFromSuperlayer() }
            fade(shown.layer, to: 1)
            if let old { fade(old.layer, to: 0) }
            CATransaction.commit()
            if self.window.alphaValue == 0 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 1
                    self.window.animator().alphaValue = 1
                }
            }
        }
        if let player = shown.player {
            let fail = { [weak self, weak shown] (reason: String) in
                guard let self, let shown, self.current === shown, !shown.ready else { return }
                shown.preparationTimer?.invalidate()
                shown.preparationTimer = nil
                shown.queueObservation?.invalidate()
                shown.queueObservation = nil
                shown.itemObservation?.invalidate()
                shown.itemObservation = nil
                shown.player?.pause()
                shown.layer.removeFromSuperlayer()
                self.current = old
                mediaFailure(url, reason)
            }
            // AVPlayerLooper fills the queue asynchronously; nil here is normal, not a bad video.
            shown.queueObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self, weak shown] player, _ in
                DispatchQueue.main.async {
                    guard let self, let shown, self.current === shown else { return }
                    guard let item = player.currentItem else { return }
                    shown.queueObservation?.invalidate()
                    shown.queueObservation = nil
                    shown.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak shown] item, _ in
                        DispatchQueue.main.async {
                            guard let self, let shown, self.current === shown else { return }
                            switch item.status {
                            case .readyToPlay: reveal()
                            case .failed: fail(item.error?.localizedDescription ?? "视频无法播放")
                            default: break
                            }
                        }
                    }
                }
            }
            shown.preparationTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self, weak shown] _ in
                guard let self, let shown, self.current === shown else { return }
                fail("视频准备超时")
            }
        } else {
            reveal()
        }
        return true
    }
}

private struct PlaybackState: Codable { var paused: Bool }

private final class Controller: NSObject, NSApplicationDelegate {
    private var config: WallpaperConfiguration
    private var playlist = WallpaperPlaylist(seenURL: paths.seen)
    private var screens: [ScreenView] = []
    private var timer: Timer?
    private var server: WallpaperControlServer?
    private var paused = false
    private var sleeping = false
    private var current: URL?
    private var failedPaths: Set<URL> = []
    private var error: String?
    private var stateError: String?

    init(config: WallpaperConfiguration) {
        self.config = config
        do { paused = try paths.loadPaused() }
        catch {
            paused = true
            stateError = "暂停状态无法读取：\(error.localizedDescription)"
            log(stateError!)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Acquire the process lock before creating any desktop window.
        let server = WallpaperControlServer(paths: paths) { [weak self] command in
            guard let self else { return WallpaperResponse(status: WallpaperStatus(pid: getpid(), playing: false, paused: false, currentItem: nil, itemCount: 0, error: "播放器正在退出"), error: "播放器正在退出") }
            return self.respond(command)
        }
        do { try server.start(); self.server = server }
        catch { log(error.localizedDescription); NSApp.terminate(nil); return }
        syncScreens(); advance()
        schedule()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.syncScreens() }
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = true; self?.screens.forEach { $0.current?.player?.pause() }
        }
        notifications.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sleeping = false
            if !self.paused { self.screens.forEach { $0.current?.player?.play() } }
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: config.slotSeconds, repeats: true) { [weak self] _ in
            guard let self, !self.paused, !self.sleeping else { return }
            self.advance()
        }
    }

    private func syncScreens() {
        let live = NSScreen.screens
        let unchanged = screens.filter { old in live.contains { ScreenView.id($0) == old.displayID && $0.frame == old.frame && $0.backingScaleFactor == old.scale } }
        for old in screens where !unchanged.contains(where: { $0 === old }) { old.current?.player?.pause(); old.window.orderOut(nil) }
        screens = unchanged
        for screen in live where !screens.contains(where: { $0.displayID == ScreenView.id(screen) }) {
            let view = ScreenView(screen)
            screens.append(view)
            if let current { _ = view.show(current, paused: paused || sleeping, mediaFailure: { [weak self] url, reason in self?.mediaFailed(url, reason) }) }
        }
    }

    private func advance(skippingFailed: Bool = false) {
        if !skippingFailed { failedPaths.removeAll() }
        let attempts: Int
        do { attempts = try WallpaperPlaylist.collect(config.sources).count }
        catch { mediaReadFailed(error); return }
        for _ in 0..<attempts {
            let candidate: URL
            do {
                guard let next = try playlist.next(sources: config.sources) else { break }
                candidate = next
            } catch { mediaReadFailed(error); return }
            if failedPaths.contains(candidate) { continue }
            // Decode image before changing the visible layer; unreadable files cannot become blank wallpaper.
            if screens.allSatisfy({ $0.show(candidate, paused: paused || sleeping, mediaFailure: { [weak self] url, reason in self?.mediaFailed(url, reason) }) }) {
                current = candidate; error = nil; return
            }
            error = "无法读取素材：\(candidate.lastPathComponent)"
            log(error!)
        }
        if attempts > 0, !failedPaths.isEmpty, let previous = screens.first?.currentURL {
            current = previous
            return
        }
        current = nil
        if attempts == 0 { error = nil }
        screens.forEach { $0.current?.player?.pause(); $0.window.alphaValue = 0 }
    }

    private func mediaReadFailed(_ failure: Error) {
        error = "素材读取失败：\(failure.localizedDescription)"
        log(error!)
        // A transient permission or mount failure must not clear the last valid desktop layer.
        current = screens.first?.currentURL
    }

    private func mediaFailed(_ url: URL, _ reason: String) {
        error = "无法播放 \(url.lastPathComponent)：\(reason)"
        log(error!)
        failedPaths.insert(url)
        if current == url { current = screens.first?.currentURL }
        advance(skippingFailed: true)
    }

    private func persistPause() throws {
        let data = try JSONEncoder().encode(PlaybackState(paused: paused))
        try data.write(to: paths.playbackState, options: .atomic)
    }

    private func respond(_ command: WallpaperCommand) -> WallpaperResponse {
        switch command {
        case .status: break
        case .pause:
            paused = true; screens.forEach { $0.current?.player?.pause() }
            do { try persistPause(); stateError = nil }
            catch { return WallpaperResponse(status: status, error: "暂停状态无法保存：\(error.localizedDescription)") }
        case .resume:
            paused = false; if !sleeping { screens.forEach { $0.current?.player?.play() } }
            do { try persistPause(); stateError = nil }
            catch { return WallpaperResponse(status: status, error: "继续状态无法保存：\(error.localizedDescription)") }
        case .next: advance()
        case .reload:
            do { config = try paths.load(); schedule(); advance() }
            catch { return WallpaperResponse(status: status, error: error.localizedDescription) }
        }
        return WallpaperResponse(status: status)
    }

    private var status: WallpaperStatus {
        let ready = current != nil && !screens.isEmpty && screens.allSatisfy { $0.current?.ready == true }
        return WallpaperStatus(pid: getpid(), playing: ready && !paused && !sleeping, paused: paused,
                        currentItem: ready ? current?.path : nil, itemCount: playlist.count, error: stateError ?? error)
    }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--command" {
    guard let command = WallpaperCommand(rawValue: CommandLine.arguments[2]) else { exit(2) }
    do {
        let status = try WallpaperClient.send(command, paths: paths)
        let data = try JSONEncoder().encode(status)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
        exit(status.isHealthy ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data(error.localizedDescription.utf8))
        exit(1)
    }
}

do {
    let config = try paths.load()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = Controller(config: config)
    app.delegate = controller
    app.run()
} catch {
    log(error.localizedDescription)
    exit(1)
}
