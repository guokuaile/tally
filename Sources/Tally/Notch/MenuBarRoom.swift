import AppKit
import ApplicationServices

/// 菜单栏给两翼留了多少地方（docs/crew.md「让开菜单」）。翼的层级在菜单栏之上，不量的话前台 app 的菜单排到哪儿就盖到哪儿：
/// 14 寸屏上 Chrome 中文菜单排到 592pt，左翼两格从 585 起，「帮助」就被压住。
enum MenuBarRoom {

    /// 纯函数。`menuEnd` 是最右那一项菜单的右缘相对菜单栏左缘的距离。
    /// 左翼露在菜单栏上的宽度是两端内边距加各格（伸到刘海底下那 12pt 不占菜单栏）；右翼只在菜单折到刘海右边时让。
    static func room(menuEnd: CGFloat, on m: ScreenMetrics) -> CrewRoom {
        let free = m.auxiliaryTopLeftWidth - menuEnd
        // 菜单排过了刘海左缘：系统把排不下的折到刘海右边、紧贴刘海，两翼都没地方
        guard free >= 0 else { return CrewRoom(left: 0, right: 0) }
        return CrewRoom(left: max(0, Int((free - CrewGeometry.inset * 2) / CrewGeometry.slot)), right: .max)
    }

    /// 纯函数：菜单栏和各项的横向范围（屏幕坐标）→ 最右那一项的右缘相对菜单栏左缘的距离；一项能算的都没有返回 nil。
    /// 减掉菜单栏自己的左缘：接着外接屏时报上来的可能是另一块屏上的那条，各屏上菜单从左缘起的排法一样。
    /// 只认落在菜单栏范围里、有宽度的项：数是别的进程报上来的，一个没宽度或跑到屏幕外的项不该把两翼挤没。
    static func menuEnd(bar: ClosedRange<CGFloat>, items: [ClosedRange<CGFloat>]) -> CGFloat? {
        items.filter { $0.upperBound > $0.lowerBound && $0.lowerBound >= bar.lowerBound && $0.upperBound <= bar.upperBound }
            .map(\.upperBound).max().map { $0 - bar.lowerBound }
    }

    /// 这个 app 的菜单排到哪儿：只取各项的位置和宽度，不读标题与内容。没给辅助功能权限、对方没响应、没有菜单栏返回 nil。
    /// 要在后台队列调：对方卡住时每次取值都等满超时。
    static func menuEnd(pid: pid_t) -> CGFloat? {
        // 没授权时下面每个调用都是失败，先问一句就不用白发那十几次
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let bar = value as! AXUIElement
        var children: CFTypeRef?
        guard let barSpan = span(bar),
              AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        return menuEnd(bar: barSpan, items: items.compactMap(span))
    }

    private static let timeout: Float = 0.5

    /// 元素的横向范围（屏幕坐标）。超时逐个元素设：头文件写明它只对传进去的那一个对象生效，设在 app 元素上管不到菜单栏和各项。
    private static func span(_ element: AXUIElement) -> ClosedRange<CGFloat>? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent), extent.width >= 0 else { return nil }
        return origin.x...(origin.x + extent.width)
    }
}
