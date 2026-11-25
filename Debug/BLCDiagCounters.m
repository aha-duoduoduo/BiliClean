#import "BLCDiag.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>

// Per-method call counters for selected classes, using the trampolines in
// BLCDiagTrampolines.S. Installed lazily by /count and left in place.

#define BLC_DIAG_SLOTS 4096
#define BLC_DIAG_TRAMPOLINE_SIZE 64

typedef struct {
    IMP original;
    volatile uint64_t count;
} BLCDiagSlot;

extern BLCDiagSlot blc_diag_slots[BLC_DIAG_SLOTS];
extern char blc_diag_trampolines[];

static NSMutableArray<NSString *> *BLCDiagSlotNames;
static NSMutableSet<NSString *> *BLCDiagInstalledClasses;
static NSLock *BLCDiagCounterLock;

static BOOL BLCDiagSkipSelector(NSString *name) {
    static NSSet *skipped;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        skipped = [NSSet setWithArray:@[
            @"dealloc", @".cxx_destruct", @"retain", @"release", @"autorelease", @"retainCount", @"_tryRetain", @"_isDeallocating",
            @"allowsWeakReference", @"retainWeakReference", @"class", @"self", @"isKindOfClass:", @"isMemberOfClass:",
            @"respondsToSelector:", @"conformsToProtocol:", @"methodSignatureForSelector:", @"forwardInvocation:",
            @"forwardingTargetForSelector:", @"resolveInstanceMethod:", @"resolveClassMethod:", @"initialize", @"load",
            @"hash", @"isEqual:", @"description", @"debugDescription", @"zone", @"alloc", @"allocWithZone:", @"new",
            @"observationInfo", @"setObservationInfo:", @"automaticallyNotifiesObserversForKey:",
            @"keyPathsForValuesAffectingValueForKey:", @"willChangeValueForKey:", @"didChangeValueForKey:",
            @"addObserver:forKeyPath:options:context:", @"removeObserver:forKeyPath:", @"removeObserver:forKeyPath:context:",
            @"valueForKey:", @"setValue:forKey:", @"valueForUndefinedKey:", @"setValue:forUndefinedKey:"
        ]];
    });
    return [skipped containsObject:name];
}

static void BLCDiagInstallMethods(Class cls, NSString *className, BOOL meta) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count && BLCDiagSlotNames.count < BLC_DIAG_SLOTS; i++) {
        NSString *selector = NSStringFromSelector(method_getName(methods[i]));
        IMP imp = method_getImplementation(methods[i]);
        if (BLCDiagSkipSelector(selector) || imp == (IMP)_objc_msgForward) continue;
        NSUInteger index = BLCDiagSlotNames.count;
        blc_diag_slots[index].count = 0;
        blc_diag_slots[index].original = imp;
        __sync_synchronize();
        method_setImplementation(methods[i], (IMP)(blc_diag_trampolines + index * BLC_DIAG_TRAMPOLINE_SIZE));
        [BLCDiagSlotNames addObject:[NSString stringWithFormat:@"%c[%@ %@]", meta ? '+' : '-', className, selector]];
    }
    free(methods);
}

static NSArray<NSString *> *BLCDiagDefaultCountClasses(void) {
    return @[@"AVPlayer", @"AVQueuePlayer", @"AVPlayerItem", @"AVPlayerItemVideoOutput", @"AVPlayerItemOutput", @"AVPlayerLayer",
             @"AVSampleBufferDisplayLayer", @"AVSampleBufferAudioRenderer", @"AVSampleBufferRenderSynchronizer",
             @"AVAudioSession", @"AVAudioPlayer", @"AVRouteDetector", @"MPNowPlayingInfoCenter", @"MPRemoteCommandCenter",
             @"IJKSDLSampleBufferAudioRenderer", @"IJKSDLSampleBufferAdapter"];
}

NSDictionary *BLCDiagCount(double seconds, NSArray<NSString *> *classNames) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BLCDiagSlotNames = [NSMutableArray array];
        BLCDiagInstalledClasses = [NSMutableSet set];
        BLCDiagCounterLock = [NSLock new];
    });
    seconds = MAX(1, MIN(seconds, 60));
    NSMutableArray *missing = [NSMutableArray array];
    [BLCDiagCounterLock lock];
    for (NSString *className in classNames.count ? classNames : BLCDiagDefaultCountClasses()) {
        if ([BLCDiagInstalledClasses containsObject:className]) continue;
        Class cls = NSClassFromString(className);
        if (!cls) { [missing addObject:className]; continue; }
        BLCDiagInstallMethods(cls, className, NO);
        BLCDiagInstallMethods(object_getClass(cls), className, YES);
        [BLCDiagInstalledClasses addObject:className];
    }
    NSUInteger used = BLCDiagSlotNames.count;
    for (NSUInteger i = 0; i < used; i++) blc_diag_slots[i].count = 0;
    [BLCDiagCounterLock unlock];
    usleep((useconds_t)(seconds * 1000000));
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < used; i++) {
        uint64_t count = blc_diag_slots[i].count;
        if (count) [rows addObject:@{@"method": BLCDiagSlotNames[i], @"n": @(count), @"perSec": @(count / seconds)}];
    }
    [rows sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"n" ascending:NO]]];
    return @{@"seconds": @(seconds), @"hookedMethods": @(used), @"missingClasses": missing,
             @"calls": [rows subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)120, rows.count))]};
}
