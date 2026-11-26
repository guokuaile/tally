import SwiftUI

struct DisplayCard: View {
    private var service = DisplayModeService.shared

    var body: some View {
        Card("显示器", symbol: "display.2", tint: .blue, spacing: 4, accessory: AnyView(
            HeaderButton(symbol: "gearshape", help: "显示器设置") {
                SettingsWindowController.shared.show(section: .displays)
            }.accessibilityLabel("显示器设置")
        )) {
            if service.screens.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("未连接外接屏").font(.metric(13)).foregroundStyle(.white.opacity(0.9))
                    Text("接入显示器后可选择显示档位")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    systemPill("刷新", on: false) { service.refresh(clearOperationFeedback: true) }
                        .disabled(service.busy)
                }
            }
            ForEach(service.screens) { screen in
                if screen.id != service.screens.first?.id { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(screen.current.width) × \(screen.current.height)")
                        .font(.metric(13)).foregroundStyle(.white.opacity(0.95))
                    Text("\(screen.name) · \(screen.current.isHiDPI ? "HiDPI" : "普通") · \(screen.current.refreshRate == 0 ? "默认刷新率" : "\(Int(screen.current.refreshRate.rounded())) Hz")")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    HStack(spacing: 6) {
                        let applied = service.target(for: screen).map { screen.current.matches($0) } ?? false
                        systemPill(applied ? "已应用" : "应用常用", on: false) {
                            Task { await service.apply(uuid: screen.id) }
                        }
                        .disabled(applied || service.busy || screen.mirrored || service.target(for: screen).flatMap(screen.matching) == nil)
                        systemPill("撤销", on: false) { Task { await service.undo(uuid: screen.id) } }
                            .disabled(service.busy || service.undoReason(for: screen) != nil)
                            .help(service.undoReason(for: screen) ?? "撤销上次切换")
                    }
                }
                .help("\(screen.name)\n当前：\(screen.current.label)\n常用：\(service.target(for: screen)?.label ?? "未配置")")
            }
            if service.busy {
                Text("正在切换显示模式…").font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
            } else if let failure = service.failure {
                Text(failure).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let notice = service.notice {
                Text(notice).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
            }
        }
    }
}
