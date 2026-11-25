#import "BLCDiag.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// Logs every scheduling decision of the offline download pipeline:
// BFCDownloadTaskManagerV2 picks tasks and adds BFCDownloadTaskCFNetworkOperation
// to BFCDownloadUrlConnectionQueue; BFCDownloadBackgroundSessionManager is the
// background NSURLSession path.

static id BLCDiagShared(NSString *className, NSString *accessor) {
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(accessor);
    return cls && [cls respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(cls, selector) : nil;
}

static NSString *BLCDiagTask(id task) {
    if (!task) return @"task=nil";
    return [NSString stringWithFormat:@"key=%@ state=%@ arrange=%@ command=%@", BLCDiagShort(BLCDiagValue(task, @"key"), 60),
            BLCDiagValue(task, @"state"), BLCDiagValue(task, @"taskArrangeType"), BLCDiagValue(task, @"command")];
}

static NSString *BLCDiagQueueSummary(void) {
    NSOperationQueue *queue = BLCDiagShared(@"BFCDownloadUrlConnectionQueue", @"shared");
    NSUInteger executing = 0;
    for (NSOperation *operation in queue.operations) if (operation.isExecuting) executing++;
    return [NSString stringWithFormat:@"queue ops=%lu executing=%lu max=%ld", (unsigned long)queue.operationCount,
            (unsigned long)executing, (long)queue.maxConcurrentOperationCount];
}

NSString *BLCDiagDownloadSummary(void) {
    NSDictionary *tasks = BLCDiagValue(BLCDiagShared(@"BFCDownloadTaskManagerV2", @"shared"), @"allTaskDict");
    NSCountedSet *states = [NSCountedSet set];
    for (id task in [tasks.allValues copy]) [states addObject:[NSString stringWithFormat:@"%@", BLCDiagValue(task, @"state")]];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *state in states) [parts addObject:[NSString stringWithFormat:@"%@x%lu", state, (unsigned long)[states countForObject:state]]];
    return [NSString stringWithFormat:@"dl[%@ tasks=%lu states=%@]", BLCDiagQueueSummary(), (unsigned long)tasks.count, [parts componentsJoinedByString:@","]];
}

#pragma mark - Hooks

static void (*BLCOrigExecuteByWeight)(id, SEL);
static void BLCExecuteByWeight(id self, SEL _cmd) {
    BLCDiagEvent(@"dl executeOperationByWeight begin %@", BLCDiagQueueSummary());
    BLCOrigExecuteByWeight(self, _cmd);
    BLCDiagEvent(@"dl executeOperationByWeight end %@", BLCDiagQueueSummary());
}

static void (*BLCOrigExecuteByKey)(id, SEL, id);
static void BLCExecuteByKey(id self, SEL _cmd, id key) {
    BLCDiagEvent(@"dl executeOperationByKey %@", BLCDiagShort(key, 60));
    BLCOrigExecuteByKey(self, _cmd, key);
}

static BOOL (*BLCOrigCanStart)(id, SEL, id);
static BOOL BLCCanStart(id self, SEL _cmd, id task) {
    BOOL result = BLCOrigCanStart(self, _cmd, task);
    BLCDiagEvent(@"dl %@ taskCanStartDownload %@ -> %d", NSStringFromClass(object_getClass(self)), BLCDiagTask(task), result);
    return result;
}

static BOOL (*BLCOrigBackgroundCanStart)(id, SEL, id);
static BOOL BLCBackgroundCanStart(id self, SEL _cmd, id task) {
    BOOL result = BLCOrigBackgroundCanStart(self, _cmd, task);
    BLCDiagEvent(@"dl background taskCanStartDownload %@ -> %d", BLCDiagTask(task), result);
    return result;
}

static BOOL (*BLCOrigSettingCould)(id, SEL, id);
static BOOL BLCSettingCould(id self, SEL _cmd, id key) {
    BOOL result = BLCOrigSettingCould(self, _cmd, key);
    BLCDiagEvent(@"dl settingCouldDownload %@ -> %d", BLCDiagShort(key, 60), result);
    return result;
}

static void (*BLCOrigStartTask)(id, SEL, id);
static void BLCStartTask(id self, SEL _cmd, id task) {
    BLCDiagEvent(@"dl startDownloadTask %@", BLCDiagTask(task));
    BLCOrigStartTask(self, _cmd, task);
}

