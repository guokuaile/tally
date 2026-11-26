import AppKit
import SwiftUI
import TallyWallpaperKit

struct WallpaperSettings: View {
    @State private var service = WallpaperService.shared
    @State private var sources: [String] = []
    @State private var seconds = 300.0
    @State private var login = false

    var body: some View {
        Form {
            Section("素材") {
                if sources.isEmpty {
                    Text("尚未添加素材目录或文件").foregroundStyle(.secondary)
                }
                ForEach(sources, id: \.self) { path in
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    let isDirectory = (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory
                    HStack(spacing: 10) {
                        Image(systemName: isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(isDirectory ? Color.blue : Color.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(isDirectory ? "目录" : "文件") · \(name)")
                                .lineLimit(1)
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(path)
                        Button {
                            sources.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "minus.circle")
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("从壁纸列表移除 \(name)")
                        .help("只从列表移除，不删除本地文件；保存设置后生效")
                    }
                }
                HStack {
                    Button("添加目录…") { chooseSource(files: false) }
                    Button("添加文件…") { chooseSource(files: true) }
                }
                Text("只管理播放列表，不移动或删除本地文件。图片与视频混播；新增文件下一轮优先播放。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("播放") {
                HStack {
                    Text("每张停留")
                    TextField("秒", value: $seconds, format: .number)
                        .labelsHidden()
                        .accessibilityLabel("每张停留秒数")
                        .frame(width: 100)
                    Text("秒")
                }
                Toggle("登录时自动播放", isOn: $login)
                Button("保存设置") { run { try await service.save(draft()) } }
                HStack {
                    Button("开始播放") { run { try await service.start() } }
                    Button("停止播放") { run { try await service.stop() } }
                    Button(service.status?.paused == true ? "继续" : "暂停") {
                        run { if service.status?.paused == true { try await service.resume() } else { try await service.pause() } }
                    }.disabled(service.status == nil)
                    Button("下一张") { run { try await service.next() } }.disabled(service.status == nil)
                }
                .disabled(service.busy)
            }
            Section("状态") {
                Text(service.status.map { "\($0.paused ? "已暂停" : $0.playing ? "播放中" : "未播放") · \($0.itemCount) 个素材" } ?? "播放器未运行")
                if let current = service.status?.currentItem { Text(URL(fileURLWithPath: current).lastPathComponent).lineLimit(1) }
                if let message = service.message { Text(message).foregroundStyle(.secondary) }
                if let error = service.status?.error { Text(error).foregroundStyle(.orange) }
                if service.legacyAvailable {
                    Button("恢复旧壁纸入口") { run { try await service.restoreLegacy() } }
                        .disabled(service.busy)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if let config = service.configuration {
                var seen: Set<String> = []
                sources = config.sources.filter { seen.insert($0).inserted }
                seconds = config.slotSeconds; login = config.launchAtLogin
            } else if !DemoMode.isOn {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let old = ["Pictures/电脑壁纸/静态壁纸", "Pictures/电脑壁纸/动态壁纸"].map { home.appendingPathComponent($0).path }
                sources = old.filter { FileManager.default.fileExists(atPath: $0) }
            }
            await service.refresh()
        }
    }

    private func draft() -> WallpaperConfiguration {
        WallpaperConfiguration(sources: sources, slotSeconds: seconds, launchAtLogin: login)
    }

    private func chooseSource(files: Bool) {
        guard !DemoMode.isOn else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = !files; panel.canChooseFiles = files
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for path in panel.urls.map(\.path) where !sources.contains(path) {
                sources.append(path)
            }
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        Task { do { try await operation() } catch { /* Service publishes the error. */ } }
    }
}
