#import <Foundation/Foundation.h>

// Diagnostics-only build (make release DIAG=1). Not part of normal releases.

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void BLCDiagEvent(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT NSArray<NSString *> *BLCDiagRecentEvents(NSUInteger limit);

FOUNDATION_EXPORT id _Nullable BLCDiagValue(id _Nullable object, NSString *key);
FOUNDATION_EXPORT NSString *BLCDiagShort(id _Nullable value, NSUInteger maxLength);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *BLCDiagIvars(id _Nullable object);

FOUNDATION_EXPORT NSDictionary *BLCDiagProcessState(void);
FOUNDATION_EXPORT NSArray<NSDictionary *> *BLCDiagThreadUsage(void);
FOUNDATION_EXPORT double BLCDiagProcessCPU(void);

FOUNDATION_EXPORT NSDictionary *BLCDiagSample(double seconds, double hz);
FOUNDATION_EXPORT NSDictionary *BLCDiagCount(double seconds, NSArray<NSString *> *_Nullable classNames);

FOUNDATION_EXPORT void BLCDiagInstallDownloadHooks(void);
FOUNDATION_EXPORT NSDictionary *BLCDiagDownloadState(void);
FOUNDATION_EXPORT NSString *BLCDiagDownloadSummary(void);

NS_ASSUME_NONNULL_END
