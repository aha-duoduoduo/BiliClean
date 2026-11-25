#import "BLCDiag.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <pthread.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>

static NSString *const BLCDiagPrefix = @"[BLCDiag]";
static const uint16_t BLCDiagFirstPort = 8790;

#pragma mark - Events and value helpers

static NSMutableArray<NSString *> *BLCDiagEvents;
static NSLock *BLCDiagEventLock;

void BLCDiagEvent(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"HH:mm:ss.SSS";
        BLCDiagEvents = [NSMutableArray array];
        BLCDiagEventLock = [NSLock new];
    });
    [BLCDiagEventLock lock];
    NSString *line = [NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], message];
    [BLCDiagEvents addObject:line];
    if (BLCDiagEvents.count > 2000) [BLCDiagEvents removeObjectsInRange:NSMakeRange(0, 500)];
    [BLCDiagEventLock unlock];
    NSLog(@"%@ %@", BLCDiagPrefix, message);
}

NSArray<NSString *> *BLCDiagRecentEvents(NSUInteger limit) {
    [BLCDiagEventLock lock];
    NSArray *events = BLCDiagEvents ?: @[];
    NSUInteger start = events.count > limit ? events.count - limit : 0;
    NSArray *result = [events subarrayWithRange:NSMakeRange(start, events.count - start)];
    [BLCDiagEventLock unlock];
    return result;
}

id BLCDiagValue(id object, NSString *key) {
    if (!object) return nil;
    @try { return [object valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

NSString *BLCDiagShort(id value, NSUInteger maxLength) {
    if (!value) return @"nil";
    NSString *text = [value isKindOfClass:NSString.class] ? value : [value description];
    text = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    return text.length > maxLength ? [[text substringToIndex:maxLength] stringByAppendingString:@"…"] : text;
}

static NSString *BLCDiagIvarValue(id object, Ivar ivar) {
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type) return @"?";
    if (type[0] == '@') return BLCDiagShort(object_getIvar(object, ivar), 160);
    void *base = (__bridge void *)object;
    char *address = (char *)base + ivar_getOffset(ivar);
    switch (type[0]) {
        case 'B': return *(bool *)address ? @"YES" : @"NO";
        case 'c': return @(*(char *)address).stringValue;
        case 'i': return @(*(int *)address).stringValue;
        case 'I': return @(*(unsigned int *)address).stringValue;
        case 'q': case 'l': return @(*(long long *)address).stringValue;
        case 'Q': case 'L': return @(*(unsigned long long *)address).stringValue;
        case 'd': return @(*(double *)address).stringValue;
        case 'f': return @(*(float *)address).stringValue;
        default: return [NSString stringWithFormat:@"<%s>", type];
    }
}

NSDictionary<NSString *, NSString *> *BLCDiagIvars(id object) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (Class cls = object_getClass(object); cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = @(ivar_getName(ivars[i]) ?: "?");
            if (!result[name]) result[name] = BLCDiagIvarValue(object, ivars[i]);
        }
        free(ivars);
    }
    return result;
}

#pragma mark - Process state

typedef CFTypeRef (*BLCSecTaskCreateFromSelf)(CFAllocatorRef);
typedef CFTypeRef (*BLCSecTaskCopyValue)(CFTypeRef, CFStringRef, CFErrorRef *);
typedef CFStringRef (*BLCSecTaskCopySigningIdentifier)(CFTypeRef, CFErrorRef *);

