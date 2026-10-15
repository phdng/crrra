/* Portable behavioral tests for production root nested-group projection. */
#import <Foundation/Foundation.h>
#import <assert.h>
#import "CRRootSettingsProjection.h"

static NSArray *Visible(NSArray *rows, NSDictionary *stored)
{
    return CRRootVisibleNestedItems(rows, ^id(id item) {
        return [item isKindOfClass:NSDictionary.class] ? item[@"nestedEntryCount"] : nil;
    }, ^BOOL(id item) {
        id value = stored[item[@"key"]];
        if (!value)
            value = item[@"default"];
        return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
    });
}

static NSArray *Keys(NSArray *rows)
{
    NSMutableArray *result = [NSMutableArray new];
    for (id row in rows)
        [result addObject:row[@"key"] ?: @"group"];
    return result;
}

int main(void)
{
    @autoreleasepool {
        NSDictionary *shortcuts = @{@"key": @"applicationShortcutEnabled",
            @"default": @YES, @"nestedEntryCount": @5};
        NSDictionary *notifications = @{@"key": @"notificationsSupportEnabled",
            @"default": @YES, @"nestedEntryCount": @1};
        NSDictionary *nestedChild = @{@"key": @"inner",
            @"default": @NO, @"nestedEntryCount": @1};
        NSArray *rows = @[shortcuts,
            @{@"key": @"launch"},
            @{@"key": @"expand"},
            @{@"key": @"new"},
            @{@"key": @"onlyIf"},
            @{@"key": @"badge"},
            @{@"key": @"other"},
            notifications,
            @{@"key": @"showTitle"},
            @{@"key": @"after"}];
        NSArray *keys = Keys(rows);
        /* C assert is a single-argument macro: parenthesize expressions
         * containing comma-separated Objective-C array literals. */
        assert([Keys(Visible(rows, @{})) isEqual:keys]);
        assert(([Keys(Visible(rows, @{@"applicationShortcutEnabled": @NO}))
            isEqual:@[@"applicationShortcutEnabled", @"other",
                      @"notificationsSupportEnabled", @"showTitle", @"after"]]));
        assert(([Keys(Visible(rows, @{@"notificationsSupportEnabled": @NO}))
            isEqual:@[@"applicationShortcutEnabled", @"launch", @"expand",
                      @"new", @"onlyIf", @"badge", @"other",
                      @"notificationsSupportEnabled", @"after"]]));
        assert(([Keys(Visible(rows, @{@"applicationShortcutEnabled": @NO,
                                     @"notificationsSupportEnabled": @NO}))
            isEqual:@[@"applicationShortcutEnabled", @"other",
                      @"notificationsSupportEnabled", @"after"]]));
        assert([Keys(Visible(rows, @{@"applicationShortcutEnabled": @YES,
                                     @"notificationsSupportEnabled": @YES}))
            isEqual:keys]);

        NSArray *nested = @[
            @{@"key": @"parent", @"default": @YES, @"nestedEntryCount": @3},
            nestedChild,
            @{@"key": @"grandchild"},
            @{@"key": @"sibling"},
            @{@"key": @"tail"}];
        assert(([Keys(Visible(nested, @{}))
            isEqual:@[@"parent", @"inner", @"sibling", @"tail"]]));
        assert(([Keys(Visible(nested, @{@"inner": @YES}))
            isEqual:@[@"parent", @"inner", @"grandchild", @"sibling", @"tail"]]));
        assert(([Keys(Visible(nested, @{@"parent": @NO, @"inner": @YES}))
            isEqual:@[@"parent", @"tail"]]));

        /* Invalid metadata cannot skip the next group or the last row. */
        NSArray *malformed = @[
            @{@"key": @"badTooLong", @"nestedEntryCount": @99},
            @{@"key": @"badType", @"nestedEntryCount": @"3"},
            @{@"key": @"badNegative", @"nestedEntryCount": @(-2)},
            @{@"key": @"tail"}];
        assert([Keys(Visible(malformed, @{})) isEqual:Keys(malformed)]);
        assert([CRRootVisibleNestedItems(nil, nil, nil) isEqual:@[]]);
        NSLog(@"Crane Root Settings nested groups: PASS");
        return 0;
    }
}