static void (*BLCOrigPauseTask)(id, SEL, id, id);
static void BLCPauseTask(id self, SEL _cmd, id task, id message) {
    BLCDiagEvent(@"dl pauseDownloadTask %@ message=%@", BLCDiagTask(task), BLCDiagShort(message, 80));
    BLCOrigPauseTask(self, _cmd, task, message);
}

static void (*BLCOrigInterruptPause)(id, SEL, id);
static void BLCInterruptPause(id self, SEL _cmd, id task) {
    BLCDiagEvent(@"dl interruptPauseDownloadTask %@", BLCDiagTask(task));
    BLCOrigInterruptPause(self, _cmd, task);
}

static void (*BLCOrigManagerV2MaxQueue)(id, SEL, id);
static void BLCManagerV2MaxQueue(id self, SEL _cmd, id count) {
    BLCDiagEvent(@"dl TaskManagerV2 updateMaxQueueCount %@ (%@)", count, BLCDiagQueueSummary());
    BLCOrigManagerV2MaxQueue(self, _cmd, count);
}

static void (*BLCOrigManagerMaxQueue)(id, SEL, id);
static void BLCManagerMaxQueue(id self, SEL _cmd, id count) {
    BLCDiagEvent(@"dl +BFCDownloadManager updateMaxQueueCount %@", count);
    BLCOrigManagerMaxQueue(self, _cmd, count);
}

static void (*BLCOrigStartEntity)(id, SEL, id);
static void BLCStartEntity(id self, SEL _cmd, id entity) {
    BLCDiagEvent(@"dl startTaskWithEntity %@", BLCDiagShort(entity, 160));
    BLCOrigStartEntity(self, _cmd, entity);
}

static void (*BLCOrigAddOperationEntity)(id, SEL, id, unsigned long long);
static void BLCAddOperationEntity(id self, SEL _cmd, id entity, unsigned long long command) {
    BLCDiagEvent(@"dl addOperationWithEntity command=%llu %@", command, BLCDiagShort(entity, 120));
    BLCOrigAddOperationEntity(self, _cmd, entity, command);
}

static void (*BLCOrigSetMaxConcurrent)(id, SEL, NSInteger);
static void BLCSetMaxConcurrent(id self, SEL _cmd, NSInteger count) {
    NSInteger current = [(NSOperationQueue *)self maxConcurrentOperationCount];
    if (count != current) BLCDiagEvent(@"dl queue setMaxConcurrentOperationCount %ld -> %ld", (long)current, (long)count);
    BLCOrigSetMaxConcurrent(self, _cmd, count);
}

static void (*BLCOrigAddOperations)(id, SEL, NSArray *, BOOL);
static void BLCAddOperations(id self, SEL _cmd, NSArray *operations, BOOL wait) {
    BLCOrigAddOperations(self, _cmd, operations, wait);
    BLCDiagEvent(@"dl queue addOperations %lu -> %@", (unsigned long)operations.count, BLCDiagQueueSummary());
}

static void (*BLCOrigOperationStart)(id, SEL);
static void BLCOperationStart(id self, SEL _cmd) {
    BLCDiagEvent(@"dl operation start key=%@ jax=%@", BLCDiagShort(BLCDiagValue(self, @"key"), 60), BLCDiagValue(self, @"enableJaxDownloader"));
    BLCOrigOperationStart(self, _cmd);
}

static void (*BLCOrigOperationFinish)(id, SEL);
static void BLCOperationFinish(id self, SEL _cmd) {
    BLCDiagEvent(@"dl operation finish key=%@", BLCDiagShort(BLCDiagValue(self, @"key"), 60));
    BLCOrigOperationFinish(self, _cmd);
}

static void (*BLCOrigOperationPause)(id, SEL);
static void BLCOperationPause(id self, SEL _cmd) {
    BLCDiagEvent(@"dl operation pause key=%@", BLCDiagShort(BLCDiagValue(self, @"key"), 60));
    BLCOrigOperationPause(self, _cmd);
}

static BOOL (*BLCOrigStartUrlTask)(id, SEL, id, id, id);
static BOOL BLCStartUrlTask(id self, SEL _cmd, id task, id description, id ua) {
    BOOL result = BLCOrigStartUrlTask(self, _cmd, task, description, ua);
    BLCDiagEvent(@"dl background startUrlTask %@ -> %d", BLCDiagShort(description, 100), result);
    return result;
}

