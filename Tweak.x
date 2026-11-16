// ZaloWatchAlert
//
// Zalo reports incoming calls only through CallKit (-[CXProvider
// reportNewIncomingCallWithUUID:update:completion:]). watchOS does not relay a
// third-party CallKit call to the Apple Watch, so the Watch has nothing to show.
// This tweak posts a regular local notification while the call is ringing
// (repeated every few seconds). Notification mirroring then alerts the Watch.
// See RESEARCH.md.

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <CallKit/CallKit.h>
#import <notify.h>

// ---------------------------------------------------------------------------
// Debug code lives only in this block, behind the single flag ZWA_DEBUG. The
// Makefile defines it only for `build.sh debug` (ZALOWATCHALERT_DEBUG=1), so a
// normal build contains no logging and no log file.
// ---------------------------------------------------------------------------
#ifdef ZWA_DEBUG
// oslog is unreadable over SSH on the roothide iPhone, so also append to a file
// in the Zalo container's tmp (read it via /rootfs/.../Data/Application/<id>/tmp).
static void ZWALogImpl(NSString *message) {
    NSLog(@"[ZaloWatchAlert] %@", message);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ZaloWatchAlert.log"];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}
#define ZWALog(fmt, ...) ZWALogImpl([NSString stringWithFormat:fmt, ##__VA_ARGS__])

static void ZWALogNotificationSettings(UNUserNotificationCenter *center, NSInteger tick) {
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        ZWALog(@"tick %ld auth=%ld alert=%ld sound=%ld level=%ld", (long)tick,
               (long)settings.authorizationStatus, (long)settings.alertSetting,
               (long)settings.soundSetting, (long)settings.timeSensitiveSetting);
    }];
}
#else
#define ZWALog(...) do {} while (0)
#define ZWALogNotificationSettings(center, tick) do {} while (0)
#endif

// Is the device locked (or screen blanked) right now? Notifications are only useful
// then: the Watch only mirrors while the iPhone is locked, and when the user is using
// the iPhone the CallKit banner is enough. Three independent signals, any one of them
// saying "locked" counts as locked:
//   - notify key com.apple.springboard.lockstate (SpringBoard, readable from apps)
//   - notify key com.apple.springboard.hasBlankedScreen
//   - -[UIApplication protectedDataAvailable] (false while locked with a passcode)
static BOOL ZWADeviceLocked(void) {
    static int lockToken, blankToken;
    static BOOL haveLock, haveBlank;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        haveLock = notify_register_check("com.apple.springboard.lockstate", &lockToken) == NOTIFY_STATUS_OK;
        haveBlank = notify_register_check("com.apple.springboard.hasBlankedScreen", &blankToken) == NOTIFY_STATUS_OK;
    });
    uint64_t lockState = 0, blanked = 0;
    if (haveLock) notify_get_state(lockToken, &lockState);
    if (haveBlank) notify_get_state(blankToken, &blanked);
    BOOL protectedAvailable = [UIApplication sharedApplication].protectedDataAvailable;
    BOOL locked = lockState != 0 || blanked != 0 || !protectedAvailable;
    ZWALog(@"lock check: lockstate=%llu(%d) blanked=%llu(%d) protectedData=%d -> locked=%d",
           lockState, haveLock, blanked, haveBlank, protectedAvailable, locked);
    return locked;
}

static NSString *const kZWAIdentifierPrefix = @"com.qn.zalowatchalert.";
// Zalo's own CallKit ring timer is 45 s ("CALLKIT started 45s" in call.txt).
static const NSTimeInterval kZWARepeatInterval = 2.0;
static const NSInteger kZWAMaxTicks = 22;   // 22 x 2 s = 44 s, keeps the ~45 s ring window

@interface ZWAController : NSObject <CXCallObserverDelegate>
+ (instancetype)shared;
- (void)callStartedWithUUID:(NSUUID *)uuid update:(CXCallUpdate *)update;
- (void)stopForUUID:(NSUUID *)uuid;
// Returns YES if this UUID was already reported (Zalo reports the same call twice).
- (BOOL)markReportedUUID:(NSUUID *)uuid;
@end

@implementation ZWAController {
    NSMutableDictionary<NSUUID *, NSTimer *> *_timers;
    NSMutableDictionary<NSUUID *, NSNumber *> *_ticks;
    CXCallObserver *_observer;
    NSMutableSet<NSUUID *> *_reported;
}

+ (instancetype)shared {
    static ZWAController *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[ZWAController alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _timers = [NSMutableDictionary dictionary];
        _ticks = [NSMutableDictionary dictionary];
        _reported = [NSMutableSet set];
    }
    return self;
}

- (BOOL)markReportedUUID:(NSUUID *)uuid {
    @synchronized (self) {
        if ([_reported containsObject:uuid]) return YES;
        [_reported addObject:uuid];
        return NO;
    }
}

- (NSString *)identifierForUUID:(NSUUID *)uuid tick:(NSInteger)tick {
    return [NSString stringWithFormat:@"%@%@.%ld", kZWAIdentifierPrefix, uuid.UUIDString, (long)tick];
}

