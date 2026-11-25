#import "BLCSettingsTransfer.h"
#import "BLCCDNManager.h"
#import "BLCTabManager.h"

static NSString *const BLCSettingsPrefix = @"blc.";
static NSString *const BLCSettingsFormat = @"BiliClean settings";

static BOOL BLCSettingsKeyTransferable(NSString *key) {
    static NSSet<NSString *> *skipped;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        skipped = [NSSet setWithArray:@[@"blc.tab.cached.response", @"blc.tab.cached.items", @"blc.tab.updated.at", @"blc.cdn.last.speeds"]];
    });
    return [key hasPrefix:BLCSettingsPrefix] && ![skipped containsObject:key];
}

NSString *BLCSettingsExportJSON(NSUInteger *count) {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] persistentDomainForName:NSBundle.mainBundle.bundleIdentifier] ?: @{};
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    for (NSString *key in stored) {
        id value = stored[key];
        if (BLCSettingsKeyTransferable(key) && [NSJSONSerialization isValidJSONObject:@[value]]) settings[key] = value;
    }
    if (count) *count = settings.count;
    NSDictionary *root = @{@"format": BLCSettingsFormat, @"settings": settings};
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

NSUInteger BLCSettingsImportJSON(NSString *json, NSError **error) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *settings = [root isKindOfClass:NSDictionary.class] && [root[@"format"] isEqual:BLCSettingsFormat] ? root[@"settings"] : nil;
    if (![settings isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:@"com.biliclean.settings" code:1 userInfo:@{NSLocalizedDescriptionKey: @"剪贴板里没有 BiliClean 设置"}];
        return 0;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSUInteger imported = 0;
    for (NSString *key in settings) {
        if (![key isKindOfClass:NSString.class] || !BLCSettingsKeyTransferable(key)) continue;
        [defaults setObject:settings[key] forKey:key];
        imported++;
    }
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:BLCCDNConfigurationDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:BLCTabConfigurationDidChangeNotification object:nil];
    return imported;
}
