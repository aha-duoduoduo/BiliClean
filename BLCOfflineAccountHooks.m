#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static const char *BLCAccSvcClass =
    "_TtC13AccountModuleP33_D63281C28B8514DC353ECE59E1D8DB9217AccountServiceImp";

static NSString *const BLCUnlimitedEnabledKey = @"blc.offline.unlimited.enabled";
static NSString *const BLCUnlimitedCountKey = @"blc.offline.unlimited.count";

static BOOL BLCUnlimitedEnabled(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:BLCUnlimitedEnabledKey];
    return value ? [value boolValue] : YES;
}

static NSInteger BLCUnlimitedCount(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:BLCUnlimitedCountKey];
    NSInteger count = value ? [value integerValue] : 3;
    return MAX(1, MIN(count, 99));
}

static IMP blcOrigIsVip;
static IMP blcOrigVipStatus;
static IMP blcOrigVipType;
static IMP blcOrigIsSVip;
static IMP blcOrigVipDueDate;

static BOOL blcOfflineIsVip(id self, SEL _cmd) {
    if (!BLCUnlimitedEnabled() && blcOrigIsVip) return ((BOOL (*)(id, SEL))blcOrigIsVip)(self, _cmd);
    return YES;
}
static long long blcOfflineVipStatus(id self, SEL _cmd) {
    if (!BLCUnlimitedEnabled() && blcOrigVipStatus) return ((long long (*)(id, SEL))blcOrigVipStatus)(self, _cmd);
    return 1;
}
static long long blcOfflineVipType(id self, SEL _cmd) {
    if (!BLCUnlimitedEnabled() && blcOrigVipType) return ((long long (*)(id, SEL))blcOrigVipType)(self, _cmd);
    return 2;
}
static BOOL blcOfflineIsSVip(id self, SEL _cmd) {
    if (!BLCUnlimitedEnabled() && blcOrigIsSVip) return ((BOOL (*)(id, SEL))blcOrigIsSVip)(self, _cmd);
    return NO;
}
static long long blcOfflineVipDueDate(id self, SEL _cmd) {
    if (!BLCUnlimitedEnabled() && blcOrigVipDueDate) return ((long long (*)(id, SEL))blcOrigVipDueDate)(self, _cmd);
    return 4102444800000LL;
}

static void BLCReplace(Class cls, SEL sel, IMP newImp, IMP *orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        NSLog(@"[BLC-Offline] selector %@ missing on %@", NSStringFromSelector(sel), NSStringFromClass(cls));
        return;
    }
    *orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    NSLog(@"[BLC-Offline] hooked %@ on %@", NSStringFromSelector(sel), NSStringFromClass(cls));
}

__attribute__((constructor)) static void BLCInstallOfflineAccountHooks(void) {
    if (!BLCUnlimitedEnabled()) return;
    NSUserDefaults *off = [[NSUserDefaults alloc] initWithSuiteName:@"c_video_offline"];
    [off setObject:[NSString stringWithFormat:@"%ld", (long)BLCUnlimitedCount()] forKey:@"c_max_concurrent"];
    [off synchronize];
    Class svc = objc_getClass(BLCAccSvcClass);
    if (!svc) {
        NSLog(@"[BLC-Offline] AccountServiceImp not found");
        return;
    }
    BLCReplace(svc, @selector(isVip), (IMP)blcOfflineIsVip, &blcOrigIsVip);
    BLCReplace(svc, @selector(vipStatus), (IMP)blcOfflineVipStatus, &blcOrigVipStatus);
    BLCReplace(svc, @selector(vipType), (IMP)blcOfflineVipType, &blcOrigVipType);
    BLCReplace(svc, @selector(isSVip), (IMP)blcOfflineIsSVip, &blcOrigIsSVip);
    BLCReplace(svc, @selector(vipDueDate), (IMP)blcOfflineVipDueDate, &blcOrigVipDueDate);
}
