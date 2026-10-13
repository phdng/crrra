#ifndef CR_CONTAINER_REGISTRY_H
#define CR_CONTAINER_REGISTRY_H

#import "CRPreferences.h"
#import "CRPaths.h"

/* Native 0x15E20/0x170A4 count all Containers (>1 means DEFAULT + custom);
 * 0x137FC/0x16A90 enumerate that same array into selection actions.
 * Reconstructed older registries stored only custom entries. Project an
 * implicit DEFAULT into those dictionaries without deleting or relocating data.
 * Original libcrane storage internals are not exported; this is an adapter. */
static inline NSDictionary *CRManagerSettingsIncludingDefault(NSDictionary *settings)
{
    if (![settings isKindOfClass:NSDictionary.class] || !settings.count)
        return @{};
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