static void (*BLCOrigInfiniteAugust)(id, SEL);
static void BLCInfiniteAugust(id self, SEL _cmd) {
    BLCDiagEvent(@"dl background infiniteAugust (keep-alive start?)");
    BLCOrigInfiniteAugust(self, _cmd);
}

static void (*BLCOrigTukareta)(id, SEL);
static void BLCTukareta(id self, SEL _cmd) {
    BLCDiagEvent(@"dl background tukareta (keep-alive stop?)");
    BLCOrigTukareta(self, _cmd);
}

static void (*BLCOrigUpdateVipCount)(id, SEL, id);
static void BLCUpdateVipCount(id self, SEL _cmd, id count) {
    BLCDiagEvent(@"dl VIPManager updateVipDownloadCount %@", count);
    BLCOrigUpdateVipCount(self, _cmd, count);
}

static void BLCDiagHook(NSString *className, BOOL meta, NSString *selector, IMP replacement, IMP *original) {
    Class cls = NSClassFromString(className);
    if (meta) cls = object_getClass(cls);
    SEL sel = NSSelectorFromString(selector);
    if (!cls || !class_getInstanceMethod(cls, sel)) {
        BLCDiagEvent(@"hook missing %c[%@ %@]", meta ? '+' : '-', className, selector);
        return;
    }
    MSHookMessageEx(cls, sel, replacement, original);
}

void BLCDiagInstallDownloadHooks(void) {
    NSString *v2 = @"BFCDownloadTaskManagerV2", *bg = @"BFCDownloadBackgroundSessionManager", *op = @"BFCDownloadTaskCFNetworkOperation";
    BLCDiagHook(v2, NO, @"executeOperationByWeight", (IMP)BLCExecuteByWeight, (IMP *)&BLCOrigExecuteByWeight);
    BLCDiagHook(v2, NO, @"executeOperationByKey:", (IMP)BLCExecuteByKey, (IMP *)&BLCOrigExecuteByKey);
    BLCDiagHook(v2, NO, @"taskCanStartDownload:", (IMP)BLCCanStart, (IMP *)&BLCOrigCanStart);
    BLCDiagHook(v2, NO, @"settingCouldDownload:", (IMP)BLCSettingCould, (IMP *)&BLCOrigSettingCould);
    BLCDiagHook(v2, NO, @"startDownloadTask:", (IMP)BLCStartTask, (IMP *)&BLCOrigStartTask);
    BLCDiagHook(v2, NO, @"pauseDownloadTask:errorMessage:", (IMP)BLCPauseTask, (IMP *)&BLCOrigPauseTask);
    BLCDiagHook(v2, NO, @"interruptPauseDownloadTask:", (IMP)BLCInterruptPause, (IMP *)&BLCOrigInterruptPause);
    BLCDiagHook(v2, NO, @"updateMaxQueueCount:", (IMP)BLCManagerV2MaxQueue, (IMP *)&BLCOrigManagerV2MaxQueue);
    BLCDiagHook(@"BFCDownloadManager", YES, @"updateMaxQueueCount:", (IMP)BLCManagerMaxQueue, (IMP *)&BLCOrigManagerMaxQueue);
    BLCDiagHook(@"BFCDownloadManager", NO, @"startTaskWithEntity:", (IMP)BLCStartEntity, (IMP *)&BLCOrigStartEntity);
    BLCDiagHook(@"BFCDownloadManager", NO, @"addOperationWithEntity:command:", (IMP)BLCAddOperationEntity, (IMP *)&BLCOrigAddOperationEntity);
    BLCDiagHook(@"BFCDownloadUrlConnectionQueue", NO, @"setMaxConcurrentOperationCount:", (IMP)BLCSetMaxConcurrent, (IMP *)&BLCOrigSetMaxConcurrent);
    BLCDiagHook(@"BFCDownloadUrlConnectionQueue", NO, @"addOperations:waitUntilFinished:", (IMP)BLCAddOperations, (IMP *)&BLCOrigAddOperations);
    BLCDiagHook(op, NO, @"start", (IMP)BLCOperationStart, (IMP *)&BLCOrigOperationStart);
    BLCDiagHook(op, NO, @"finish", (IMP)BLCOperationFinish, (IMP *)&BLCOrigOperationFinish);
    BLCDiagHook(op, NO, @"pause", (IMP)BLCOperationPause, (IMP *)&BLCOrigOperationPause);
    BLCDiagHook(bg, NO, @"taskCanStartDownload:", (IMP)BLCBackgroundCanStart, (IMP *)&BLCOrigBackgroundCanStart);
    BLCDiagHook(bg, NO, @"startUrlTask:taskDescription:ua:", (IMP)BLCStartUrlTask, (IMP *)&BLCOrigStartUrlTask);
    BLCDiagHook(bg, NO, @"infiniteAugust", (IMP)BLCInfiniteAugust, (IMP *)&BLCOrigInfiniteAugust);
    BLCDiagHook(bg, NO, @"tukareta", (IMP)BLCTukareta, (IMP *)&BLCOrigTukareta);
    BLCDiagHook(@"BBPhoneDownloadVIPManager", NO, @"updateVipDownloadCount:", (IMP)BLCUpdateVipCount, (IMP *)&BLCOrigUpdateVipCount);
}

