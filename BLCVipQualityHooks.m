#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// VIP quality options from the server's trial info.
//
// playview returns qn_trial_info {trial_able, remaining_times, time_length}.
// When trial_able is set, the quality panel can select a VIP quality and the
// server serves that stream. The hooks below keep the selected quality in the
// player and hide the trial banner, tags and pay button.

static NSString *const BLCVipQualityEnabledKey = @"blc.vip.quality.enabled";

static BOOL BLCVipQualityEnabled(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:BLCVipQualityEnabledKey];
    return value ? [value boolValue] : YES;
}

typedef struct {
    IMP startTrial;
    IMP modifyClose;
    IMP modifyBeforeEnd;
} BLCVipQualityHooks;

static BLCVipQualityHooks BLCUGCVipHooks;
static BLCVipQualityHooks BLCPGCVipHooks;
static Class BLCUGCVipClass;
static Class BLCPGCVipClass;

static BLCVipQualityHooks *BLCVipHooksFor(id object) {
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        if (cls == BLCUGCVipClass) return &BLCUGCVipHooks;
        if (cls == BLCPGCVipClass) return &BLCPGCVipHooks;
    }
    return NULL;
}

static void BLCVipStartTrial(id self, SEL _cmd) {
    BLCVipQualityHooks *hooks = BLCVipHooksFor(self);
    if (!BLCVipQualityEnabled()) {
        if (hooks && hooks->startTrial) ((void (*)(id, SEL))hooks->startTrial)(self, _cmd);
        return;
    }
    NSLog(@"[BLC-VipQuality] keep selected quality on %@", NSStringFromClass([self class]));
}

static void BLCVipModifyClose(id self, SEL _cmd, BOOL close) {
    BLCVipQualityHooks *hooks = BLCVipHooksFor(self);
    if (!BLCVipQualityEnabled()) {
        if (hooks && hooks->modifyClose) ((void (*)(id, SEL, BOOL))hooks->modifyClose)(self, _cmd, close);
    }
}

static void BLCVipModifyBeforeEnd(id self, SEL _cmd) {
    BLCVipQualityHooks *hooks = BLCVipHooksFor(self);
    if (!BLCVipQualityEnabled()) {
        if (hooks && hooks->modifyBeforeEnd) ((void (*)(id, SEL))hooks->modifyBeforeEnd)(self, _cmd);
    }
}

static void BLCVipHookMethod(Class cls, const char *name, IMP replacement, IMP *storage) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    if (!method) {
        NSLog(@"[BLC-VipQuality] missing %@ %s", NSStringFromClass(cls), name);
        return;
    }
    *storage = method_getImplementation(method);
    method_setImplementation(method, replacement);
    NSLog(@"[BLC-VipQuality] hooked %@ %s", NSStringFromClass(cls), name);
}

static void BLCVipInstall(Class cls, BLCVipQualityHooks *hooks) {
    if (!cls) return;
    BLCVipHookMethod(cls, "startTrial", (IMP)BLCVipStartTrial, &hooks->startTrial);
    BLCVipHookMethod(cls, "sendTrialModifyRequestForClose:", (IMP)BLCVipModifyClose, &hooks->modifyClose);
    BLCVipHookMethod(cls, "sendTrialModifyRequestBeforeTrialEnded", (IMP)BLCVipModifyBeforeEnd, &hooks->modifyBeforeEnd);
}

static void BLCVipInstallUIRules(void);

__attribute__((constructor)) static void BLCVipQualityInstall(void) {
    if (!BLCVipQualityEnabled()) return;
    BLCUGCVipClass = objc_getClass("BBPlayerVideoQualityTrialService");
    BLCPGCVipClass = objc_getClass("BBPgcPlayerVideoQualityTrialService");
    if (!BLCUGCVipClass && !BLCPGCVipClass) {
        NSLog(@"[BLC-VipQuality] trial services not found");
        return;
    }
    BLCVipInstall(BLCUGCVipClass, &BLCUGCVipHooks);
    BLCVipInstall(BLCPGCVipClass, &BLCPGCVipHooks);
    BLCVipInstallUIRules();
}

#pragma mark - Trial banner / "可试看" tag

static NSString *const BLCVipQualityAutoEnabledKey = @"blc.vip.quality.auto.enabled";

static BOOL BLCVipAutoEnabled(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:BLCVipQualityAutoEnabledKey];
    return value ? [value boolValue] : YES;
}

