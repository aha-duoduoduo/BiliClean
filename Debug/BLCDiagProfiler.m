#import "BLCDiag.h"
#import <objc/runtime.h>
#import <mach/mach.h>
#import <pthread.h>
#import <dlfcn.h>
#import <unistd.h>

// In-process sampler: suspends one running thread at a time, copies its PC/LR and
// frame-pointer chain into a preallocated buffer, resumes it, and symbolizes later.
// Nothing allocates while another thread is suspended.

#define BLC_MAX_FRAMES 48
#define BLC_MAX_SAMPLES 120000

typedef struct {
    uint64_t pcs[BLC_MAX_FRAMES];
    uint32_t count;
    uint32_t thread;
} BLCDiagStack;

static inline uint64_t BLCStrip(uint64_t value) { return value & 0x0000007FFFFFFFFFULL; }

static NSArray<NSDictionary *> *BLCObjCMethodTable(const char *imagePath) {
    NSMutableArray *rows = [NSMutableArray array];
    unsigned int classCount = 0;
    const char **names = objc_copyClassNamesForImage(imagePath, &classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        // Looking up a class realizes it; Swift classes may run metadata initializers
        // that are unsafe here (seen crashing in bili-universal), so only plain ObjC.
        if (strncmp(names[i], "_Tt", 3) == 0 || strchr(names[i], '.')) continue;
        Class cls = objc_getClass(names[i]);
        if (!cls) continue;
        for (int meta = 0; meta < 2; meta++) {
            Class target = meta ? object_getClass(cls) : cls;
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(target, &methodCount);
            for (unsigned int m = 0; m < methodCount; m++) {
                uint64_t imp = BLCStrip((uint64_t)method_getImplementation(methods[m]));
                NSString *name = [NSString stringWithFormat:@"%c[%s %s]", meta ? '+' : '-', names[i], sel_getName(method_getName(methods[m]))];
                [rows addObject:@[@(imp), name]];
            }
            free(methods);
        }
    }
    free(names);
    [rows sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    return rows;
}

static NSString *BLCSymbolize(uint64_t pc, NSMutableDictionary<NSString *, NSArray *> *tables) {
    Dl_info info = {0};
    if (!dladdr((void *)pc, &info) || !info.dli_fname) return [NSString stringWithFormat:@"?0x%llx", pc];
    NSString *image = @(info.dli_fname).lastPathComponent;
    uint64_t symbolAddress = (uint64_t)info.dli_saddr;
    NSString *symbol = info.dli_sname ? @(info.dli_sname) : nil;
    static NSSet *objcImages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // App images are symbolized offline from the static address instead.
        objcImages = [NSSet setWithArray:@[@"AVFCore", @"AVFoundation", @"MediaToolbox", @"MediaPlayer", @"MediaRemote",
                                           @"CoreMedia", @"AudioToolbox", @"VideoToolbox", @"AVKit"]];
    });
    if ([objcImages containsObject:image]) {
        NSArray *table = tables[image];
        if (!table) {
            table = BLCObjCMethodTable(info.dli_fname);
            tables[image] = table;
        }
        NSInteger lo = 0, hi = (NSInteger)table.count - 1, found = -1;
        while (lo <= hi) {
            NSInteger mid = (lo + hi) / 2;
            if ([table[mid][0] unsignedLongLongValue] <= pc) { found = mid; lo = mid + 1; } else { hi = mid - 1; }
        }
        if (found >= 0) {
            uint64_t imp = [table[found][0] unsignedLongLongValue];
            if (pc - imp < 0x4000 && (!symbol || imp > symbolAddress)) { symbol = table[found][1]; symbolAddress = imp; }
        }
    }
    if (symbol) return [NSString stringWithFormat:@"%@`%@+%llu", image, symbol, pc - symbolAddress];
    uint64_t staticAddress = pc - (uint64_t)info.dli_fbase + 0x100000000ULL;
    return [NSString stringWithFormat:@"%@@0x%llx", image, staticAddress];
}

static NSString *BLCThreadLabel(thread_t thread) {
    char name[128] = {0};
    pthread_t pthread = pthread_from_mach_thread_np(thread);
    if (pthread) pthread_getname_np(pthread, name, sizeof(name));
    if (name[0]) return @(name);
    thread_identifier_info_data_t identifier;
    mach_msg_type_number_t count = THREAD_IDENTIFIER_INFO_COUNT;
    if (thread_info(thread, THREAD_IDENTIFIER_INFO, (thread_info_t)&identifier, &count) == KERN_SUCCESS && identifier.dispatch_qaddr) {
        uint64_t queue = 0;
        vm_size_t read = 0;
        if (vm_read_overwrite(mach_task_self(), (vm_address_t)identifier.dispatch_qaddr, sizeof(queue), (vm_address_t)&queue, &read) == KERN_SUCCESS && queue) {
            __unsafe_unretained dispatch_queue_t target = (__bridge dispatch_queue_t)(void *)queue;
            const char *label = dispatch_queue_get_label(target);
            char copy[128] = {0};
            if (label && vm_read_overwrite(mach_task_self(), (vm_address_t)label, sizeof(copy) - 1, (vm_address_t)copy, &read) == KERN_SUCCESS) {
                return [NSString stringWithFormat:@"queue:%s", copy];
            }
        }
    }
    return [NSString stringWithFormat:@"thread-%u", thread];
}

