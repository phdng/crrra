/* Actual shared fallback executed with a mock bundle on macOS CI.
 * No iOS private frameworks or jailbreak filesystem are needed. */
#import <Foundation/Foundation.h>
#import <assert.h>
#import "CRLocalization.h"

@interface CRLocalizationTestBundle : NSObject
@property (nonatomic, copy) NSDictionary *translations;
@property (nonatomic, copy) NSString *englishPath;
@end
@implementation CRLocalizationTestBundle
- (NSString *)localizedStringForKey:(NSString *)key value:(NSString *)value table:(NSString *)table
{
    (void)table;
    return self.translations[key] ?: value;
}
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)type
                 inDirectory:(NSString *)directory
{
    (void)name; (void)type; (void)directory;
    return self.englishPath;
}
@end

int main(void)
{
    @autoreleasepool {
        NSDictionary *english = nil;
        assert(CRLocalizedStringFromBundle(nil, nil, &english) == nil);
        assert([CRLocalizedStringFromBundle(nil, @"APPLICATIONS", &english)
                isEqualToString:@"APPLICATIONS"]);
        assert([CRLocalizedStringFromBundle(nil, @"SET_ACTIVE_CONTAINER_DESCRIPTION", &english)
                isEqualToString:@"SET_ACTIVE_CONTAINER_DESCRIPTION"]);
        CRLocalizationTestBundle *mock = [CRLocalizationTestBundle new];
        NSBundle *bundle = (id)mock;
        mock.translations = @{@"TRANSLATED": @"Translated", @"EMPTY": @""};
        assert([CRLocalizedStringFromBundle(bundle, @"TRANSLATED", &english)
                isEqualToString:@"Translated"]);
        assert([CRLocalizedStringFromBundle(bundle, @"EMPTY", &english)
                isEqualToString:@""]);
        assert([CRLocalizedStringFromBundle(bundle, @"UNKNOWN", &english)
                isEqualToString:@"UNKNOWN"]); /* absent English file */

        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"crane-localization-%@.strings", NSUUID.UUID.UUIDString]];
        assert(([@{@"APPLICATIONS": @"Applications",
                   @"SET_ACTIVE_CONTAINER_DESCRIPTION": @"Switch to %@",
                   @"NONSTRING": @42} writeToFile:path atomically:YES]));
        mock.englishPath = path;
        assert([CRLocalizedStringFromBundle(bundle, @"APPLICATIONS", &english)
                isEqualToString:@"Applications"]);
        assert([CRLocalizedStringFromBundle(bundle, @"NONSTRING", &english)
                isEqualToString:@"NONSTRING"]);
        assert([CRLocalizedStringFromBundle(bundle, @"UNKNOWN", &english)
                isEqualToString:@"UNKNOWN"]);
        NSString *format = CRLocalizedStringFromBundle(bundle,
            @"SET_ACTIVE_CONTAINER_DESCRIPTION", &english);
        assert(([[NSString stringWithFormat:format, @"Chrome"]
                isEqualToString:@"Switch to Chrome"]));
        assert([NSFileManager.defaultManager removeItemAtPath:path error:NULL]);
        /* A successfully cached English table still works after the file goes. */
        assert([CRLocalizedStringFromBundle(bundle, @"APPLICATIONS", &english)
                isEqualToString:@"Applications"]);
        NSLog(@"Crane localization smoke: missing resources, empty values and English fallback PASS");
        return 0;
    }
}