// The banner text ("剩 N 次大会员清晰度试用") comes straight from this getter.
static IMP BLCVipOrigTrialTipsText;
static id BLCVipTrialTipsText(id self, SEL _cmd) {
    if (BLCVipQualityEnabled()) return nil;
    return BLCVipOrigTrialTipsText ? ((id (*)(id, SEL))BLCVipOrigTrialTipsText)(self, _cmd) : nil;
}

// "可试看" / "试看中" tags are BFCLabel instances inside the quality rows.
static BOOL BLCVipHasAncestorClass(UIView *view, NSString *name) {
    for (UIView *current = view; current; current = current.superview) {
        if ([NSStringFromClass([current class]) rangeOfString:name].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL BLCVipTagText(NSString *text) {
    if (text.length == 0) return NO;
    return [text rangeOfString:@"可试看"].location != NSNotFound ||
           [text rangeOfString:@"试看中"].location != NSNotFound;
}

static void BLCVipHideTagAsync(UILabel *label) {
    if (!label || label.hidden) return;
    if (!BLCVipHasAncestorClass(label, @"BBPlayeVideoQualityListCell")) return;
    __weak UILabel *weakLabel = label;
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *strongLabel = weakLabel;
        if (!strongLabel) return;
        if (!BLCVipHasAncestorClass(strongLabel, @"BBPlayeVideoQualityListCell")) return;
        if (BLCVipTagText(strongLabel.text)) strongLabel.hidden = YES;
    });
}

// The pay button under the quality list ("成为大会员畅享全部清晰度").
static void BLCVipHidePayButtonAsync(UILabel *label) {
    if (!label || label.superview.hidden) return;
    if (!BLCVipHasAncestorClass(label, @"BBPlayerFloatingWidgetView")) return;
    __weak UILabel *weakLabel = label;
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *strongLabel = weakLabel;
        if (!strongLabel) return;
        if (!BLCVipHasAncestorClass(strongLabel, @"BBPlayerFloatingWidgetView")) return;
        NSString *text = strongLabel.text;
        if ([text rangeOfString:@"畅享全部清晰度"].location == NSNotFound &&
            [text rangeOfString:@"清晰度试用"].location == NSNotFound) return;
        strongLabel.superview.hidden = YES;
    });
}

static IMP BLCVipOrigButtonLabelSetText;
static void BLCVipButtonLabelSetText(UILabel *self, SEL _cmd, NSString *text) {
    if (BLCVipOrigButtonLabelSetText) ((void (*)(id, SEL, id))BLCVipOrigButtonLabelSetText)(self, _cmd, text);
    if (!BLCVipQualityEnabled()) return;
    NSString *value = self.text;
    if ([value rangeOfString:@"畅享全部清晰度"].location != NSNotFound ||
        [value rangeOfString:@"清晰度试用"].location != NSNotFound) {
        BLCVipHidePayButtonAsync(self);
    }
}

static IMP BLCVipOrigTagSetText;
static IMP BLCVipOrigTagSetAttributedText;

static void BLCVipTagSetText(UILabel *self, SEL _cmd, NSString *text) {
    if (BLCVipOrigTagSetText) ((void (*)(id, SEL, id))BLCVipOrigTagSetText)(self, _cmd, text);
    if (BLCVipQualityEnabled() && BLCVipTagText(self.text)) BLCVipHideTagAsync(self);
}

static void BLCVipTagSetAttributedText(UILabel *self, SEL _cmd, NSAttributedString *text) {
    if (BLCVipOrigTagSetAttributedText) ((void (*)(id, SEL, id))BLCVipOrigTagSetAttributedText)(self, _cmd, text);
    if (BLCVipQualityEnabled() && BLCVipTagText(self.text)) BLCVipHideTagAsync(self);
}

#pragma mark - Auto select the highest quality

static const void *BLCVipAutoSwitchKey = &BLCVipAutoSwitchKey;
static IMP BLCVipOrigFirstFrame;

