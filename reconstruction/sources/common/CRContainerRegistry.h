#ifndef CR_CONTAINER_REGISTRY_H
#define CR_CONTAINER_REGISTRY_H

#import "CRPreferences.h"
#import "CRPaths.h"

/* Original libcrane 0x937C stores each app under appSettings_<bundleID>.
 * If that key is absent it returns exactly:
 *   { Containers = ({ name = ""; identifier = DEFAULT; });
 *     activeContainer = DEFAULT; }
 * Older reconstruction builds omitted DEFAULT from their persisted arrays, so
 * existing nonempty dictionaries are normalized on read without deleting data. */
static inline NSDictionary *CRManagerSettingsIncludingDefault(NSDictionary *settings)
{
    if (![settings isKindOfClass:NSDictionary.class] || !settings.count) {
        return @{
            CRAppSetting_Containers: @[@{
                CRCContainer_Name: @"",
                CRCContainer_Identifier: CR_DEFAULT_CONTAINER_IDENTIFIER
            }],
            CRCContainer_ActiveContainer: CR_DEFAULT_CONTAINER_IDENTIFIER
        };
    }
    NSMutableDictionary *result = [settings mutableCopy];
    id stored = settings[CRAppSetting_Containers];
    NSMutableArray *containers = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    if ([stored isKindOfClass:NSArray.class]) {
        for (id entry in stored) {
            if (![entry isKindOfClass:NSDictionary.class])
                continue;
            id identifier = entry[CRCContainer_Identifier];
            if (![identifier isKindOfClass:NSString.class] ||
                ![identifier length] || [seen containsObject:identifier])
                continue;
            [seen addObject:identifier];
            [containers addObject:[entry copy]];
        }
    }
    if (![seen containsObject:CR_DEFAULT_CONTAINER_IDENTIFIER])
        [containers insertObject:@{CRCContainer_Identifier:CR_DEFAULT_CONTAINER_IDENTIFIER}
                         atIndex:0];
    result[CRAppSetting_Containers] = [containers copy];
    return [result copy];
}

#endif
