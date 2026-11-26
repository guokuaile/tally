# 壁纸实现状态

任务 3、4 已实现、构建、测试并安装。新 `com.aiden.tally.wallpaper` 正在运行；旧 `com.aiden.video-wallpaper` 已禁用并卸载，原 plist、源码、二进制和素材保留，可从设置恢复。

## 文件与接口

- `TallyWallpaperKit`：`WallpaperConfiguration`、`WallpaperPaths`、`WallpaperPlaylist`、`WallpaperStatus`、`WallpaperCommand`、`WallpaperClient.send`、`WallpaperControlServer`。
- `TallyWallpaper`：默认启动壁纸播放器；`tally-wallpaper --command status|pause|resume|next|reload` 向本机播放器发受限控制命令，健康时输出一行 JSON 状态并退出 0，未就绪或错误返回非零。安装位置为 `/Applications/Tally.app/Contents/Library/LoginItems/TallyWallpaper.app/Contents/MacOS/tally-wallpaper`，独立 bundle ID 为 `com.aiden.tally.wallpaper`，避免 macOS 把它认成主 App。
- `Tally`：`WallpaperService.shared` 提供 `refresh/start/stop/pause/resume/next/save/reload`；视图是 `WallpaperSettings` 和 `WallpaperCard`。
- 运行任务 plist 固定在 `~/Library/Application Support/Tally/Wallpaper/player-agent.plist`；勾选登录自启时另存 `~/Library/LaunchAgents/com.aiden.tally.wallpaper.plist`。暂停意图在 `playback-state.json`，旧入口接管记录在 `migration.json`。

## 已验证与边界

- `swift test` 全部 782 项通过，其中 WallpaperKit 8 项、WallpaperService 10 项；安装隔离测试 7 项通过。发布构建、嵌套 App 签名核验和实际安装通过。
- 真实设置页完成开始、暂停、继续、下一张、恢复旧入口和再次接管。正常播放视频的两帧像素不同，暂停后相同；退出 Tally 后播放器 pid 不变且视频继续变化，重新打开 Tally 可正常进入主界面。
- 暂停时更新 App 后，播放器 pid 更换且暂停状态保留。最终配置恢复为静态/动态两个原素材目录，共 23 项，间隔 300 秒，登录后播放开启，当前继续播放。系统页「下一张」也已读回新素材。
- 未执行整机重启、休眠唤醒和长时间播放压力验收；就绪之后的解码中断不在已验证范围。证据路径与安装边界见 [桌面控制状态](desktop-controls-status.md)。