static void BLCVipFirstFrame(id self, SEL _cmd, id playback) {
    if (BLCVipOrigFirstFrame) ((void (*)(id, SEL, id))BLCVipOrigFirstFrame)(self, _cmd, playback);
    if (!BLCVipQualityEnabled() || !BLCVipAutoEnabled()) return;
    if (objc_getAssociatedObject(self, BLCVipAutoSwitchKey)) return;
    objc_setAssociatedObject(self, BLCVipAutoSwitchKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id service = weakSelf;
        if (!service) return;
        SEL listSel = sel_registerName("availableQualityList");
        SEL qnSel = sel_registerName("qn");
        SEL currentSel = sel_registerName("currentQuality");
        SEL switchSel = sel_registerName("changeQualityWithExpectQualityQn:expectQualityIsAutoSwitch:preQualityQn:");
        if (![service respondsToSelector:listSel] || ![service respondsToSelector:currentSel] || ![service respondsToSelector:switchSel]) return;
        NSArray *list = ((id (*)(id, SEL))objc_msgSend)(service, listSel);
        long long maxQn = 0;
        for (id quality in list) {
            if (![quality respondsToSelector:qnSel]) continue;
            long long qn = ((long long (*)(id, SEL))objc_msgSend)(quality, qnSel);
            if (qn > maxQn) maxQn = qn;
        }
        long long current = ((long long (*)(id, SEL))objc_msgSend)(service, currentSel);
        if (maxQn <= current) return;
        ((void (*)(id, SEL, long long, BOOL, long long))objc_msgSend)(service, switchSel, maxQn, NO, current);
        NSLog(@"[BLC-VipQuality] auto switch %lld -> %lld", current, maxQn);
    });
}

static IMP BLCVipOrigAllowAutoVip;
static BOOL BLCVipAllowAutoVip(id self, SEL _cmd) {
    BOOL original = BLCVipOrigAllowAutoVip ? ((BOOL (*)(id, SEL))BLCVipOrigAllowAutoVip)(self, _cmd) : NO;
    if (original || !BLCVipQualityEnabled()) return original;
    SEL canTrial = sel_registerName("canTrialVipQuality");
    if (![self respondsToSelector:canTrial]) return original;
    return ((BOOL (*)(id, SEL))objc_msgSend)(self, canTrial);
}

static void BLCVipInstallUIRules(void) {
    Class trialClass = objc_getClass("BBPlayerVideoQualityTrialService");
    Method tips = trialClass ? class_getInstanceMethod(trialClass, sel_registerName("trialTipsText")) : NULL;
    if (tips) {
        BLCVipOrigTrialTipsText = method_getImplementation(tips);
        method_setImplementation(tips, (IMP)BLCVipTrialTipsText);
    }
    Class tagClass = objc_getClass("BFCLabel");
    Method setText = tagClass ? class_getInstanceMethod(tagClass, sel_registerName("setText:")) : NULL;
    if (setText) {
        BLCVipOrigTagSetText = method_getImplementation(setText);
        method_setImplementation(setText, (IMP)BLCVipTagSetText);
    }
    Method setAttributed = tagClass ? class_getInstanceMethod(tagClass, sel_registerName("setAttributedText:")) : NULL;
    if (setAttributed) {
        BLCVipOrigTagSetAttributedText = method_getImplementation(setAttributed);
        method_setImplementation(setAttributed, (IMP)BLCVipTagSetAttributedText);
    }
    Class qualityClassForAuto = objc_getClass("BBPlayerVideoQualityService");
    Method allowAuto = qualityClassForAuto ? class_getInstanceMethod(qualityClassForAuto, sel_registerName("allowAutoSwitchToVipQuality")) : NULL;
    if (allowAuto) {
        BLCVipOrigAllowAutoVip = method_getImplementation(allowAuto);
        method_setImplementation(allowAuto, (IMP)BLCVipAllowAutoVip);
    }
    Class buttonLabelClass = objc_getClass("UIButtonLabel");
    Method buttonText = buttonLabelClass ? class_getInstanceMethod(buttonLabelClass, sel_registerName("setText:")) : NULL;
    if (buttonText) {
        BLCVipOrigButtonLabelSetText = method_getImplementation(buttonText);
        method_setImplementation(buttonText, (IMP)BLCVipButtonLabelSetText);
    }
    Class qualityClass = objc_getClass("BBPlayerVideoQualityService");
    Method firstFrame = qualityClass ? class_getInstanceMethod(qualityClass, sel_registerName("playbackDidRenderFirstVideoFrame:")) : NULL;
    if (firstFrame) {
        BLCVipOrigFirstFrame = method_getImplementation(firstFrame);
        method_setImplementation(firstFrame, (IMP)BLCVipFirstFrame);
    }
    NSLog(@"[BLC-VipQuality] ui rules installed (tips=%d tag=%d button=%d firstFrame=%d)", tips != NULL, setText != NULL, buttonText != NULL, firstFrame != NULL);
}
