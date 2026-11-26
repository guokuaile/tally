import Foundation
import Darwin

public enum WallpaperCommand: String, Codable { case status, pause, resume, next, reload }

public struct WallpaperStatus: Codable, Equatable {
    public var pid: Int32
    public var playing: Bool
    public var paused: Bool
    public var currentItem: String?
    public var itemCount: Int
    public var error: String?
    public init(pid: Int32, playing: Bool, paused: Bool, currentItem: String?, itemCount: Int, error: String?) {
        self.pid = pid; self.playing = playing; self.paused = paused; self.currentItem = currentItem; self.itemCount = itemCount; self.error = error
    }
    public var isHealthy: Bool { pid > 0 && error == nil && (currentItem != nil || itemCount == 0) }
}

public struct WallpaperResponse: Codable {
    public var status: WallpaperStatus
    public var error: String?
    public init(status: WallpaperStatus, error: String? = nil) { self.status = status; self.error = error }
}

private let maxPacket = 4096

private func socketAddress(_ path: String) throws -> (sockaddr_un, socklen_t) {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw WallpaperError.unavailable("控制端点路径过长") }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
    return (address, socklen_t(MemoryLayout<sockaddr_un>.size))
}

private func deadline(_ fd: Int32, seconds: Double) {
    var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds.truncatingRemainder(dividingBy: 1)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
}

private func ready(_ fd: Int32, event: Int16, until end: TimeInterval) -> Bool {
    let remaining = end - ProcessInfo.processInfo.systemUptime
    guard remaining > 0 else { return false }
    var item = pollfd(fd: fd, events: event, revents: 0)
    return poll(&item, 1, Int32(min(remaining * 1000, Double(Int32.max)))) > 0
}

private func exchange(_ fd: Int32, packet: Data, timeout: Double) throws -> Data {
    guard packet.count <= maxPacket else { throw WallpaperError.unavailable("控制消息过长") }
    let end = ProcessInfo.processInfo.systemUptime + timeout
    try packet.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            guard ready(fd, event: Int16(POLLOUT), until: end) else { throw WallpaperError.unavailable("控制连接写入超时") }
            let n = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            guard n > 0 else { throw WallpaperError.unavailable("控制连接写入失败") }
            offset += n
        }
    }
    var output = Data()
    var byte: UInt8 = 0
    while output.count < maxPacket {
        guard ready(fd, event: Int16(POLLIN), until: end) else { throw WallpaperError.unavailable("控制连接读取超时") }
        let n = recv(fd, &byte, 1, 0)
        guard n > 0 else { throw WallpaperError.unavailable("控制连接超时或已断开") }
        if byte == 10 { return output }
        output.append(byte)
    }
    throw WallpaperError.unavailable("控制回复过长")
}

public enum WallpaperClient {
    public static func send(_ command: WallpaperCommand, paths: WallpaperPaths = WallpaperPaths(), timeout: Double = 2) throws -> WallpaperStatus {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WallpaperError.unavailable("无法创建控制连接") }
        defer { close(fd) }
        deadline(fd, seconds: timeout)
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw WallpaperError.unavailable("无法设置控制连接截止时间") }
        var (address, size) = try socketAddress(paths.socket.path)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) } }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw WallpaperError.unavailable("壁纸播放器未运行") }
            var pollItem = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollItem, 1, Int32(timeout * 1000)) > 0 else { throw WallpaperError.unavailable("控制连接超时") }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
                throw WallpaperError.unavailable("壁纸播放器未运行")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw WallpaperError.unavailable("控制连接身份不符") }
        let response = try JSONDecoder().decode(WallpaperResponse.self, from: exchange(fd, packet: Data((command.rawValue + "\n").utf8), timeout: timeout))
        if let error = response.error { throw WallpaperError.unavailable(error) }
        return response.status
    }
}

public final class WallpaperControlServer {
    private let paths: WallpaperPaths
    private let handler: (WallpaperCommand) -> WallpaperResponse
    private var lockFD: Int32 = -1
    private var serverFD: Int32 = -1

    public init(paths: WallpaperPaths, handler: @escaping (WallpaperCommand) -> WallpaperResponse) { self.paths = paths; self.handler = handler }

    public func start() throws {
        try paths.prepare()
        lockFD = open(paths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
            throw WallpaperError.unavailable("壁纸播放器已运行")
        }
        // The lock is held before removing a stale endpoint; a live process keeps its endpoint.
        unlink(paths.socket.path)
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { throw WallpaperError.unavailable("无法创建控制端点") }
        var (address, size) = try socketAddress(paths.socket.path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFD, $0, size) } }
        guard bound == 0, chmod(paths.socket.path, 0o600) == 0, listen(serverFD, 8) == 0 else {
            throw WallpaperError.unavailable("无法绑定控制端点")
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let client = accept(serverFD, nil, nil)
                if client < 0 { break }
                deadline(client, seconds: 2)
                var uid: uid_t = 0, gid: gid_t = 0
                if getpeereid(client, &uid, &gid) == 0, uid == getuid() {
                    handle(client)
                }
                close(client)
            }
        }
    }

    private func handle(_ fd: Int32) {
        let end = ProcessInfo.processInfo.systemUptime + 2
        var bytes = Data()
        var byte: UInt8 = 0
        while bytes.count < maxPacket {
            guard ready(fd, event: Int16(POLLIN), until: end) else { return }
            guard recv(fd, &byte, 1, 0) > 0 else { return }
            if byte == 10 { break }
            bytes.append(byte)
        }
        guard bytes.count < maxPacket, let value = String(data: bytes, encoding: .utf8), let command = WallpaperCommand(rawValue: value) else { return }
        let reply = DispatchQueue.main.sync { handler(command) }
        guard let data = try? JSONEncoder().encode(reply), data.count < maxPacket else { return }
        var packet = data
        packet.append(10)
        packet.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard ready(fd, event: Int16(POLLOUT), until: end) else { break }
                let n = send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    public func stop() {
        if serverFD >= 0 { close(serverFD); serverFD = -1; unlink(paths.socket.path) }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }
    deinit { stop() }
}
