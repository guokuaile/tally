import SwiftUI

/// 翅膀窗口的尺寸与位置，全是纯函数。两翼从物理刘海的左右缘往里 12pt 起，和闭合态面板同高；
/// 物理刘海的底角是圆的，闭合面板的底角也跟着圆（半径 12），翼只贴到刘海边的话两段圆弧之间露一条缝，
/// 所以翼往刘海底下多伸 12pt 把那块填黑；面板级别更高盖在翼上，接缝看不出来。
enum CrewGeometry {
    enum Side: CaseIterable { case left, right }

    /// 一格 31pt：22pt 球身加左右各 4.5pt 空隙；翼两端各留 8pt。
    static let slot: CGFloat = 31
    static let body: CGFloat = 22
    static let inset: CGFloat = 8
    /// 靠刘海那头伸到物理刘海底下的部分，和闭合面板的底角半径一样大，正好填掉圆角缝
    static let overlap: CGFloat = NotchGeometry.closedBottomRadius
    /// 外侧底角圆角和闭合态一致，内侧直角贴面板。
    static let bottomRadius: CGFloat = 12
    /// 球心离翼顶 19pt：球底离带子底 2pt（翼高 32 时）。
    static let bodyCenterY: CGFloat = 19
    /// bloub 画布里球直径 200 单位 → 22pt
    static let scale: CGFloat = body / 200

    static func wingWidth(slots: Int) -> CGFloat {
        slots > 0 ? overlap + inset * 2 + CGFloat(slots) * slot : 0
    }

    /// 空翼或没有刘海返回 nil。右翼从物理刘海右缘往里 12pt 起，左翼到物理刘海左缘往里 12pt 止。
    static func wingFrame(side: Side, slots: Int, on m: ScreenMetrics) -> CGRect? {
        guard slots > 0, m.safeAreaTop > 0 else { return nil }
        let width = wingWidth(slots: slots)
        let y = m.frame.maxY - m.safeAreaTop
        switch side {
        case .right: return CGRect(x: m.frame.maxX - m.auxiliaryTopRightWidth - overlap, y: y, width: width, height: m.safeAreaTop)
        case .left: return CGRect(x: m.frame.minX + m.auxiliaryTopLeftWidth + overlap - width, y: y, width: width, height: m.safeAreaTop)
        }
    }

    /// Slots are ordered outward from the notch and occupy the full height.
    static func slotRect(side: Side, index: Int, slots: Int, height: CGFloat) -> CGRect {
        let fromNotch = overlap + inset + CGFloat(index) * slot
        let width = slot
        let x = side == .right ? fromNotch : wingWidth(slots: slots) - fromNotch - width
        return CGRect(x: x, y: 0, width: width, height: height)
    }

    /// The horizontal center in wing coordinates.
    static func slotCenterX(side: Side, index: Int, slots: Int) -> CGFloat {
        let rect = slotRect(side: side, index: index, slots: slots, height: 0)
        return side == .right ? rect.minX + slot / 2 : rect.maxX - slot / 2
    }

    /// 相邻小人之间留空隙，指针落在两者中间时不触发旁边的会话。
    static func hitRect(side: Side, index: Int, slots: Int, height: CGFloat) -> CGRect {
        slotRect(side: side, index: index, slots: slots, height: height).insetBy(dx: 2, dy: 0)
    }

    /// Exclude the notch overlap and margins from hit testing.
    static func slot(atX x: CGFloat, side: Side, slots: Int) -> Int? {
        (0..<slots).first { index in
            let rect = hitRect(side: side, index: index, slots: slots, height: 1)
            return x >= rect.minX && x < rect.maxX
        }
    }

    /// 翼的轮廓：外侧底角圆角，内侧直角贴面板。
    static func outline(side: Side, size: CGSize) -> Path {
        let r = bottomRadius
        return Path(roundedRect: CGRect(origin: .zero, size: size),
                    cornerRadii: RectangleCornerRadii(topLeading: 0, bottomLeading: side == .left ? r : 0, bottomTrailing: side == .right ? r : 0, topTrailing: 0))
    }
}
