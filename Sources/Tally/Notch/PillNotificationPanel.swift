import AppKit
import SwiftUI

enum BadgeTheme: String, CaseIterable {
    case development, writing, design, data

    var label: String {
        switch self {
        case .development: "开发"
        case .writing: "写作"
        case .design: "设计"
        case .data: "数据"
        }
    }
}

private struct BadgeTextPool {
    let likes: [String]
    let dislikes: [String]
    let mottos: [String]
    let secrets: [String]
}

struct BadgeIdentity {
    let name: String
    let likes: String
    let dislike: String
    let motto: String
    let secret: String
    let color: Color
    let accessory: String

    private static let names = [
        "小满", "阿点", "小栈", "米粒", "阿序", "豆包", "小页", "阿野", "木木", "小七",
        "团团", "阿圆", "小格", "小谷", "阿麦", "小舟", "点点", "小橘", "栗子", "阿布",
        "小桥", "阿墨", "小沐", "阿初", "小石", "阿禾", "小鹿", "小北", "阿团", "小川", "小芽", "阿齐"
    ]
    private static let likes = [
        "一遍过，真香。", "全绿通关。", "生产平安，功德加一。", "代码自己好了，绝了。", "报错下班了。", "测试说通过，真甜。",
        "编译一次过，玄学。", "准点合并。", "版本天选，一路绿灯。", "本地宇宙，万事皆通。", "缺陷自动辞职。", "日志说人话。",
        "注释懂我，不必多言。", "周五不发版。", "一键回滚。", "缓存一次命中。", "变量名不变，谢天谢地。", "修完不许动。",
        "需求有终点。", "BUG，请自重。", "线上无事，勿扰。", "空指针失踪。", "分号补货。", "合并无冲突，太平了。",
        "打工人，必胜。", "绿灯护体。", "提测直通车。", "上线大吉。", "终端贴贴。", "需求已封印。",
        "代码已超度，安息。"
    ]
    private static let dislikes = [
        "周五上线。", "祖传代码。", "薛定谔的 BUG。", "说改一行，结果亿行。", "代码考古。", "玄学复现。",
        "凌晨夺命 call。", "线上手搓，心惊胆战。", "重启治百病，真怕了。", "本地没事，线上有事。", "需求复活甲。", "接口躲猫猫。",
        "PPT 驱动开发。", "这锅很烫。", "空指针偷袭。", "注释已退休。", "缓存刺客。", "日志猜谜。",
        "测试背刺。", "上线开盲盒。", "权限躲猫猫。", "只改亿点，信你个鬼。", "再跑一次，还不行。", "甲方召唤术。",
        "需求永动机。", "代码盲盒。", "改完又还原，白忙。", "部署抽卡。", "依赖套娃。"
    ]
    private static let mottos = [
        "能跑，别动。", "本地封神，线上封印。", "先别急，回滚。", "我来会会它。", "此事必有蹊跷。", "问题不大。",
        "重启大法，启动。", "先查，再茶。", "CPU 要冒烟了。", "臣领旨，这就修。", "此锅从何而来？", "谢邀，正在查。",
        "代码，先别动。", "再跑亿遍，万一呢。", "今天不背锅。", "这事，很难评。", "我有一个大胆的想法。", "建议重开。",
        "这合理吗？", "容我掐指一算。", "天选打工人，出列。", "先备个份。", "你礼貌吗？", "我看看，谁在渡劫。",
        "这就去，把它超度。", "刚才还好好的。", "来都来了，试试。", "别慌，能撤销。", "啊对对对，是队列。", "懂了，又没懂。",
        "先让日志开口。"
    ]
    private static let secrets = [
        "私藏回滚键。", "供奉小黄鸭。", "替 BUG 求过情。", "把锅甩给缓存。", "给报错起花名。", "偷偷拜键盘。",
        "凌晨和日志对话。", "写过玄学注释。", "修复靠许愿。", "曾对着编译进度念经。", "珍藏无错截图。", "以为缓存会自己好。",
        "给分号请过假。", "悄悄撤销重来。", "误把自己当甲方。", "和进度条斗法。", "日志里藏彩蛋。", "临时方案，住了三年。",
        "对 BUG 有了感情。", "把回滚练成了绝技。", "给服务续过命。", "在分支上迷路。", "曾被报错吓退。", "把注释当护身符。",
        "把告警当闹钟。", "给测试磕过一个头。", "工位修仙。", "默念一次过。", "收藏前任的锅。"
    ]
    private static let common = BadgeTextPool(
        likes: [
            "带薪喝水。", "准点跑路。", "午休封神，谁也别叫。", "摸鱼自由。", "会议取消，原地封神。", "薪水到账，终于显灵。",
            "甲方点头。", "老板失联，世界清静。", "薪想事成。", "工位结界，生人勿扰。", "下班闪现。", "带薪发呆。",
            "假装很忙。", "已读不回。", "大饼免疫，谢谢画饼。", "计划通，这次真通。", "周末满血。", "饭点封神。",
            "请假秒批。", "需求止步，不再加了。", "会议早退。", "表情包自由。", "今天无锅，轻装上班。", "免死金牌。"
        ],
        dislikes: [
            "周五加急。", "下班在吗。", "连环夺命 call。", "嘴上不急，心里加急。", "画饼充饥。", "下班夺命 call。",
            "隐形加班。", "会议永动机。", "无限返工。", "临时起意。", "口头需求，风一吹就变。", "人间饼王。",
            "工位召唤术，退散。", "十分钟会议，开一小时。", "薛定谔的定稿。", "赛博画饼。", "周一综合征。", "深夜在吗。",
            "需求刺客。", "临门一脚，又加需求。", "大饼里，还有大饼。", "嘴上不急，偷偷加急。", "明天要用，今天才说。", "休息日营业。"
        ],
        mottos: [
            "臣妾做不到。", "朕知道了。", "容我掐指算算。", "且慢，先喝口水。", "谢邀，人在工位。", "今天不背锅。",
            "这事，很难评。", "已读乱回。", "下班了，明天再议。", "略懂，略懂。", "容我缓缓，别催。", "此事必有蹊跷。",
            "摆驾食堂。", "臣先告退，下班了。", "天大地大，先吃饭吧。", "没事的话，我先溜了。", "主打一个稳，稳住。", "请开始，画饼。",
            "建议重开。", "容朕想想，别催。", "我先装忙，别拆穿。", "万事好商量，除了加班。", "退！退！退！", "少侠且慢，让我先吃饭。"
        ],
        secrets: [
            "工位养鱼。", "假装忙着发呆。", "收藏退堂鼓。", "暗号一响，准点跑路。", "私藏了下班铃声。", "曾被封为摸鱼王。",
            "已读之后，先装死。", "假装开会，实际喝水。", "偷偷藏了三块大饼。", "工牌有结界。", "开会时练习表情管理。", "带薪养鱼，鱼在心里。",
            "假装看日历，其实看假期。", "曾对“在吗”装没看见。", "工位里藏了零食。", "睡前默念一遍周报。", "曾把群设静音。", "躲过临时会。",
            "曾假装相信过画饼。", "私藏了一张跑路图。", "在工位偷偷贴了符。", "摸鱼，但怕水深。", "开会靠表情包替身。", "养了只鸽子，叫延期。"
        ]
    )
    private static let writing = BadgeTextPool(
        likes: [
            "一稿封神，可以下班。", "截稿续命。", "标题天选，一眼相中。", "灵感包邮，请查收。", "定稿自由。", "标点听话。",
            "删稿不痛，下次再写。", "编辑放假，稿子安全。"
        ],
        dislikes: [
            "最终版复活，再改一遍。", "标题刺客。", "灵感失联。", "一稿亿改，没完没了。", "甲方提笔，作者沉默。", "截稿倒计时。",
            "错字潜伏。", "临时加字。"
        ],
        mottos: [
            "笔下留情，字数超了。", "容我憋憋，灵感快来。", "灵感在路上。", "此稿，待渡劫。", "再改亿字，就交。", "一字千改，还不够。",
            "笔来，让我再改改。", "容我润润，再交稿。"
        ],
        secrets: [
            "私藏错别字。", "曾给输入法上过供。", "灵感靠催稿。", "拿稿纸当过枕头。", "给标题举办过选妃。", "曾梦见截稿。",
            "私藏废稿。", "曾给句号请过假。"
        ]
    )
    private static let design = BadgeTextPool(
        likes: [
            "一稿封神，可以下班。", "甲方闭麦，世界清静。", "像素对齐，强迫症舒坦。", "色号自由，不再返工。", "图层整齐，功德圆满。", "定稿不改。",
            "灵感暴富。", "对齐成精，一眼就准。"
        ],
        dislikes: [
            "五彩斑斓黑。", "再高级点，具体哪儿？", "像素刺客。", "甲方许愿，设计师渡劫。", "图层套娃。", "最终版复活，再改一遍。",
            "图要放大，字不能挡。", "你说随便，我重做。"
        ],
        mottos: [
            "让像素再飞一会儿。", "再挪一像素。", "此图有灵。", "给白色选个妃。", "再改亿点点，就好。", "图层先别动。",
            "对齐即正义。", "这版能打，别再改了。"
        ],
        secrets: [
            "曾把像素排得整整齐齐。", "私藏废稿。", "曾经拜过色卡。", "图层有花名。", "曾对色号许愿。", "对齐对到走火入魔。",
            "收藏甲方语录。", "画过摸鱼图。"
        ]
    )
    private static let data = BadgeTextPool(
        likes: [
            "数字听话，报表省心。", "口径大一统，普天同庆。", "表格成精，自己填数。", "报表显灵，数字对了。", "数据不背刺，谢天谢地。", "误差退散，小数点归位。",
            "刷新自由，不再转圈。", "小数点站稳，别乱跑。"
        ],
        dislikes: [
            "口径刺客。", "发数字只发截图。", "表格套娃。", "缺失值躲猫猫。", "手搓报表，搓到天亮。", "数字开盲盒，口径随缘。",
            "合并单元格。", "小数点出逃。"
        ],
        mottos: [
            "口径请归队，别乱跑。", "数据请开麦，说清楚。", "再刷亿遍，总会好的。", "让我盘盘，数在哪儿。", "这数从何而来？", "先别动，我的筛选。",
            "此数有诈，待我查查。", "表格请开口，别装死。"
        ],
        secrets: [
            "给异常数据起过名字。", "曾经拜过透视表。", "偷偷藏过一个小数点。", "给零值贴过寻人启事。", "偷偷给表格上了锁。", "半夜爬起来刷过数据。",
            "曾把小数点看错一位。", "把筛选条件藏进兜里。"
        ]
    )
    private static let looks: [(Color, String)] = [
        (Color(red: 0.87, green: 0.92, blue: 0.99), "star.fill"),
        (Color(red: 0.98, green: 0.91, blue: 0.85), "heart.fill"),
        (Color(red: 0.87, green: 0.95, blue: 0.91), "leaf.fill"),
        (Color(red: 0.95, green: 0.89, blue: 0.97), "sparkle")
    ]

