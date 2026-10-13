/* Executes the actual editor implementation against an inherited mock private
 * API on macOS CI. This validates Objective-C dispatch, not iOS/Choicy parity. */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <assert.h>
#import "CRManager.h"
#import "CRPreferences.h"
#import "CRChoicyEditor.h"

static NSMutableDictionary *stores;
static NSString *activeContainer = @"A";
static NSUInteger writes, reloads, originalReads, originalWrites, originalPosts;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation CraneManager
+ (CraneManager *)sharedManager
{
    static CraneManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [CraneManager new]; });
    return manager;
}
- (NSArray *)containerIdentifiersOfApplicationWithIdentifier:(NSString *)appID
{
    return [stores[appID] allKeys] ?: @[];
}
- (NSDictionary *)containerSettingsForContainerWithIdentifier:(NSString *)containerID
                                 ofApplicationWithIdentifier:(NSString *)appID
{
    return stores[appID][containerID] ?: @{};
}
- (void)setContainerSettings:(NSDictionary *)settings
  forContainerWithIdentifier:(NSString *)containerID
   ofApplicationWithIdentifier:(NSString *)appID
{
    stores[appID][containerID] = [settings copy];
    writes++;
}
- (NSString *)activeContainerIdentifierForApplicationWithIdentifier:(NSString *)appID
{
    (void)appID;
    return activeContainer;
}
- (void)reloadApplicationWithIdentifier:(NSString *)appID
{
    assert([appID isEqual:@"app"]);
    reloads++;
}
@end
#pragma clang diagnostic pop

@interface CRSmokeSpecifier : NSObject
@property (nonatomic, copy) NSDictionary *properties;
- (id)propertyForKey:(NSString *)key;
@end
@implementation CRSmokeSpecifier
- (id)propertyForKey:(NSString *)key { return self.properties[key]; }
@end

@interface CRSmokeTweak : NSObject
@property (nonatomic, copy) NSString *dylibName;
@property (nonatomic) BOOL visible;
@end
@implementation CRSmokeTweak
@end

@interface CRSmokeChoicyBase : NSObject
@property (nonatomic, strong) CRSmokeSpecifier *specifier;
@property (nonatomic, strong) NSMutableDictionary *processPreferences;
- (NSString *)applicationIdentifier;
- (BOOL)shouldShowAppPlugIns;
- (BOOL)shouldShowTweak:(CRSmokeTweak *)tweak;
- (void)readPreferences;
- (void)writePreferences;
- (void)sendPostNotification;
@end
@implementation CRSmokeChoicyBase
- (NSString *)applicationIdentifier
{
    return [self.specifier propertyForKey:@"applicationIdentifier"];
}
- (BOOL)shouldShowAppPlugIns { return YES; }
- (BOOL)shouldShowTweak:(CRSmokeTweak *)tweak { return tweak.visible; }
- (void)readPreferences { originalReads++; }
- (void)writePreferences { originalWrites++; }
- (void)sendPostNotification { originalPosts++; }
@end

static CRSmokeSpecifier *Specifier(id app, id container)
{
    CRSmokeSpecifier *specifier = [CRSmokeSpecifier new];
    specifier.properties = @{@"applicationIdentifier": app,
                              @"containerIdentifier": container};
    return specifier;
}