static NSDictionary *BLCDiagSigning(void) {
    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
    BLCSecTaskCreateFromSelf create = security ? (BLCSecTaskCreateFromSelf)dlsym(security, "SecTaskCreateFromSelf") : NULL;
    BLCSecTaskCopyValue copyValue = security ? (BLCSecTaskCopyValue)dlsym(security, "SecTaskCopyValueForEntitlement") : NULL;
    BLCSecTaskCopySigningIdentifier copyIdentifier = security ? (BLCSecTaskCopySigningIdentifier)dlsym(security, "SecTaskCopySigningIdentifier") : NULL;
    if (!create || !copyValue) return @{@"error": @"SecTask unavailable"};
    CFTypeRef task = create(kCFAllocatorDefault);
    if (!task) return @{@"error": @"SecTaskCreateFromSelf failed"};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"application-identifier", @"com.apple.developer.team-identifier", @"get-task-allow",
                            @"aps-environment", @"com.apple.security.application-groups", @"keychain-access-groups"]) {
        CFTypeRef value = copyValue(task, (__bridge CFStringRef)key, NULL);
        result[key] = value ? BLCDiagShort(CFBridgingRelease(value), 200) : @"(none)";
    }
    if (copyIdentifier) {
        CFStringRef identifier = copyIdentifier(task, NULL);
        result[@"signing-identifier"] = identifier ? (NSString *)CFBridgingRelease(identifier) : @"(none)";
    }
    CFRelease(task);
    return result;
}

double BLCDiagProcessCPU(void) {
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return -1;
    double total = 0;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_basic_info_data_t info;
        mach_msg_type_number_t infoCount = THREAD_BASIC_INFO_COUNT;
        if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&info, &infoCount) == KERN_SUCCESS && !(info.flags & TH_FLAGS_IDLE)) {
            total += info.cpu_usage * 100.0 / TH_USAGE_SCALE;
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
    return total;
}

NSArray<NSDictionary *> *BLCDiagThreadUsage(void) {
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return @[];
    NSMutableArray *rows = [NSMutableArray array];
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_basic_info_data_t info;
        mach_msg_type_number_t infoCount = THREAD_BASIC_INFO_COUNT;
        if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&info, &infoCount) == KERN_SUCCESS && info.cpu_usage > 0) {
            char name[128] = {0};
            pthread_t pthread = pthread_from_mach_thread_np(threads[i]);
            if (pthread) pthread_getname_np(pthread, name, sizeof(name));
            [rows addObject:@{@"name": @(name[0] ? name : "?"), @"cpu": @(info.cpu_usage * 100.0 / TH_USAGE_SCALE)}];
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
    [rows sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"cpu" ascending:NO]]];
    return rows;
}

static NSString *BLCDiagRouteSummary(void) {
    NSMutableArray *outputs = [NSMutableArray array];
    for (AVAudioSessionPortDescription *port in AVAudioSession.sharedInstance.currentRoute.outputs) {
        [outputs addObject:[NSString stringWithFormat:@"%@(%@)", port.portType, port.portName]];
    }
    return [outputs componentsJoinedByString:@","];
}

NSDictionary *BLCDiagProcessState(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSArray *plugins = [NSFileManager.defaultManager contentsOfDirectoryAtPath:bundle.builtInPlugInsPath ?: @"" error:nil] ?: @[];
    AVAudioSession *session = AVAudioSession.sharedInstance;
    task_vm_info_data_t vm = {0};
    mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &vmCount);
    Class centerClass = NSClassFromString(@"MPNowPlayingInfoCenter");
    id center = centerClass ? ((id (*)(id, SEL))objc_msgSend)(centerClass, NSSelectorFromString(@"defaultCenter")) : nil;
    NSArray *threads = BLCDiagThreadUsage();
    NSDictionary *nowPlaying = BLCDiagValue(center, @"nowPlayingInfo");
    NSMutableDictionary *nowPlayingSummary = [NSMutableDictionary dictionary];
    for (NSString *key in nowPlaying) nowPlayingSummary[key] = BLCDiagShort(nowPlaying[key], 80);
    return @{
        @"bundleIdentifier": bundle.bundleIdentifier ?: @"",
        @"bundleVersion": [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"",
        @"supportsLiveActivities": [bundle objectForInfoDictionaryKey:@"NSSupportsLiveActivities"] ?: @NO,
        @"plugins": plugins,
        @"signing": BLCDiagSigning(),
        @"nowPlaying": @{@"info": nowPlayingSummary, @"playbackState": BLCDiagValue(center, @"playbackState") ?: @(-1)},
        @"audio": @{
            @"category": session.category ?: @"", @"mode": session.mode ?: @"", @"route": BLCDiagRouteSummary(),
            @"outputLatency": @(session.outputLatency), @"ioBufferDuration": @(session.IOBufferDuration),
            @"sampleRate": @(session.sampleRate), @"otherAudioPlaying": @(session.isOtherAudioPlaying)
        },
        @"thermalState": @(NSProcessInfo.processInfo.thermalState),
        @"lowPowerMode": @(NSProcessInfo.processInfo.isLowPowerModeEnabled),
        @"cpuPercent": @(BLCDiagProcessCPU()),
        @"footprintMB": @(vm.phys_footprint / 1048576),
        @"threads": [threads subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)15, threads.count))],
        @"download": BLCDiagDownloadSummary(),
    };
}

