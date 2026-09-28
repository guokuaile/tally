# 「音乐」页

> 系统「正在播放」的那首歌：封面、歌名、歌手、哪个播放器，上一曲 / 播放暂停 / 下一曲。哪个播放器都认（Apple Music、Spotify、酷狗、网易云、浏览器里的视频），不用逐个适配、不弹任何授权框。

## 边界

- 只有展开态的一页，闭合态不画（那 189pt 里有 185 是摄像头外壳，见 [panel.md](panel.md)）。
- 不做进度条和拖动进度：进度是播放器自己报的，酷狗暂停、继续之后一直报旧值，照着画是错的。不做歌词、音量、随机 / 循环、换歌时垂提示条。
- 不判断播放器支不支持上一曲 / 下一曲（浏览器里单个视频没有下一个，按了没反应）：要判得多用一组私有接口，第一版不值。
- 这是全仓库唯一用私有接口的地方，而且借了系统的一个口子（见下）。苹果哪天堵上、或者把 perl 从系统里拿掉，这一页就没了；所以它自检、失效就整页藏起来，别的功能不受影响。

## 数据怎么来（`Sources/TallyMedia/helper.m` + `NowPlayingMonitor`）

系统里管「正在播放」的是私有框架 MediaRemote（控制中心、锁屏那块就是它）。macOS 15.4 起 `mediaremoted` 只回答它信任的客户端：自签的 Tally 直接调 `MRMediaRemoteGetNowPlayingInfo` 拿到的是空字典、`IsPlaying` 恒为 false（macOS 26.2 实测：同一份代码在苹果签名的 `swift` 解释器进程里读得到歌名，编成独立二进制就是 0 个字段）。被排除的路：

| 路 | 为什么不走 |
|---|---|
| 直接调 MediaRemote | 15.4 起读不到 |
| AppleScript / 系统广播（`com.apple.Music.playerInfo`、`com.spotify.client.PlaybackStateChanged`） | 只认 Apple Music 和 Spotify，酷狗、网易云、浏览器都看不到；AppleScript 还要每个播放器弹一次自动化授权 |
| 模拟键盘上的媒体键 | 只能控制、读不到歌名，还要新增「辅助功能」授权 |
| 打包现成的 mediaremote-adapter | 460 KB 的第三方 framework + perl 脚本，和「零第三方依赖」冲突 |

走的路：`/usr/bin/perl` 是平台二进制，`mediaremoted` 信它，它的签名又不带库校验，能加载别人的 dylib。Tally 把自己写的一个小 dylib（一个 `.m` 文件，打包时单独一行 `clang -dynamiclib` 编出来、放在 `Contents/Frameworks/libtallymedia.dylib`，不链进 app，所以不走 SwiftPM，命令见下）交给 perl 加载，在 perl 的进程里调 MediaRemote。boring.notch、Atoll、mew-notch、cyclop 都是这个做法；dylib 是 arm64、perl 是 arm64e，实测能加载。

```bash
# 编助手（-Werror：它跑在别人的进程里，警告也不放过）
clang -dynamiclib -fobjc-arc -O2 -Wall -Werror -arch arm64 -mmacosx-version-min=15.0 -framework Foundation \
  -o Tally.app/Contents/Frameworks/libtallymedia.dylib Sources/TallyMedia/helper.m
# Tally 起它
/usr/bin/perl -e 'use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0x01) or die; while (1) { sleep 3600; }' <dylib>
```

### 助手的约定

- **stdout 一行一个 JSON**：`playing`（bool）、`title`、`artist`、`album`、`pid`（播放器进程，Tally 拿它取名字和图标；头一行可能还是 0）、`artworkId`、`artwork`（base64，只在封面换了的那一行带——一张十几万字符）。`title` 为空就是没有在播放的会话。起不来时发一行 `{"error": …}`。歌名、歌手这些是别的 app 报上来的，不是字符串一律当空：放进去一个 `NSDate`，`NSJSONSerialization` 抛的是异常，perl 会崩了重起、再崩。
- **和上一行一样就不发**：通知之外还每 2 秒轮询一次（cyclop 在 macOS 26 上测到过整段 30 秒一条通知都不来、期间真的换过歌），不去重的话 Tally 每 2 秒白解析一行。
- **stdin 一行一条命令**：`toggle` / `next` / `prev`（`MRMediaRemoteSendCommand` 的 2 / 4 / 5），发完 0.3 秒主动再读一次，按钮按下去界面马上跟上；`get` 让助手忘掉发过什么、重发一份完整的。
- **stdin 一关就退出**：Tally 正常退出、重装时被杀掉、崩了，管道都会关，perl 跟着走，不留孤儿（boring.notch 踩过）。
- dylib 的构造函数里只起线程、马上返回：`dlopen` 期间持着 dyld 的锁，在构造函数里阻塞的话线程里那次 `dlopen(MediaRemote)` 永远等不到。

