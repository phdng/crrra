/*
 * CRRootSettingsProjection.h — pure Foundation projection of native
 * CranePrefs Root.plist nestedEntryCount group visibility (0x20828).
 *
 * Preserve the canonical ordered specifier array. An OFF switch hides only
 * its declared following entries; nested disabled switches compose naturally.
 * Bounds errors are treated as invalid metadata, never as permission to
 * remove arbitrary unrelated Settings rows.
 */
#ifndef CR_ROOT_SETTINGS_PROJECTION_H
#define CR_ROOT_SETTINGS_PROJECTION_H

#import <Foundation/Foundation.h>

static inline NSArray *CRRootVisibleNestedItems(
    NSArray *allItems,
    id (^nestedCountForItem)(id item),
    BOOL (^enabledForItem)(id item))
{
    if (![allItems isKindOfClass:NSArray.class] ||
        !nestedCountForItem || !enabledForItem)
        return @[];
    NSMutableArray *visible = [NSMutableArray arrayWithCapacity:allItems.count];
    for (NSUInteger index = 0; index < allItems.count; ++index) {
        id item = allItems[index];
        [visible addObject:item];
        id raw = nestedCountForItem(item);
        if (!raw)
            continue;
        if (![raw isKindOfClass:NSNumber.class])
            continue;
        NSInteger nested = [raw integerValue];
        NSUInteger remaining = allItems.count - index - 1;
        if (nested <= 0 || (NSUInteger)nested > remaining)
            continue;
        if (!enabledForItem(item))
            index += (NSUInteger)nested;
    }
    return [visible copy];
}

#endif /* CR_ROOT_SETTINGS_PROJECTION_H */
