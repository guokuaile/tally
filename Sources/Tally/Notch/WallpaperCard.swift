import SwiftUI

struct WallpaperCard: View {
    @State private var service = WallpaperService.shared

    var body: some View {
        Card("壁纸", symbol: "photo.on.rectangle", tint: .purple, spacing: 4, accessory: AnyView(
            HeaderButton(symbol: "gearshape", help: "壁纸设置") {
                SettingsWindowController.shared.show(section: .wallpaper)
            }.accessibilityLabel("壁纸设置")
        )) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(service.status.map { $0.paused ? "已暂停" : $0.playing ? "播放中" : "无素材" } ?? "未运行")
                        .font(.metric(13)).foregroundStyle(.white.opacity(0.95))
                    Spacer(minLength: 4)
                    if let status = service.status {
                        Text("\(status.itemCount) 个素材").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                Text(service.status?.currentItem.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "选择本地图片或视频开始播放")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.middle)
                    .help(service.status?.currentItem ?? "在壁纸设置中添加素材")
                HStack(spacing: 6) {
                    systemPill(service.status == nil ? "开始" : service.status?.paused == true ? "继续" : "暂停", on: false) {
                        Task {
                            if service.status == nil { try? await service.start() }
                            else if service.status?.paused == true { try? await service.resume() }
                            else { try? await service.pause() }
                        }
                    }
                    .disabled(service.busy)
                    systemPill("下一张", on: false) { Task { try? await service.next() } }
                        .disabled(service.status == nil || service.busy)
                    systemPill("停止", on: false) { Task { try? await service.stop() } }
                        .disabled(service.status == nil || service.busy)
                }
            }
            if let message = service.message {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
            if let error = service.status?.error, error != service.message {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .task { await service.refresh() }
    }
}