#pragma mark - Snapshot

NSDictionary *BLCDiagDownloadState(void) {
    NSOperationQueue *queue = BLCDiagShared(@"BFCDownloadUrlConnectionQueue", @"shared");
    NSMutableArray *operations = [NSMutableArray array];
    for (NSOperation *operation in queue.operations) {
        [operations addObject:@{@"class": NSStringFromClass(operation.class), @"key": BLCDiagShort(BLCDiagValue(operation, @"key"), 80),
                                @"state": BLCDiagValue(operation, @"state") ?: @"?", @"executing": @(operation.isExecuting),
                                @"ready": @(operation.isReady), @"finished": @(operation.isFinished)}];
    }
    id manager = BLCDiagShared(@"BFCDownloadTaskManagerV2", @"shared");
    NSDictionary *allTasks = [BLCDiagValue(manager, @"allTaskDict") copy];
    NSMutableArray *tasks = [NSMutableArray array];
    for (id key in allTasks) [tasks addObject:BLCDiagTask(allTasks[key])];
    id firstTask = allTasks.allValues.firstObject;
    id background = BLCDiagShared(@"BFCDownloadBackgroundSessionManager", @"shared");
    NSURLSession *session = BLCDiagValue(background, @"session");
    id keepAlive = BLCDiagValue(background, @"haruhi");
    id vip = BLCDiagShared(@"BBPhoneDownloadVIPManager", @"sharedInstance");
    Ivar vipCount = vip ? class_getInstanceVariable(object_getClass(vip), "_downloadCount") : NULL;
    Class managerClass = NSClassFromString(@"BFCDownloadManager");
    BOOL downloading = managerClass && [managerClass respondsToSelector:NSSelectorFromString(@"isDownloading")]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(managerClass, NSSelectorFromString(@"isDownloading")) : NO;
    return @{
        @"queue": @{@"max": @(queue.maxConcurrentOperationCount), @"count": @(queue.operationCount), @"suspended": @(queue.isSuspended),
                    @"operations": operations},
        @"tasks": tasks,
        @"firstTaskIvars": firstTask ? BLCDiagIvars(firstTask) : @{},
        @"background": @{
            @"allTaskList": @([BLCDiagValue(background, @"allTaskList") count]),
            @"deathNote": @([BLCDiagValue(background, @"deathNote") count]),
            @"maxConnectionsPerHost": @(session.configuration.HTTPMaximumConnectionsPerHost),
            @"sessionIdentifier": session.configuration.identifier ?: @"",
            @"keepAlivePlayer": keepAlive ? @{@"playing": BLCDiagValue(keepAlive, @"playing") ?: @"?", @"volume": BLCDiagValue(keepAlive, @"volume") ?: @"?",
                                              @"url": BLCDiagShort(BLCDiagValue(keepAlive, @"url"), 120)} : @"nil",
        },
        @"vip": @{@"downloadCountGetter": BLCDiagShort(BLCDiagValue(vip, @"downloadCount"), 40),
                  @"downloadCountIvar": vipCount ? BLCDiagShort(object_getIvar(vip, vipCount), 40) : @"?"},
        @"isDownloading": @(downloading),
        @"recentEvents": [[BLCDiagRecentEvents(400) filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF CONTAINS ' dl '"]]
                          valueForKey:@"self"],
    };
}