#pragma mark - HTTP server

static NSString *BLCDiagLocalIP(void) {
    struct ifaddrs *interfaces = NULL;
    NSString *address = @"127.0.0.1";
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *cursor = interfaces; cursor; cursor = cursor->ifa_next) {
            if (!cursor->ifa_addr || cursor->ifa_addr->sa_family != AF_INET || strcmp(cursor->ifa_name, "en0") != 0) continue;
            char buffer[INET_ADDRSTRLEN] = {0};
            if (inet_ntop(AF_INET, &((struct sockaddr_in *)cursor->ifa_addr)->sin_addr, buffer, sizeof(buffer))) {
                address = @(buffer);
                break;
            }
        }
        freeifaddrs(interfaces);
    }
    return address;
}

static uint16_t BLCDiagPort;

static NSString *BLCDiagURL(void) {
    return [NSString stringWithFormat:@"http://%@:%u", BLCDiagLocalIP(), BLCDiagPort];
}

static NSDictionary<NSString *, NSString *> *BLCDiagQuery(NSString *query) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        NSArray *parts = [pair componentsSeparatedByString:@"="];
        if (parts.count == 2) result[parts[0]] = [parts[1] stringByRemovingPercentEncoding] ?: parts[1];
    }
    return result;
}

static id BLCDiagRoute(NSString *path, NSDictionary<NSString *, NSString *> *query) {
    double seconds = query[@"sec"] ? query[@"sec"].doubleValue : 5;
    if ([path isEqualToString:@"/state"]) return BLCDiagProcessState();
    if ([path isEqualToString:@"/sample"]) return BLCDiagSample(seconds, query[@"hz"] ? query[@"hz"].doubleValue : 200);
    if ([path isEqualToString:@"/count"]) {
        NSArray *classes = query[@"classes"].length ? [query[@"classes"] componentsSeparatedByString:@","] : nil;
        return BLCDiagCount(seconds, classes);
    }
    if ([path isEqualToString:@"/download"]) return BLCDiagDownloadState();
    if ([path isEqualToString:@"/events"]) return BLCDiagRecentEvents(query[@"n"] ? (NSUInteger)query[@"n"].integerValue : 300);
    if ([path isEqualToString:@"/ivars"]) {
        Class cls = NSClassFromString(query[@"class"] ?: @"");
        NSString *accessor = query[@"accessor"] ?: @"shared";
        SEL selector = NSSelectorFromString(accessor);
        if (!cls || ![cls respondsToSelector:selector]) return @{@"error": @"class or accessor not found"};
        id instance = ((id (*)(id, SEL))objc_msgSend)(cls, selector);
        return BLCDiagIvars(instance);
    }
    return @{@"endpoints": @[@"/state", @"/sample?sec=8&hz=200", @"/count?sec=5[&classes=A,B]", @"/download", @"/events?n=300", @"/ivars?class=X&accessor=shared"]};
}