### Tally 这一侧（`NowPlayingMonitor`）

- 「音乐」开着就一直跑着助手（不常驻时要靠它知道有没有在播，才决定页签出不出现），关掉就关管道让它退出。一个闲着的 perl 常驻内存约 19 MB（实测），2 秒一次轮询不占 CPU。
- 封面的取舍：这一行带了封面就用它；没带，`artworkId` 和手里那张一样就留着，不一样就清掉（换歌了、新封面还没到，宁可先空着也不挂上一首的）。
- 助手意外退出就重起；起来不到一分钟就退的算一次「起不来」，连着三次就不再试（只认「几秒内就退」的话，每次撑七八秒再崩的会被一直重起下去），整页藏起来，设置「音乐」里亮出原因；改一下开关或重开 Tally 再试。app 包里没有那份 dylib（`swift run`、测试）同样算起不来。
- 助手没在跑（退了还没重起的那一秒）时按的按钮会丢，记一条日志，不然「按了没反应」无处可查。
- 写命令的管道要设 `F_SETNOSIGPIPE`（对管道同样生效，探针实测：读端关了再写，进程活着、`write` 返回 EPIPE）：助手已经没了的那一刻按按钮，不设的话 SIGPIPE 直接带走整个 Tally。
- 演示模式不起助手：那是真机状态，录 README 时不该出现你正在听的歌。

## 页签出不出现（`LaunchOptions.Page.visible(shelf:music:)`、`NowPlayingMonitor.showsPage`）

设置「音乐」两个开关：

| 开关 | 默认 | 作用 |
|---|---|---|
| 「音乐」页（`musicEnabled`） | 开 | 关掉不起助手、不出页签 |
| 页签常驻（`musicResident`） | 关 | 开：页签一直在，没在播时页里说「没有在播放的内容」。关：有「正在播放」的会话才出现（暂停着也算），播放器退出后消失 |

页签排在最后（文件架后面）：它会随播放出现、消失，排中间的话别的页签跟着挪位置，数字键 1–9 对应的页也跟着变。正停在音乐页时它消失了（播放器退了、开关关了、助手起不来）就回到 AI 页；启动时记着的上一页是音乐的，那一刻助手还没报上来，先落在 AI 页，读到有在播的会话再切回去（`lastPage` 只有这次降级不跟着改，人自己点过别的页就不切）。

## 页面

一张卡片：左边封面 72pt（没有封面画音符占位），中间歌名、「歌手 · 专辑」、播放器图标 + 名字（`NSRunningApplication(processIdentifier:)`），右边三颗按钮。点按钮以外的那一片（封面、歌名那一段）把播放器叫到前台：走 `NSWorkspace.openApplication(at:)` 而不是 `activate()`——它带 reopen，窗口关着、只剩 Dock 图标的播放器（酷狗关掉主窗口后就是这样）也会把主窗口弹出来；拿不到 bundle 路径（浏览器的 helper 进程之类）就不动。页标题摘要「酷狗音乐 · 正在播放」/「… · 已暂停」/「没有在播放的内容」。标题行的 ↻ 在这页是让助手重发一份（`get`）。

## 验证

```bash
swift test --filter 'NowPlayingTests|PreferencesTests|SwipeTests'
open -a Tally --args --open music && sleep 6 && screencapture -R256,0,1000,300 -x /tmp/tally-music.png
pgrep -fl 'perl.*libtallymedia'                      # 开着音乐时有且只有一个
pkill -x Tally; sleep 1; pgrep -fl 'perl.*libtallymedia'   # Tally 没了它也得没
```

用例：一行 JSON 解析成记录、`title` 为空是没有会话、`error` 行、坏行忽略；封面三种取舍（带了用新的、同 id 留旧的、换 id 没带就清）；分块到达的输出按行切（半行攒着、一块里多行、十几万字符的封面行）；页签出现规则（关着不出、常驻一直出、不常驻看有没有会话、起不来不出）；摘要文案；`visible(shelf:music:)` 的顺序；偏好默认值与落盘。

真机才验得了的：助手在 perl 里读到歌名与封面、`toggle` 两次状态来回变、关 stdin 即退出（手动跑过）；面板里三颗按钮要人点一下。
