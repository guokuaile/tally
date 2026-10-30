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
        "一次跑过，假装常态", "需求写全，堪比过年", "周五上线，周一没事", "会议取消，喜提午睡",
        "复现成功，凶手落网", "测试全绿，群里报喜", "说好不改，真的不改", "报错认错，主动消失",
        "领导说好，不加但是", "咖啡没凉需求就过了", "删掉代码，奖金翻倍", "一眼看懂上周的自己",
        "部署完毕，手机静音", "需求不变，普天同庆", "午饭没凉，构建也好", "周报只写一行搞定",
        "接口准时，甲方鼓掌", "需求评审居然有结论", "日志说人话的那天", "会议十分钟准时散场",
        "需求写少，奖金不少", "写完注释就忘了为啥", "能撤销的人生选择", "刚合完就没人提修改",
        "进度百分百真的结束", "终于等到一句辛苦了", "周五五点老板发红包", "加班取消，代码也绿",
        "同步一下只需一分钟", "验收通过不附赠新活", "摸鱼时告警也在摸鱼"
    ]
    private static let dislikes = [
        "周五下班前说很急", "只改一行的第十稿", "昨天能跑今天装死", "凌晨三点的你睡了吗",
        "报错只说未知错误", "会议主题叫简单聊聊", "需求说差不多就行", "截图只截到报错一半",
        "排期明天，需求明天给", "刚下班的那句在吗", "最后一版的下一版", "代码写完才想起备份",
        "需求文档写参照之前", "群里说一句都没问题", "说好不改转头改表", "改完又说还是原来好",
        "空指针比我先下班", "全员通过后有人反对", "临上线突然换需求", "定时任务定在饭点",
        "说好的十分钟开一小时", "测试说偶现但没截图", "重启解决但没敢问为啥", "看起来简单你先做",
        "明明周五却像周一", "已读不回的审批人", "一改配置全员在线", "上线后说顺便加一个",
        "没留注释的前任自己"
    ]
    private static let mottos = [
        "我先看看锅在哪。", "这锅先别急着端。", "能跑，先别碰。", "本地好着呢。", "我先假装很淡定。", "重启一下再说。",
        "这行代码看着眼熟。", "先查日志，再查黄历。", "再试一次，万一呢。", "不是我，是缓存。", "我记得昨天是好的。", "等我找找上次的锅。",
        "我先把撤回备好。", "这次真的最后一版。", "先别慌，截图了吗？", "我去跟报错讲讲理。", "别催，进度条在走。", "等我喝口水再背锅。",
        "先让我装作会了。", "我再查查是谁写的。", "需求有变，表情不变。", "没事，先备份。", "代码不动，我先动。", "这下真得加班了。",
        "让我和电脑商量下。", "这个得问昨天的我。", "给我一分钟，或者一晚。", "先过测试，再过周末。", "别问，问就是在查。", "我怀疑它认识我。", "截图留证，日后好说。"
    ]
    private static let secrets = [
        "开会时偷偷看构建", "把需求文档当催眠曲", "代码跑通后拜过键盘", "把缓存藏成私人零食", "曾给报错取名小祖宗", "测试变绿时偷着鼓掌",
        "备份文件叫千万别删", "曾靠重启蒙混过关", "看到已读就开始紧张", "给最后一版建了十份", "把小黄鸭问到想离职", "周报里藏过一个摸鱼",
        "对着进度条念过快点", "开会静音偷偷叹气", "曾给变量起名随便吧", "把项目群设成勿扰", "假装喝水其实在发呆", "曾经给打印日志道歉",
        "合代码前偷偷拜过天", "想把需求塞进碎纸机", "周五备份比需求还多", "给闹钟备注别再上线", "改完又悄悄改回去了", "给离谱报错颁过奖",
        "给待办清单画过墓碑", "装作忙着其实在找锅", "曾对加载圈喊过加油", "给老板的在吗设了铃声", "键盘回车键比我勇敢"
    ]
    private static let common = BadgeTextPool(
        likes: ["会议取消，喜提午睡", "领导说好，不加但是", "周五五点老板发红包", "需求写全，堪比过年", "说好不改，真的不改", "午饭没凉，事情办完", "下班准点，手机静音", "周报只写一行搞定", "评审居然当场有结论", "会议十分钟准时散场", "需求写少，奖金不少", "能撤销的人生选择", "刚交完就没人提修改", "进度百分百真的结束", "终于等到一句辛苦了", "加班取消，晚饭还热", "同步一下只需一分钟", "验收通过不附赠新活", "摸鱼时群消息也摸鱼", "周五下班没人在找我", "老板说的随便是真随便", "请假申请秒通过", "一觉醒来待办自己少了", "今天的锅不是我的"],
        dislikes: ["周五下班前说很急", "只改一行的第十稿", "凌晨三点的你睡了吗", "会议主题叫简单聊聊", "需求说差不多就行", "截图只截到问题一半", "排期明天，需求明天给", "刚下班的那句在吗", "最后一版的下一版", "文档里只写参照之前", "群里说一句都没问题", "改完又说还是原来好", "全员通过后有人反对", "临交付突然换需求", "定时会议定在饭点", "说好的十分钟开一小时", "看起来简单你先做", "明明周五却像周一", "已读不回的审批人", "交付后说顺便加一个", "下班前收到临时会议", "谁有空三个字的陷阱", "半夜弹出的紧急消息", "先做着细节以后再说"],
        mottos: ["我先看看锅在哪。", "这锅先别急着端。", "我先假装很淡定。", "再试一次，万一呢。", "我记得昨天是好的。", "等我找找上次的锅。", "我先把撤回备好。", "这次真的最后一版。", "先别慌，截图了吗？", "别催，进度条在走。", "等我喝口水再背锅。", "先让我装作会了。", "需求有变，表情不变。", "这下真得加班了。", "这个得问昨天的我。", "给我一分钟，或者一晚。", "别问，问就是在查。", "截图留证，日后好说。", "我先确认谁来拍板。", "今天的事明天再慌。", "让我先找个会议室。", "等我把表情管理做好。", "先问清楚再点头。", "我看看有没有后一句。"],
        secrets: ["把需求文档当催眠曲", "看到已读就开始紧张", "给最后一版建了十份", "周报里藏过一个摸鱼", "对着进度条念过快点", "开会静音偷偷叹气", "把项目群设成勿扰", "假装喝水其实在发呆", "想把需求塞进碎纸机", "改完又悄悄改回去了", "给待办清单画过墓碑", "装作忙着其实在找锅", "给老板的在吗设了铃声", "把会议录音当白噪音", "下班前反复刷新审批", "偷偷数过会议里的人", "把加急消息静音三秒", "工位零食比任务还多", "做过一份未发送的周报", "给日历上的会起外号", "把最后一版藏在桌面", "在表情包里偷偷翻白眼", "曾把已收到打成救命", "把待办写在咖啡杯上"]
    )
    private static let writing = BadgeTextPool(
        likes: ["一稿通过，原地过年", "标题一改阅读就涨", "截稿之前灵感上班", "甲方说这版不用改", "字数刚好卡在及格线", "开头写完结尾也来了", "校对完发现零错字", "删掉废话版面还够"],
        dislikes: ["再改得有感觉一点", "标题重写只改一个字", "定稿之后又换主题", "一千字说成一句话", "昨天定稿今天返工", "文案写完补一句都行", "故事讲完才给素材", "截止明天素材下周给"],
        mottos: ["这个标题我再想想。", "再给灵感打个电话。", "这版真的叫最终稿。", "先让我编，不是，写。", "这个逗号有话要说。", "我再删几个字。", "别急，灵感在路上。", "这句我能改一下午。"],
        secrets: ["给删掉的句子留了坟", "最终稿后面还有十九版", "对着标题发过半天呆", "把灵感记在外卖单上", "写完才发现忘了保存", "收藏过一百种开头", "靠数标点拖延过交稿", "曾为一个词翻遍词典"]
    )
    private static let design = BadgeTextPool(
        likes: ["一稿定案甲方满意", "字体齐了心情也齐", "像素对上准时下班", "参考图终于只有一张", "色号一次就被选中", "审美突然达成一致", "图层命名都能看懂", "最终稿不用再另存"],
        dislikes: ["再高级一点点", "颜色要五彩斑斓的黑", "图放大但不要挡字", "甲方说随便然后都不行", "请把红色调得更绿", "改个像素顺便换个风格", "最终版又多了个新建", "参考图只有一张截图"],
        mottos: ["我把像素挪一挪。", "这个颜色再呼吸一下。", "这版真的不能再大了。", "我再找找参考图。", "先对齐，再叹气。", "这字还能再大一点。", "我让图层冷静一下。", "白色也有很多种。"],
        secrets: ["私藏了十八版最终稿", "偷偷量过一像素间距", "给图层取过奇怪名字", "曾对配色盘许愿", "调色调到忘了吃饭", "把废稿藏进了灵感库", "偷偷把图层名字改回去", "看见没对齐就想伸手"]
    )
    private static let data = BadgeTextPool(
        likes: ["报表对上提前下班", "表格没乱就是晴天", "口径统一堪比奇迹", "数据刷新一次就对", "透视表居然听话", "数字刚好对上老板的", "筛选条件终于没漏", "小数点待在正确位置"],
        dislikes: ["这两个数字怎么不同", "口径明天换个说法", "表格只发了截图", "求和之前合并了单元格", "报表数字手工再改改", "缺失值假装自己是零", "数据昨晚还是这个数", "筛选条件藏在第八列"],
        mottos: ["我再核一下口径。", "这数字有点眼熟。", "让我再刷新一次。", "先别动我的筛选。", "这列是谁偷偷加的？", "差一个小数点而已。", "我先和表格聊聊。", "数字不会说谎吧。"],
        secrets: ["给异常数据起过外号", "偷偷给表格上过锁", "曾把小数点数了三遍", "用颜色区分谁动过表", "把透视表当占卜工具", "做过一份没人看的报表", "开会时悄悄刷新数据", "给零值写过寻人启事"]
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