    static func forSession(_ id: String, themes: [String] = []) -> BadgeIdentity {
        func choose<T>(_ values: [T], field: String) -> T {
            let key = "\(field):\(id)"
            let hash = key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            return values[Int(hash % UInt64(values.count))]
        }
        // 四份通用池与最多四个主题并列，确保通用文案始终占至少一半。
        var pools = [common, common, common, common]
        for theme in BadgeTheme.allCases where themes.contains(theme.rawValue) {
            switch theme {
            case .development: pools.append(BadgeTextPool(likes: likes, dislikes: dislikes, mottos: mottos, secrets: secrets))
            case .writing: pools.append(writing)
            case .design: pools.append(design)
            case .data: pools.append(data)
            }
        }
        let look = choose(looks, field: "look")
        return BadgeIdentity(name: choose(names, field: "name"),
                             likes: choose(choose(pools, field: "likes-pool").likes, field: "likes"),
                             dislike: choose(choose(pools, field: "dislike-pool").dislikes, field: "dislike"),
                             motto: choose(choose(pools, field: "motto-pool").mottos, field: "motto"),
                             secret: choose(choose(pools, field: "secret-pool").secrets, field: "secret"),
                             color: look.0, accessory: look.1)
    }

}

/// A notification occupies only its own visible capsule, leaving the gaps between pills clickable.
struct PillNotificationView: View {
    let peek: Peek
    let isInteractive: Bool
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var badgeEntered = false
    @State private var portraitStart = Date()
    @State private var badgeTextFinished = false