- (void)callStartedWithUUID:(NSUUID *)uuid update:(CXCallUpdate *)update {
    if (!uuid) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        // iPhone in use: CallKit banner is already visible and the Watch does
        // not mirror anything while the iPhone is unlocked.
        UIApplicationState state = [UIApplication sharedApplication].applicationState;
        ZWALog(@"callStarted uuid=%@ appState=%ld", uuid, (long)state);
        if (state == UIApplicationStateActive) {
            ZWALog(@"app active, skip notification for %@", uuid);
            return;
        }
        if (!ZWADeviceLocked()) {
            ZWALog(@"device unlocked, skip notification for %@", uuid);
            return;
        }
        if (self->_timers[uuid]) return;

        if (!self->_observer) {
            self->_observer = [[CXCallObserver alloc] init];
            [self->_observer setDelegate:self queue:dispatch_get_main_queue()];
        }

        NSString *caller = update.localizedCallerName;
        if (caller.length == 0) caller = update.remoteHandle.value;
        if (caller.length == 0) caller = @"Zalo";
        NSString *body = update.hasVideo ? @"Cuộc gọi video Zalo đến" : @"Cuộc gọi Zalo đến";

        ZWALog(@"call %@ from %@ video=%d", uuid, caller, update.hasVideo);

        self->_ticks[uuid] = @0;
        [self postNotificationForUUID:uuid caller:caller body:body];

        __weak ZWAController *weakSelf = self;
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:kZWARepeatInterval repeats:YES block:^(NSTimer *t) {
            ZWAController *strongSelf = weakSelf;
            if (!strongSelf) { [t invalidate]; return; }
            // User picked up and unlocked the iPhone while it was ringing: stop alerting
            // and clear what was already delivered (also clears it on the Watch).
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive || !ZWADeviceLocked()) {
                ZWALog(@"device unlocked while ringing, stopping %@", uuid);
                [strongSelf stopForUUID:uuid];
                return;
            }
            NSInteger tick = [strongSelf->_ticks[uuid] integerValue] + 1;
            if (tick >= kZWAMaxTicks) { [strongSelf stopForUUID:uuid]; return; }
            strongSelf->_ticks[uuid] = @(tick);
            [strongSelf postNotificationForUUID:uuid caller:caller body:body];
        }];
        self->_timers[uuid] = timer;
    });
}

- (void)postNotificationForUUID:(NSUUID *)uuid caller:(NSString *)caller body:(NSString *)body {
    NSInteger tick = [_ticks[uuid] integerValue];
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = caller;
    content.body = body;
    // No threadIdentifier and no removal between ticks: grouped/replaced notifications
    // made the Watch haptics irregular, so every tick is an independent notification.
    // Everything is cleared in stopForUUID:.
    // A silent notification gave no haptic on the Watch, so use the default sound.
    // iOS does not play it over the CallKit ringtone while the call is ringing.
    content.sound = [UNNotificationSound defaultSound];
    content.interruptionLevel = UNNotificationInterruptionLevelTimeSensitive;

    NSString *identifier = [self identifierForUUID:uuid tick:tick];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    ZWALogNotificationSettings(center, tick);
    [center addNotificationRequest:request withCompletionHandler:^(NSError *error) {
        ZWALog(@"add notification %@ -> %@", identifier, error ? error : @"ok");
    }];
}

- (void)stopForUUID:(NSUUID *)uuid {
    if (!uuid) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) { [self->_reported removeObject:uuid]; }
        NSTimer *timer = self->_timers[uuid];
        if (!timer && !self->_ticks[uuid]) return;
        [timer invalidate];
        [self->_timers removeObjectForKey:uuid];
        NSInteger last = [self->_ticks[uuid] integerValue];
        [self->_ticks removeObjectForKey:uuid];

        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        for (NSInteger i = 0; i <= last; i++) {
            [ids addObject:[self identifierForUUID:uuid tick:i]];
        }
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center removePendingNotificationRequestsWithIdentifiers:ids];
        [center removeDeliveredNotificationsWithIdentifiers:ids];
        ZWALog(@"stopped %@", uuid);
    });
}

#pragma mark - CXCallObserverDelegate

- (void)callObserver:(CXCallObserver *)callObserver callChanged:(CXCall *)call {
    // Answered (on iPhone) or ended: stop alerting.
    ZWALog(@"callChanged uuid=%@ connected=%d ended=%d", call.UUID, call.hasConnected, call.hasEnded);
    if (call.hasConnected || call.hasEnded) {
        [self stopForUUID:call.UUID];
    }
}

@end

%hook CXProvider

- (void)reportNewIncomingCallWithUUID:(NSUUID *)uuid update:(CXCallUpdate *)update completion:(void (^)(NSError *error))completion {
    ZWALog(@"hook reportNewIncomingCall uuid=%@ name=%@ handle=%@ video=%d", uuid,
           update.localizedCallerName, update.remoteHandle.value, update.hasVideo);
    // Zalo reports the same UUID twice (the second one only refreshes the info and
    // CallKit answers it with an error). The duplicate must not stop the alert.
    if (uuid && [[ZWAController shared] markReportedUUID:uuid]) {
        ZWALog(@"duplicate report for %@, passing through", uuid);
        %orig;
        return;
    }
    void (^wrapped)(NSError *) = ^(NSError *error) {
        ZWALog(@"report completion uuid=%@ error=%@", uuid, error);
        if (error) [[ZWAController shared] stopForUUID:uuid];
        if (completion) completion(error);
    };
    %orig(uuid, update, wrapped);
    [[ZWAController shared] callStartedWithUUID:uuid update:update];
}

- (void)reportCallWithUUID:(NSUUID *)uuid endedAtDate:(NSDate *)endDate reason:(CXCallEndedReason)endedReason {
    ZWALog(@"hook reportCallEnded uuid=%@ reason=%ld", uuid, (long)endedReason);
    %orig;
    [[ZWAController shared] stopForUUID:uuid];
}

%end
