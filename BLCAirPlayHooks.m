#import "BLCAirPlayHooks.h"
#import <objc/runtime.h>
#import <pthread.h>
#import <substrate.h>
#import <unistd.h>

// During AirPlay the player outputs audio through IJKSDLSampleBufferAudioRenderer, which
// feeds AVSampleBufferAudioRenderer via -requestMediaDataWhenReadyOnQueue:usingBlock:.
// The block returns without enqueuing when -needMoreData says the player is far enough
// ahead, but with the ~2 s AirPlay buffer the renderer still reports ready, so AVFoundation
// re-invokes the block immediately. Measured on iPhone Air: ~37,000 -isReadyForMoreMediaData
// and ~18,000 -[AVSampleBufferRenderSynchronizer rate] calls per second, each a synchronous
// XPC round trip to mediaplaybackd. Waiting briefly when no data is needed ends the spin.
static const useconds_t BLCAirPlayIdleBackoff = 5000;

static BOOL (*BLCOriginalNeedMoreData)(id, SEL);

static BOOL BLCNeedMoreData(id self, SEL _cmd) {
    BOOL needed = BLCOriginalNeedMoreData(self, _cmd);
    if (!needed && !pthread_main_np()) {
        usleep(BLCAirPlayIdleBackoff);
    }
    return needed;
}

void BLCInstallAirPlayHooks(void) {
    Class renderer = NSClassFromString(@"IJKSDLSampleBufferAudioRenderer");
    SEL selector = NSSelectorFromString(@"needMoreData");
    if (renderer && class_getInstanceMethod(renderer, selector)) {
        MSHookMessageEx(renderer, selector, (IMP)BLCNeedMoreData, (IMP *)&BLCOriginalNeedMoreData);
    }
}