NSDictionary *BLCDiagSample(double seconds, double hz) {
    seconds = MAX(1, MIN(seconds, 30));
    hz = MAX(10, MIN(hz, 500));
    BLCDiagStack *stacks = calloc(BLC_MAX_SAMPLES, sizeof(BLCDiagStack));
    if (!stacks) return @{@"error": @"allocation failed"};
    NSMutableDictionary<NSNumber *, NSString *> *threadLabels = [NSMutableDictionary dictionary];
    thread_t sampler = mach_thread_self();
    NSUInteger stackCount = 0, ticks = 0;
    CFAbsoluteTime end = CFAbsoluteTimeGetCurrent() + seconds;
    while (CFAbsoluteTimeGetCurrent() < end && stackCount < BLC_MAX_SAMPLES) {
        ticks++;
        thread_act_array_t threads = NULL;
        mach_msg_type_number_t threadCount = 0;
        if (task_threads(mach_task_self(), &threads, &threadCount) != KERN_SUCCESS) break;
        for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
            thread_t thread = threads[i];
            thread_basic_info_data_t info;
            mach_msg_type_number_t infoCount = THREAD_BASIC_INFO_COUNT;
            BOOL running = thread != sampler && stackCount < BLC_MAX_SAMPLES
                && thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&info, &infoCount) == KERN_SUCCESS
                && info.run_state == TH_STATE_RUNNING && !(info.flags & TH_FLAGS_IDLE);
            pthread_t pthread = running ? pthread_from_mach_thread_np(thread) : NULL;
            uint64_t stackHigh = pthread ? (uint64_t)pthread_get_stackaddr_np(pthread) : 0;
            uint64_t stackLow = pthread ? stackHigh - pthread_get_stacksize_np(pthread) : 0;
            if (running && thread_suspend(thread) == KERN_SUCCESS) {
                arm_thread_state64_t state;
                mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
                if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
                    BLCDiagStack *stack = &stacks[stackCount++];
                    stack->thread = thread;
                    stack->count = 0;
                    stack->pcs[stack->count++] = BLCStrip(arm_thread_state64_get_pc(state));
                    uint64_t lr = BLCStrip(arm_thread_state64_get_lr(state));
                    uint64_t fp = arm_thread_state64_get_fp(state);
                    if (stackHigh) {
                        BOOL first = YES;
                        while (fp && !(fp & 7) && fp >= stackLow && fp + 16 <= stackHigh && stack->count < BLC_MAX_FRAMES) {
                            uint64_t next = ((uint64_t *)fp)[0];
                            uint64_t ret = BLCStrip(((uint64_t *)fp)[1]);
                            if (first && ret != lr && lr) stack->pcs[stack->count++] = lr;
                            first = NO;
                            if (!ret || stack->count >= BLC_MAX_FRAMES) break;
                            stack->pcs[stack->count++] = ret;
                            if (next <= fp) break;
                            fp = next;
                        }
                    } else if (lr) {
                        stack->pcs[stack->count++] = lr;
                    }
                }
                thread_resume(thread);
            }
        }
        for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
            if (!threadLabels[@(threads[i])]) threadLabels[@(threads[i])] = BLCThreadLabel(threads[i]);
            mach_port_deallocate(mach_task_self(), threads[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threads, threadCount * sizeof(thread_t));
        usleep((useconds_t)(1000000.0 / hz));
    }
    mach_port_deallocate(mach_task_self(), sampler);

    NSMutableDictionary<NSString *, NSArray *> *tables = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSString *> *symbols = [NSMutableDictionary dictionary];
    NSCountedSet *selfCounts = [NSCountedSet set], *inclusive = [NSCountedSet set], *stackKeys = [NSCountedSet set], *threadCounts = [NSCountedSet set];
    for (NSUInteger s = 0; s < stackCount; s++) {
        BLCDiagStack *stack = &stacks[s];
        NSMutableArray *names = [NSMutableArray arrayWithCapacity:stack->count];
        for (uint32_t f = 0; f < stack->count; f++) {
            NSString *name = symbols[@(stack->pcs[f])];
            if (!name) symbols[@(stack->pcs[f])] = name = BLCSymbolize(stack->pcs[f], tables);
            [names addObject:name];
        }
        if (!names.count) continue;
        [selfCounts addObject:names.firstObject];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSString *name in names) {
            NSString *function = [name componentsSeparatedByString:@"+"].firstObject;
            if (![seen containsObject:function]) { [seen addObject:function]; [inclusive addObject:function]; }
        }
        [stackKeys addObject:[[names subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)18, names.count))] componentsJoinedByString:@"\n"]];
        [threadCounts addObject:threadLabels[@(stack->thread)] ?: @"?"];
    }
    free(stacks);
    NSArray *(^top)(NSCountedSet *, NSUInteger) = ^NSArray *(NSCountedSet *set, NSUInteger limit) {
        NSArray *sorted = [set.allObjects sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [@([set countForObject:b]) compare:@([set countForObject:a])];
        }];
        NSMutableArray *rows = [NSMutableArray array];
        for (id key in [sorted subarrayWithRange:NSMakeRange(0, MIN(limit, sorted.count))]) {
            [rows addObject:@{@"n": @([set countForObject:key]), @"perSec": @([set countForObject:key] / seconds), @"v": key}];
        }
        return rows;
    };
    return @{
        @"seconds": @(seconds), @"hz": @(hz), @"ticks": @(ticks), @"samples": @(stackCount),
        @"note": @"perSec of samples / hz = cores of CPU (approx)",
        @"threads": top(threadCounts, 30), @"self": top(selfCounts, 60), @"inclusive": top(inclusive, 80), @"stacks": top(stackKeys, 30),
    };
}
