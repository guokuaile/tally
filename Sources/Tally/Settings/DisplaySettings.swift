import AppKit
import SwiftUI

struct DisplaySettings: View {
    private var service = DisplayModeService.shared
    @State private var selectedUUID = ""
    @State private var selectedMode: DisplayModeSelection?
    @State private var customSize = ""
    @State private var message: String?
    @State private var configurationMessage: String?
    @State private var working = false
    @State private var showAdvanced = false

    private var screen: DisplaySnapshot? { service.screens.first { $0.id == selectedUUID } }

    var body: some View {
        Form {
            Section("外接显示器") {
                if service.screens.isEmpty {
                    Text("没有检测到外接显示器").foregroundStyle(.secondary)
                } else {
                    Picker("显示器", selection: $selectedUUID) {
                        ForEach(service.screens) { screen in
                            Text(screen.name).tag(screen.id)
                        }
                    }
                    if let screen {
                        LabeledContent("当前模式", value: screen.current.label)
                        if screen.mirrored { Text("镜像屏需先在系统设置中改为扩展显示。") }
                    }
                }
                Button("刷新显示器") {
                    reload(clearOperationFeedback: true)
                    message = service.failure == nil ? "已刷新：\(service.screens.count) 台外接屏，当前屏幕有 \(screen?.modes.count ?? 0) 个可用档位" : nil
                }
                .disabled(working || service.busy)
            }
            if let screen {
                Section("分辨率与缩放") {
                    Picker("选择模式", selection: $selectedMode) {
                        Text("请选择").tag(Optional<DisplayModeSelection>.none)
                        ForEach(screen.modes) { mode in Text(mode.label).tag(Optional(mode)) }
                    }
                    if let saved = service.target(for: screen) {
                        LabeledContent("常用模式", value: saved.label)
                        if screen.matching(saved) == nil { Text("已保存模式当前不可用").foregroundStyle(.orange) }
                    }
                    HStack {
                        Button("应用所选模式") {
                            guard let selectedMode else { return }
                            run { await service.apply(uuid: screen.id, mode: selectedMode) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedMode == nil || screen.mirrored || working || service.busy)
                        Button("保存为常用") {
                            guard let selectedMode else { return }
                            do { try service.saveTarget(selectedMode, for: screen.id); message = "已保存为常用，屏幕未切换；可在系统页快捷应用" }
                            catch { message = error.localizedDescription }
                        }.disabled(selectedMode == nil || working || service.busy)
                        Button("撤销上次切换") { run { await service.undo(uuid: screen.id) } }
                            .disabled(service.undoReason(for: screen) != nil || working || service.busy)
                    }
                    Text("选好档位后点“应用所选模式”立即切换；“保存为常用”只记住选择。")
                        .font(.caption).foregroundStyle(.secondary)
                    if working || service.busy {
                        HStack { ProgressView().controlSize(.small); Text("处理中…") }
                    } else if let message {
                        Text(message).foregroundStyle(.secondary)
                    } else if let notice = service.notice {
                        Text(notice).foregroundStyle(.secondary)
                    }
                    if let failure = service.failure { Text(failure).foregroundStyle(.red) }
                    if let reason = service.undoReason(for: screen) { Text(reason).foregroundStyle(.secondary) }
                    if service.target(for: screen).flatMap({ screen.matching($0) }) == nil,
                       service.target(for: screen) != nil {
                        Text("新档位尚未加载时，请重新连接显示器后刷新。")
                    }
                    if service.preferencesUndoPending(for: screen.id) {
                        Text("上次操作未确认；不会自动恢复或应用。请核对当前模式。")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Button { showAdvanced.toggle() } label: {
                        HStack {
                            Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                                .foregroundStyle(.secondary)
                            Text("新增 HiDPI 档位与配置恢复")
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showAdvanced ? "已展开" : "已收起")
                    if showAdvanced {
                        Text("列表里没有合适档位时再使用：安装配置 → 拔插显示器 → 刷新显示器 → 选择模式并应用。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("桌面尺寸，如 2580x1080", text: $customSize)
                        if let preview = previewText(screen) { Text(preview).foregroundStyle(.secondary) }
                        Button("安装档位配置…") { install(screen) }
                            .disabled(previewText(screen) == nil || working || service.busy || screen.mirrored)
                        Button("恢复原始档位配置…") { restore(screen) }
                            .disabled(working || service.busy)
                        Text("安装需管理员授权，不会立即切换屏幕。恢复配置也不会撤销当前模式。")
                            .font(.caption).foregroundStyle(.secondary)
                        if let configurationMessage { Text(configurationMessage).foregroundStyle(.secondary) }
                    }
                }
            } else if let failure = service.failure {
                Section { Text(failure).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            reload()
        }
        .onChange(of: selectedUUID) { _, uuid in
            if let screen = service.screens.first(where: { $0.id == uuid }) {
                selectedMode = service.target(for: screen).flatMap(screen.matching) ?? screen.current
            }
            message = nil
            configurationMessage = nil
        }
    }

    private func reload(clearOperationFeedback: Bool = false) {
        service.refresh(clearOperationFeedback: clearOperationFeedback)
        if !service.screens.contains(where: { $0.id == selectedUUID }) { selectedUUID = service.screens.first?.id ?? "" }
        if let screen {
            selectedMode = selectedMode.flatMap(screen.matching)
                ?? service.target(for: screen).flatMap(screen.matching) ?? screen.current
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        message = nil
        working = true
        Task { await action(); working = false; reload() }
    }

    private func previewText(_ screen: DisplaySnapshot) -> String? {
        guard let size = try? HiDPISize(customSize),
              (try? HiDPIOverrideService.shared.preview(screen, sizes: [size])) != nil else { return nil }
        return "\(size.width)×\(size.height) 桌面 → \(size.width * 2)×\(size.height * 2) 渲染 · \(screen.name)（\(screen.vendor):\(screen.product)）"
    }

    private func install(_ screen: DisplaySnapshot) {
        guard let size = try? HiDPISize(customSize) else { configurationMessage = "尺寸格式无效"; return }
        let alert = NSAlert()
        alert.messageText = "安装 HiDPI 档位配置？"
        alert.informativeText = "将为 \(screen.name) 写入系统显示器配置并请求管理员授权。写入后需重新连接显示器。"
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        working = true
        Task {
            defer { working = false; reload() }
            do { try await HiDPIOverrideService.shared.install(screen, sizes: [size]); configurationMessage = "配置已安装；重新连接显示器后刷新模式列表" }
            catch { configurationMessage = error.localizedDescription }
        }
    }

    private func restore(_ screen: DisplaySnapshot) {
        let alert = NSAlert()
        alert.messageText = "恢复原始档位配置？"
        alert.informativeText = "新档位在下次重新连接后可能消失；当前显示模式不会立即恢复。"
        alert.addButton(withTitle: "恢复配置")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        working = true
        Task {
            defer { working = false; reload() }
            do { try await HiDPIOverrideService.shared.restore(screen); configurationMessage = "原始配置已恢复；当前模式未改变" }
            catch { configurationMessage = error.localizedDescription }
        }
    }
}
