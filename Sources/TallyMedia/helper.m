// Tally 的「正在播放」助手：编成 dylib，由 /usr/bin/perl 加载后运行，不链进 app（docs/music.md）。
//
// macOS 15.4 起 mediaremoted 只回答它信任的客户端，Tally 这种自签进程问到的永远是空字典；
// /usr/bin/perl 是平台二进制、签名不带库校验，能加载这份 dylib，在它的进程里问就拿得到完整记录。
// 做法参考 cyclop（MIT）与 mediaremote-adapter（BSD-3），见 NOTICE。
//
// 约定：stdout 一行一个 JSON；stdin 一行一条命令（toggle / next / prev / get）；
// stdin 一关就退出，Tally 被杀掉也不会留下孤儿 perl。

#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);

static MRGetInfoFn sGetInfo;
static MRGetBoolFn sGetIsPlaying;
static MRGetPIDFn sGetPID;
static MRSendCommandFn sSendCommand;
// 下面几个只在 sQueue 上读写
static dispatch_queue_t sQueue;
static int sOwnerPID;
static NSString *sLastState;
static NSString *sLastArtworkId;

// MRMediaRemoteCommand 里用到的三个
static const int kCommandTogglePlayPause = 2;
static const int kCommandNextTrack = 4;
static const int kCommandPreviousTrack = 5;

/// 这些值是别的 app 经 MediaRemote 报上来的，类型不归我们管：不是字符串就当没有。
/// 放进去一个 NSDate / NSData，NSJSONSerialization 是抛异常不是返回 nil，perl 会跟着崩、被 Tally 重起、再崩。
static NSString *text(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static void emit(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/// 读一次当前记录，和上一次发出去的不一样才发。
/// 每 2 秒轮询一次，不去重的话 Tally 那头每 2 秒白解析一行、界面白刷一遍。
/// 不给进度（elapsed / duration）：那是播放器自己报的，酷狗暂停、继续之后一直报旧值，照着画的进度条是错的。
/// 封面是一行里的大头，只在换了的时候带；artworkId 每次都带，Tally 靠它判断手里那张还算不算数。
static void publish(void) {
    if (!sGetInfo || !sGetIsPlaying) return;
    // pid 只用来认是哪个播放器，晚一轮无妨；不嵌进下面的回调里，少一层等待
    if (sGetPID) sGetPID(sQueue, ^(int pid) { sOwnerPID = pid; });
    sGetIsPlaying(sQueue, ^(Boolean playing) {
        sGetInfo(sQueue, ^(CFDictionaryRef raw) {
            NSDictionary *info = (__bridge NSDictionary *)raw;
            NSString *title = text(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
            NSString *album = text(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
            NSString *artworkId = text(info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]);
            if (artworkId.length == 0) artworkId = [NSString stringWithFormat:@"%@\n%@", title, album];

            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            out[@"playing"] = playing ? @YES : @NO;
            out[@"title"] = title;
            out[@"artist"] = text(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
            out[@"album"] = album;
            out[@"pid"] = @(sOwnerPID);
            out[@"artworkId"] = artworkId;

            NSData *state = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:NULL];
            NSString *stateText = state ? [[NSString alloc] initWithData:state encoding:NSUTF8StringEncoding] : nil;
            NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if (![artwork isKindOfClass:NSData.class]) artwork = nil;
            BOOL newArtwork = artwork.length > 0 && ![artworkId isEqualToString:sLastArtworkId];
            if (!newArtwork && [stateText isEqualToString:sLastState]) return;

            if (newArtwork) {
                out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                sLastArtworkId = artworkId;
            }
            sLastState = stateText;
            emit(out);
        });
    });
}

static void send(int command) {
    if (sSendCommand) sSendCommand(command, NULL);
    // 通知在 macOS 26 上时有时无，不等 2 秒一次的轮询：按钮按下去界面得马上跟上
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), sQueue, ^{ publish(); });
}

static void handleCommand(NSString *line) {
    if ([line isEqualToString:@"toggle"]) {
        send(kCommandTogglePlayPause);
    } else if ([line isEqualToString:@"next"]) {
        send(kCommandNextTrack);
    } else if ([line isEqualToString:@"prev"]) {
        send(kCommandPreviousTrack);
    } else if ([line isEqualToString:@"get"]) {
        // Tally 要一份完整的（含封面）：忘掉发过什么
        dispatch_async(sQueue, ^{
            sLastState = nil;
            sLastArtworkId = nil;
            publish();
        });
    }
}

static void startFeed(void) {
    [NSThread detachNewThreadWithBlock:^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!handle) {
            emit(@{@"error": @"mediaremote-unavailable"});
            return;
        }
        sGetInfo = (MRGetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        sGetIsPlaying = (MRGetBoolFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        sGetPID = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        sSendCommand = (MRSendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
        if (!sGetInfo || !sGetIsPlaying) {
            emit(@{@"error": @"mediaremote-symbols-missing"});
            return;
        }

        MRRegisterFn registerNotifications = (MRRegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (registerNotifications) registerNotifications(sQueue);
        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ];
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                publish();
            }];
        }
        // 通知之外再轮询：cyclop 在 macOS 26 上测到过整段 30 秒一条通知都不来、期间真的换过歌
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) { publish(); }];

        publish();
        [NSRunLoop.currentRunLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
        [NSRunLoop.currentRunLoop run];
    }];
}

static void startCommandReader(void) {
    [NSThread detachNewThreadWithBlock:^{
        char buffer[64];
        while (fgets(buffer, sizeof buffer, stdin)) {
            @autoreleasepool {
                NSString *line = [@(buffer) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (line.length) handleCommand(line);
            }
        }
        // Tally 关了管道，或者整个进程没了
        exit(0);
    }];
}

// 加载即启动，马上返回：dlopen 期间持着 dyld 的锁，在这里阻塞的话上面线程里的 dlopen 永远等不到
__attribute__((constructor))
static void tally_media_init(void) {
    sQueue = dispatch_queue_create("com.aiden.tally.media", DISPATCH_QUEUE_SERIAL);
    startFeed();
    startCommandReader();
}
