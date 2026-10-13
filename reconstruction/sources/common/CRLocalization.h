#ifndef CR_LOCALIZATION_H
#define CR_LOCALIZATION_H

#import <Foundation/Foundation.h>

/* Crane 0x6924 with a missing-bundle guard. Kept independent of UIKit/XPC so
 * CI can execute the actual fallback used by every reconstructed component. */
static inline NSString *CRLocalizedStringFromBundle(
    NSBundle *bundle, NSString *key, NSDictionary * __strong *englishCache)
{
    if (!key)
        return nil;
    NSString *value = [bundle localizedStringForKey:key value:key table:nil];
    /* Preserve a valid intentionally empty translation, but never expose nil
     * labels or pass a nil format string to container-selection alerts. */
    if (!value || [value isEqualToString:key]) {
        if (!*englishCache && bundle) {
            NSString *path = [bundle pathForResource:@"Localizable"
                ofType:@"strings" inDirectory:@"en.lproj"];
            if (path.length)
                *englishCache = [NSDictionary dictionaryWithContentsOfFile:path];
        }
        id fallback = (*englishCache)[key];
        value = [fallback isKindOfClass:NSString.class] ? fallback : key;
    }
    return value ?: key;
}

#endif
