import AppKit
import SwiftUI

/// 「音乐」页：系统「正在播放」的那首歌——封面、歌名、歌手、哪个播放器，上一曲 / 播放暂停 / 下一曲。
/// 不画进度条：进度是播放器自己报的，有的（酷狗）暂停、继续之后一直报旧值（docs/music.md）。
struct MusicPage: View {
    var monitor = NowPlayingMonitor.shared

    var body: some View {
        Card {
            if let track = monitor.track {
                HStack(spacing: 12) {
                    // 按钮以外的那一片整个可点：打开播放器
                    Button { monitor.openPlayer() } label: {
                        info(track)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("打开播放器")
                    HStack(spacing: 4) {
                        MusicButton(symbol: "backward.fill", help: "上一曲", size: 13) { monitor.send(.prev) }
                        MusicButton(symbol: track.isPlaying ? "pause.fill" : "play.fill",
                                    help: track.isPlaying ? "暂停" : "播放", size: 18) { monitor.send(.toggle) }
                        MusicButton(symbol: "forward.fill", help: "下一曲", size: 13) { monitor.send(.next) }
                    }
                }
            } else {
                // 只有「页签常驻」开着才到得了这里
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("没有在播放的内容")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 72)
            }
        }
    }

    /// 封面 + 歌名 / 歌手 / 播放器。
    private func info(_ track: NowPlaying) -> some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                if !track.subtitle.isEmpty {
                    Text(track.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                if let player = monitor.player {
                    HStack(spacing: 4) {
                        if let icon = player.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 12, height: 12)
                        }
                        Text(player.localizedName ?? "")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let image = monitor.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 72, height: 72)
                .clipShape(shape)
        } else {
            shape
                .fill(.white.opacity(0.08))
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.3))
                }
        }
    }
}

/// 播放控制的圆按钮：悬停出底，和标题行的按钮同一个手感，只是大一号。
private struct MusicButton: View {
    let symbol: String
    let help: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(hovered ? 0.14 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.smooth(duration: 0.2), value: hovered)
        .help(help)
    }
}
