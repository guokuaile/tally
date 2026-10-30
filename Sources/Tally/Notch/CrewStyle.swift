import SwiftUI

/// 一个项目折叠出来的状态；数字小的更急，名册按它排序、翅膀按它选片段。
enum CrewMood: Int, CaseIterable, Comparable {
    case permission = 0, input, compacting, run, done, stale

    static func < (lhs: CrewMood, rhs: CrewMood) -> Bool { lhs.rawValue < rhs.rawValue }

    var clip: String {
        switch self {
        case .permission: "crew-permission"
        case .input: "crew-input"
        case .compacting: "crew-compacting"
        case .run: "crew-run"
        case .done: "crew-done"
        case .stale: "crew-stale"
        }
    }

    var label: String {
        switch self {
        case .permission: "等审批"
        case .input: "等输入"
        case .compacting: "压缩中"
        case .run: "在跑"
        case .done: "完成"
        case .stale: "失联"
        }
    }

    /// 减少动态效果时取的那一帧（秒），和第 7 版预览定格页的 `STILL` 表一致（在跑取 0.9 不取 3.5：那一刻环绕线伸进邻座，静态时不要）
    var still: (clip: String, time: Double) {
        switch self {
        case .permission: ("crew-permission", 1.6)
        case .input: ("crew-input", 2.0)
        case .compacting: ("crew-compacting", 3.2)
        case .run: ("crew-run", 0.9)
        case .done: ("crew-done", 3.0)
        case .stale: ("crew-stale", 0)
        }
    }

    /// 等审批、等输入才有「等久了」的档
    var isWaiting: Bool { self == .permission || self == .input }

    /// 落灰档借失联的片段：半合眼、灰身，就是等久了的样子（docs/crew.md「等久了换档」）
    func clip(tier: CrewTier) -> String { tier == .dusty && isWaiting ? CrewMood.stale.clip : clip }
    func still(tier: CrewTier) -> (clip: String, time: Double) { tier == .dusty && isWaiting ? CrewMood.stale.still : still }
}

/// 等审批、等输入的角色按等了多久分档；别的 mood 恒为刚弹出。
enum CrewTier: Int, Comparable {
    case fresh = 0, lingering, dusty

    static let lingeringAfter: TimeInterval = 3 * 60
    static let dustyAfter: TimeInterval = 10 * 60

    static func < (lhs: CrewTier, rhs: CrewTier) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 不在等（nil）就是刚弹出那一档
    static func of(waited: TimeInterval?) -> CrewTier {
        guard let waited else { return .fresh }
        return waited >= dustyAfter ? .dusty : waited >= lingeringAfter ? .lingering : .fresh
    }
}

/// 状态 + 套系 → 绘制样式。配色照第 7 版预览按**表情**分，不按工具或左右：在跑 coral、等审批 peach、等输入 rose 是暖，压缩中 mint、完成 sky 是冷，
/// 失联 ash；玻璃套系的描边只看冷暖（两套流光），填色和眼皮色只给渐变套系。纯函数，绘制函数不认识片段，只看样式和帧字段。
enum CrewStyle {
    struct Palette {
        let rim: [Color]
        let fill: (top: Color, bottom: Color)
        let lid: Color
    }

    private static func hex(_ values: String...) -> [Color] { values.map { BloubArt.color($0)! } }

    /// 两套流光和预览一样：暖是 coral 那套的色环，冷是 AI 页那套蓝紫青；失联灰
    static let warmRim = hex("#FF7A3C", "#FF487A", "#FFB05C", "#FFE078", "#FF6C54", "#FF7A3C")
    static let coolRim = BloubArt.rimColors
    static let ashRim = hex("#787E8C", "#969CAA", "#787E8C")

    static let coral = Palette(rim: warmRim, fill: (hex("#FFB36B")[0], hex("#FF6A5B")[0]), lid: hex("#FF8E63")[0])
    static let peach = Palette(rim: warmRim, fill: (hex("#FFD66B")[0], hex("#FF8A4B")[0]), lid: hex("#FFAE58")[0])
    static let rose = Palette(rim: warmRim, fill: (hex("#FFA36B")[0], hex("#FF5C8A")[0]), lid: hex("#FF7E79")[0])
    static let mint = Palette(rim: coolRim, fill: (hex("#8CF5D2")[0], hex("#2BC48A")[0]), lid: hex("#5EDDAE")[0])
    static let sky = Palette(rim: coolRim, fill: (hex("#8FE8FF")[0], hex("#3B9CF5")[0]), lid: hex("#63C2FA")[0])
    static let ash = Palette(rim: ashRim, fill: (hex("#9AA1AE")[0], hex("#5B6270")[0]), lid: hex("#7A8290")[0])
    static let amber = hex("#FFC53D")[0]
    static let cyan = hex("#7DE3F7")[0]
    /// 等久了的光晕：满 3 分钟橙，满 10 分钟红
    static let orange = hex("#FF8C1A")[0]
    static let red = hex("#FF4D4D")[0]
    /// 预览里合眼 / 半眼皮的眼皮色
    static let glassLid = hex("#1B1D24")[0]

    /// 预览 `STATES` 表的配色
    static func palette(for mood: CrewMood) -> Palette {
        switch mood {
        case .run: coral
        case .permission: peach
        case .input: rose
        case .compacting: mint
        case .done: sky
        case .stale: ash
        }
    }

    static func style(mood: CrewMood, skin: BloubArt.Style.Skin, tier: CrewTier = .fresh) -> BloubArt.Style {
        let tier = mood.isWaiting ? tier : .fresh
        // 落灰档配失联的灰身；和真失联的区别只在光晕：真失联没有
        let colors = tier == .dusty ? ash : palette(for: mood)
        var style = BloubArt.Style()
        style.skin = skin
        style.rim = colors.rim
        style.fill = skin == .gradient ? colors.fill : nil
        style.lid = skin == .gradient ? colors.lid : glassLid
        style.glow = switch tier {
        case .dusty: red
        case .lingering: orange
        case .fresh: mood == .permission ? amber : mood == .input ? cyan : nil
        }
        // 失联片段每帧光晕量是 0，红光晕要自己给量：取呼吸区间的中值、不呼吸，落灰了就别再喘
        if tier == .dusty { style.glowAmount = 0.5 }
        style.compactSymbol = true
        style.small = true
        return style
    }
}