static NSInteger IncompatiblePlugInsReturn(id self, SEL selector)
{
    (void)self;
    (void)selector;
    return 1;
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        NSString *mode = argc > 1 ? @(argv[1]) : @"valid";
        /* A failed lookup must not poison a future retry after bundle load. */
        assert(CRChoicyContainerEditorClass() == Nil);
        if ([mode isEqual:@"missing"])
            return 0;
        Class parent = objc_allocateClassPair(
            [mode isEqual:@"incomplete"] ? NSObject.class : CRSmokeChoicyBase.class,
            "CHPProcessConfigurationListController", 0);
        assert(parent);
        if ([mode isEqual:@"incompatible"])
            assert(class_addMethod(parent, @selector(shouldShowAppPlugIns),
                (IMP)IncompatiblePlugInsReturn, "q@:"));
        objc_registerClassPair(parent);
        if ([mode isEqual:@"incompatible"] || [mode isEqual:@"incomplete"]) {
            assert(CRChoicyContainerEditorClass() == Nil);
            return 0;
        }
        if ([mode isEqual:@"collision"]) {
            Class collision = objc_allocateClassPair(NSObject.class,
                "CRPContainerChoicyOverwriteListController", 0);
            assert(collision);
            objc_registerClassPair(collision);
            assert(CRChoicyContainerEditorClass() == Nil);
            return 0;
        }

        stores = [@{@"app": [@{
            @"A": @{@"identifier": @"A", @"name": @"First",
                     @"notificationsAllowed": @NO,
                     CRCContainer_ChoicyConfigurationOverwrite: @{@"flag": @1}},
            @"B": @{@"identifier": @"B", @"name": @"Second"},
        } mutableCopy]} mutableCopy];
        Class editorClass = CRChoicyContainerEditorClass();
        assert(editorClass && class_getSuperclass(editorClass) == parent);
        assert(CRChoicyContainerEditorClass() == editorClass);
        CRSmokeChoicyBase *editor = [editorClass new];
        editor.specifier = Specifier(@"app", @"A");
        assert(![editor shouldShowAppPlugIns]);
        assert([[parent new] shouldShowAppPlugIns]);

        CRSmokeTweak *tweak = [CRSmokeTweak new];
        tweak.visible = YES;
        tweak.dylibName = @" Crane";
        assert(![editor shouldShowTweak:tweak]);
        assert([[parent new] shouldShowTweak:tweak]);
        tweak.dylibName = @"Other";
        assert([editor shouldShowTweak:tweak]);
        tweak.visible = NO;
        assert(![editor shouldShowTweak:tweak]);
        assert(![editor shouldShowTweak:(id)[NSObject new]]);

        [editor readPreferences];
        assert([editor.processPreferences[@"flag"] isEqual:@1]);
        editor.processPreferences[@"flag"] = @2;
        assert([stores[@"app"][@"A"][CRCContainer_ChoicyConfigurationOverwrite][@"flag"]
                isEqual:@1]); /* read didn't expose the stored mutable dictionary */

        /* An unrelated field edited while this page is open is retained. */
        NSMutableDictionary *latest = [stores[@"app"][@"A"] mutableCopy];
        latest[@"name"] = @"Renamed";
        stores[@"app"][@"A"] = latest;
        [editor writePreferences];
        assert(writes == 1);
        assert([stores[@"app"][@"A"][@"name"] isEqual:@"Renamed"]);
        assert([stores[@"app"][@"A"][@"notificationsAllowed"] isEqual:@NO]);
        assert([stores[@"app"][@"A"][CRCContainer_ChoicyConfigurationOverwrite][@"flag"]
                isEqual:@2]);
        editor.processPreferences[@"flag"] = @3;
        assert([stores[@"app"][@"A"][CRCContainer_ChoicyConfigurationOverwrite][@"flag"]
                isEqual:@2]); /* save snapshot is independent */
        [editor sendPostNotification];
        assert(reloads == 1);

        editor.specifier = Specifier(@"app", @"B");
        [editor readPreferences];
        assert(editor.processPreferences && editor.processPreferences.count == 0);
        editor.processPreferences[@"other"] = @YES;
        [editor writePreferences];
        [editor sendPostNotification];
        assert(writes == 2 && reloads == 1);
        assert([stores[@"app"][@"B"][CRCContainer_ChoicyConfigurationOverwrite][@"other"]
                isEqual:@YES]);
        assert([stores[@"app"][@"A"][CRCContainer_ChoicyConfigurationOverwrite][@"flag"]
                isEqual:@2]);

        /* Reject non-plist payloads and stale/default/malformed navigation. */
        editor.processPreferences = (id)@{@"invalid": NSNull.null};
        [editor writePreferences];
        assert(writes == 2);
        editor.processPreferences = (id)NSNull.null;
        [editor writePreferences];
        assert(writes == 2);
        for (id container in @[@"DEFAULT", @"Deleted", NSNull.null]) {
            editor.specifier = Specifier(@"app", container);
            [editor readPreferences];
            assert(editor.processPreferences.count == 0);
            editor.processPreferences[@"new"] = @YES;
            [editor writePreferences];
            [editor sendPostNotification];
            assert(writes == 2 && reloads == 1);
        }
        editor.specifier = Specifier(NSNull.null, @"A");
        [editor writePreferences];
        assert(writes == 2);
        assert(originalReads == 0 && originalWrites == 0 && originalPosts == 0);
        NSLog(@"Choicy editor smoke: scoped read/write, inheritance and failure guards PASS");
        return 0;
    }
}