static void BLCDiagHandleClient(int client) {
    char buffer[4096] = {0};
    ssize_t size = recv(client, buffer, sizeof(buffer) - 1, 0);
    NSString *request = size > 0 ? [[NSString alloc] initWithBytes:buffer length:(NSUInteger)size encoding:NSUTF8StringEncoding] : nil;
    NSArray *line = [[request componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
    NSString *target = line.count >= 2 ? line[1] : @"/";
    NSRange mark = [target rangeOfString:@"?"];
    NSString *path = mark.location == NSNotFound ? target : [target substringToIndex:mark.location];
    NSString *query = mark.location == NSNotFound ? @"" : [target substringFromIndex:mark.location + 1];
    id payload = nil;
    @try {
        payload = BLCDiagRoute(path, BLCDiagQuery(query));
    } @catch (NSException *exception) {
        payload = @{@"exception": exception.reason ?: exception.name};
    }
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil]
        ?: [@"{\"error\":\"not serializable\"}" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", (unsigned long)body.length];
    NSMutableData *response = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [response appendData:body];
    const uint8_t *bytes = response.bytes;
    size_t sent = 0;
    while (sent < response.length) {
        ssize_t written = send(client, bytes + sent, response.length - sent, 0);
        if (written <= 0) break;
        sent += (size_t)written;
    }
    close(client);
}

static int BLCDiagBind(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    for (uint16_t port = BLCDiagFirstPort; port < BLCDiagFirstPort + 10; port++) {
        struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_ANY)};
        if (bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(fd, 8) == 0) {
            BLCDiagPort = port;
            return fd;
        }
    }
    close(fd);
    return -1;
}

static volatile int BLCDiagListenSocket = -1;

// iOS defuncts listening sockets while the app is suspended; accept() then fails
// forever. Rebind on failure and whenever the app returns to the foreground.
static void BLCDiagStartServer(void) {
    BLCDiagListenSocket = BLCDiagBind();
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
        int fd = BLCDiagListenSocket;
        if (fd >= 0) shutdown(fd, SHUT_RDWR);
    }];
    [NSThread detachNewThreadWithBlock:^{
        [NSThread currentThread].name = @"BLCDiag.accept";
        while (YES) {
            int fd = BLCDiagListenSocket;
            if (fd < 0) {
                sleep(1);
                BLCDiagListenSocket = BLCDiagBind();
                continue;
            }
            int client = accept(fd, NULL, NULL);
            if (client >= 0) {
                [NSThread detachNewThreadWithBlock:^{
                    [NSThread currentThread].name = @"BLCDiag.client";
                    BLCDiagHandleClient(client);
                }];
                continue;
            }
            if (errno == EINTR) continue;
            close(fd);
            BLCDiagListenSocket = -1;
            usleep(200000);
        }
    }];
}

static dispatch_source_t BLCDiagHeartbeat;

static void BLCDiagStartHeartbeat(void) {
    dispatch_queue_t queue = dispatch_queue_create("BLCDiag.heartbeat", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        NSLog(@"%@ hb %@ cpu=%.0f%% thermal=%ld route=%@ %@", BLCDiagPrefix, BLCDiagURL(), BLCDiagProcessCPU(),
              (long)NSProcessInfo.processInfo.thermalState, BLCDiagRouteSummary(), BLCDiagDownloadSummary());
    });
    dispatch_resume(timer);
    BLCDiagHeartbeat = timer;
}

__attribute__((constructor)) static void BLCDiagInit(void) {
    BLCDiagInstallDownloadHooks();
    BLCDiagStartServer();
    BLCDiagStartHeartbeat();
    BLCDiagEvent(@"diagnostics loaded %@ bundle=%@", BLCDiagURL(), NSBundle.mainBundle.bundleIdentifier);
}
