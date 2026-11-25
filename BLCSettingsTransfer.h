#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// User settings (NSUserDefaults keys with the "blc." prefix) as JSON, so they can be
// moved between installs with different bundle identifiers. Server caches are skipped.
FOUNDATION_EXPORT NSString *BLCSettingsExportJSON(NSUInteger *_Nullable count);
FOUNDATION_EXPORT NSUInteger BLCSettingsImportJSON(NSString *json, NSError **error);

NS_ASSUME_NONNULL_END