    private var isSession: Bool { peek.sessionId != nil && peek.provider != nil }

    @ViewBuilder
    var body: some View {
        if isInteractive {
            content.accessibilityAction(named: "打开提示", onTap)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if peek.style == .badge { badgeBody } else { pillBody }
    }

    private var badgeBody: some View {
        let identity = BadgeIdentity.forSession(peek.id, themes: PreferencesStore.shared.prefs.badgeThemes)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(0..<2) { _ in
                    VStack(spacing: 1) {
                        ForEach(0..<2) { _ in
                            Text("TALLY").font(.system(size: 4.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8)).rotationEffect(.degrees(90))
                                .frame(width: 11, height: 18)
                        }
                    }
                    .frame(width: 11, height: 45)
                    .background(Color(red: 0.09, green: 0.10, blue: 0.13))
                }
            }
            Capsule().fill(.gray.opacity(0.75)).frame(width: 28, height: 7).padding(.bottom, -3).zIndex(1)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(badgeTitle).font(.system(size: 10, weight: .heavy)).lineLimit(1)
                    Spacer()
                    Text(badgeHeading).font(.system(size: 9)).foregroundStyle(.black.opacity(0.4))
                }
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 8).fill(identity.color)
                        .saturation(peek.badgeKind == .departed ? 0 : 1)
                    badgePortrait
                        .saturation(peek.badgeKind == .departed ? 0 : 1)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: identity.accessory)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Circle().fill(.black.opacity(0.8)))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(badgeStamp)
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(badgeStampColor)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .overlay { Rectangle().strokeBorder(badgeStampColor, lineWidth: 2) }
                        .overlay { Rectangle().strokeBorder(badgeStampColor.opacity(0.8), lineWidth: 0.8).padding(4) }
                        .rotationEffect(.degrees(-7))
                        .scaleEffect(reduceMotion || badgeEntered ? 1 : 2.6)
                        .opacity(reduceMotion || badgeEntered ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.27, dampingFraction: 0.48).delay(1.1), value: badgeEntered)
                        .offset(x: -8, y: 5)
                }
                .frame(height: 68)
                VStack(alignment: .leading, spacing: 4) {
                    Text("花名").font(.system(size: 9, weight: .medium)).foregroundStyle(.black.opacity(0.42))
                    Text(identity.name).font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
                        .lineLimit(1).truncationMode(.middle)
                    badgeDetails(identity)
                    .padding(.top, 2)
                }
                .opacity(reduceMotion || badgeEntered ? 1 : 0)
                .offset(y: reduceMotion || badgeEntered ? 0 : 5)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35).delay(0.25), value: badgeEntered)
                Spacer(minLength: 0)
                Canvas { context, size in
                    let widths: [CGFloat] = [2, 1, 1, 2, 3, 1, 1, 1, 2, 3, 1, 1, 3, 2, 1, 1, 2, 1, 1, 3, 2, 1, 3, 1, 1, 2, 2, 1, 1, 1, 3, 2, 1, 3, 2, 1, 1, 2, 3, 1, 2, 2, 1, 1, 3, 1, 2, 3, 1, 1, 2, 1, 3, 2, 1, 1, 2, 3, 1, 2]
                    let unit = size.width / widths.reduce(0, +)
                    var x: CGFloat = 0
                    for (index, width) in widths.enumerated() {
                        let scaled = width * unit
                        if index.isMultiple(of: 2) {
                            context.fill(Path(CGRect(x: x, y: 0, width: scaled, height: size.height)), with: .color(.black.opacity(0.85)))
                        }
                        x += scaled
                    }
                }
                .frame(width: 134, height: 17)
                .accessibilityHidden(true)
            }
            .padding(12)
            .frame(width: 220, height: 305, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(red: 0.97, green: 0.97, blue: 0.98)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .rotationEffect(.degrees(reduceMotion ? 0 : (badgeEntered ? -3 : -12)), anchor: .top)
        .offset(y: !reduceMotion && !badgeEntered ? -55 : 0)
        .opacity(!reduceMotion && !badgeEntered ? 0 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .task(id: "\(peek.id)-\(badgeHeading)") {
            badgeTextFinished = false
            badgeEntered = false
            portraitStart = Date()
            guard !reduceMotion else { badgeTextFinished = true; badgeEntered = true; return }
            withAnimation(.spring(response: 1.1, dampingFraction: 0.42)) { badgeEntered = true }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            badgeTextFinished = true
        }
    }

    @ViewBuilder
    private var badgePortrait: some View {
        if reduceMotion {
            CrewBadgeIcon(mood: .run, size: 68, inset: 0.12)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
                CrewBadgeIcon(mood: .run, size: 68, inset: 0.12, elapsed: timeline.date.timeIntervalSince(portraitStart))
            }
            .frame(width: 68, height: 68)
        }
    }

    private var badgeTitle: String {
        let name = PreferencesStore.shared.prefs.badgeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "员工证" : name
    }

    private var badgeHeading: String {
        switch peek.badgeKind { case .joined: "入职工牌"; case .departed: "离职工牌"; case .returned: "返聘工牌" }
    }

    private var badgeStamp: String {
        switch peek.badgeKind { case .joined: "已入职"; case .departed: "已离职"; case .returned: "已返聘" }
    }

    private var badgeStampColor: Color {
        peek.badgeKind == .departed
            ? Color(red: 0.30, green: 0.35, blue: 0.40)
            : Color(red: 0.72, green: 0.13, blue: 0.11)
    }

    @ViewBuilder
    private func badgeDetails(_ identity: BadgeIdentity) -> some View {
        if reduceMotion || badgeTextFinished {
            badgeRows(identity, elapsed: nil)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                badgeRows(identity, elapsed: timeline.date.timeIntervalSince(portraitStart))
            }
        }
    }

    private func badgeRows(_ identity: BadgeIdentity, elapsed: TimeInterval?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            badgeRow("部门", peek.title, row: 0, elapsed: elapsed)
            badgeRow("岗位", peek.subtitle ?? "Agent", row: 1, elapsed: elapsed)
            badgeRow("喜欢", identity.likes, row: 2, elapsed: elapsed)
            badgeRow("不喜欢", identity.dislike, row: 3, elapsed: elapsed)
            badgeRow("口头禅", identity.motto, row: 4, elapsed: elapsed)
            badgeRow("小秘密", identity.secret, row: 5, elapsed: elapsed)
        }
    }

    private func badgeRow(_ label: String, _ value: String, row: Int, elapsed: TimeInterval?) -> some View {
        let start = 0.25 + Double(row) * 0.14
        let progress = elapsed.map { min(max(($0 - start) / 0.6, 0), 1) } ?? 1
        let visible = String(value.prefix(Int((Double(value.count) * progress).rounded(.down))))
        return HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(.black.opacity(0.4)).frame(width: 42, alignment: .leading)
            Text(value).opacity(0)
                .overlay(alignment: .topLeading) {
                    Text(visible).foregroundStyle(.black.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .lineLimit(2).truncationMode(.middle)
        }
        .font(.system(size: 11, weight: .medium))
    }

    private var pillBody: some View {
        HStack(spacing: 9) {
            PeekIcon(peek: peek, appeared: true)
                .frame(width: 29, height: 29)

            if isSession {
                sessionContent
            } else {
                genericContent
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            Capsule().fill(Color.black)
                .overlay { Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.7) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var sessionContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                ProviderLogo(name: peek.provider == "codex" ? "openai" : "claude", size: 10)
                Text(peek.modelLabel.flatMap { $0.isEmpty ? nil : $0 } ?? providerName)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("·")
                    .foregroundStyle(.white.opacity(0.4))
                Text(statusText)
                    .foregroundStyle(peek.tint)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 11, weight: .semibold))

            GeometryReader { geometry in
                HStack(spacing: 5) {
                    Text(peek.cwdLabel ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: min(104, geometry.size.width * 0.4), alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("·")
                        .foregroundStyle(.white.opacity(0.35))
                    Text(peek.failureMessage ?? peek.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 12)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var genericContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(peek.label)
                    .foregroundStyle(peek.tint)
                Text(peek.title)
                    .foregroundStyle(.white)
            }
            .font(.system(size: 11, weight: .semibold))
            if let subtitle = peek.subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private var providerName: String {
        peek.provider == "codex" ? "Codex" : "Claude"
    }

    private var statusText: String {
        if peek.failureMessage != nil { return "无法跳转" }
        return switch peek.sessionState {
        case .waitingPermission: "等审批"
        case .waitingInput: "等输入"
        case .ended: "已关闭"
        default: "完成"
        }
    }

    private var accessibilityText: String {
        if peek.style == .badge {
            let identity = BadgeIdentity.forSession(peek.id, themes: PreferencesStore.shared.prefs.badgeThemes)
            return [badgeStamp, "花名 \(identity.name)", "部门 \(peek.title)", "岗位 \(peek.subtitle ?? "Agent")", "喜欢 \(identity.likes)", "不喜欢 \(identity.dislike)", "口头禅 \(identity.motto)", "小秘密 \(identity.secret)"]
                .filter { !$0.isEmpty }.joined(separator: "，")
        }
        if isSession {
            return [providerName, peek.modelLabel ?? providerName, statusText, peek.cwdLabel ?? "", peek.failureMessage ?? peek.title]
                .filter { !$0.isEmpty }.joined(separator: "，")
        }
        return [peek.label, peek.title, peek.subtitle ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "，")
    }
}

private final class PillHostingView: NSHostingView<PillNotificationView> {
    var onTap: () -> Void

    required init(rootView: PillNotificationView) {
        onTap = rootView.onTap
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onTap()
    }
}

final class PillNotificationPanel: NSPanel {
    static let maxWidth: CGFloat = 320
    static let height: CGFloat = 44
    static let gap: CGFloat = 6

    private let pillHost: PillHostingView
    private var badgeHitTesting = false
    private var mouseMonitors: [Any] = []
    private var badgeStartedAt: Date?
    private var badgeEntranceTimer: Timer?

    init(peek: Peek, isInteractive: Bool, onTap: @escaping () -> Void) {
        pillHost = PillHostingView(rootView: PillNotificationView(peek: peek, isInteractive: isInteractive, onTap: onTap))
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: Self.maxWidth, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .mainMenu + 4
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = !isInteractive
        contentView = pillHost
        configureHitTesting(peek: peek, isInteractive: isInteractive)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(peek: Peek, isInteractive: Bool, onTap: @escaping () -> Void) {
        configureHitTesting(peek: peek, isInteractive: isInteractive)
        pillHost.onTap = onTap
        pillHost.rootView = PillNotificationView(peek: peek, isInteractive: isInteractive, onTap: onTap)
    }

    /// AppKit coordinates start at the bottom of the screen; the first pill starts below the notch.
    func place(on screen: NSScreen, offset: CGFloat, style: Peek.Style) {
        let height = Self.height(for: style)
        let width = style == .badge ? 300.0 : Self.maxWidth
        var frame = Self.placementFrame(in: screen.frame, safeAreaTop: screen.safeAreaInsets.top, offset: offset, width: width, height: height)
        if style == .badge {
            let right = PreferencesStore.shared.prefs.badgePosition != "left"
            frame.origin.x = Self.badgeX(in: screen.frame, width: frame.width, leftWidth: screen.auxiliaryTopLeftArea?.width ?? screen.frame.width / 2, rightWidth: screen.auxiliaryTopRightArea?.width ?? screen.frame.width / 2, right: right)
        }
        setFrame(frame, display: true)
        updateBadgeHitTesting()
    }

    override func close() {
        badgeEntranceTimer?.invalidate()
        badgeEntranceTimer = nil
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
        super.close()
    }

    static func badgeContains(_ point: CGPoint, in size: CGSize, entering: Bool = false) -> Bool {
        let card = CGRect(x: (size.width - 220) / 2, y: size.height - 354, width: 220, height: 305)
        let strap = CGRect(x: (size.width - 32) / 2, y: size.height - 52, width: 32, height: 52)
        return (entering ? card.insetBy(dx: -30, dy: -20) : card.insetBy(dx: -10, dy: -6)).contains(point) || strap.contains(point)
    }

    private func configureHitTesting(peek: Peek, isInteractive: Bool) {
        badgeHitTesting = isInteractive && peek.style == .badge
        if badgeHitTesting && mouseMonitors.isEmpty {
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                badgeStartedAt = Date()
                let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateBadgeHitTesting() }
                }
                RunLoop.main.add(timer, forMode: .common)
                badgeEntranceTimer = timer
            }
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
                DispatchQueue.main.async { self?.updateBadgeHitTesting() }
            }) { mouseMonitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
                self?.updateBadgeHitTesting()
                return event
            }) { mouseMonitors.append(monitor) }
        } else if !badgeHitTesting {
            badgeStartedAt = nil
            badgeEntranceTimer?.invalidate()
            badgeEntranceTimer = nil
            for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
            mouseMonitors.removeAll()
        }
        ignoresMouseEvents = !isInteractive
        updateBadgeHitTesting()
    }

    private func updateBadgeHitTesting() {
        guard badgeHitTesting else { return }
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
        let entering = badgeStartedAt.map { Date().timeIntervalSince($0) < 1.5 } ?? false
        ignoresMouseEvents = !Self.badgeContains(local, in: frame.size, entering: entering)
    }

    static func height(for style: Peek.Style) -> CGFloat { style == .badge ? 370 : height }

    static func badgeX(in screen: CGRect, width: CGFloat, leftWidth: CGFloat, rightWidth: CGFloat, right: Bool) -> CGFloat {
        let anchor = right ? screen.maxX - rightWidth + 40 : screen.minX + leftWidth - 40
        return min(max(anchor - width / 2, screen.minX + 16), screen.maxX - width - 16)
    }

    static func placementFrame(in screenFrame: CGRect, safeAreaTop: CGFloat, offset: CGFloat, width: CGFloat, height: CGFloat, rightAligned: Bool = false) -> CGRect {
        let width = min(width, max(1, screenFrame.width - 32))
        let top = screenFrame.maxY - safeAreaTop - gap - offset
        let x = rightAligned ? screenFrame.maxX - width - 16 : screenFrame.midX - width / 2
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    static func placementFrame(in screenFrame: CGRect, safeAreaTop: CGFloat, index: Int) -> CGRect {
        placementFrame(in: screenFrame, safeAreaTop: safeAreaTop, offset: CGFloat(index) * (height + gap), width: maxWidth, height: height)
    }
}
