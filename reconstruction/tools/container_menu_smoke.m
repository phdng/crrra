/* Runs production filesystem, registry projection and preference defaults
 * on macOS CI. SpringBoard's private UI still needs an iPhone test. */
#import <Foundation/Foundation.h>
#import <assert.h>
#import "CRContainerScaffold.h"
#import "CRContainerRegistry.h"
#import "CRGameCenterAccounts.h"

static NSArray *Identifiers(NSDictionary *settings)
{
    return [settings[CRAppSetting_Containers] valueForKey:CRCContainer_Identifier];
}

int main(void)
{
    @autoreleasepool {
        for (NSString *key in @[CRPref_AppShortcutEnabled, CRPref_NewContainerShortcut,
             CRPref_OnlyShowIfContainersExist, CRPref_ShowContainerNotificationBadges,
             CRPref_NotificationsSupportEnabled, CRPref_ShowContainerInTitle]) {
            assert(CRPrefBoolValue(key, nil));
            assert(!CRPrefBoolValue(key, @NO));
            assert(CRPrefBoolValue(key, @YES));
        }
        for (NSString *key in @[CRPref_ExpandContainersShortcut,
             CRPref_LaunchAppOnContainerSelection, CRPref_AlwaysAskBeforeLaunch, @"unknown"]) {
            assert(!CRPrefBoolValue(key, nil));
            assert(!CRPrefBoolValue(key, @NO));
            assert(CRPrefBoolValue(key, @YES));
        }

        /* Original libcrane 0x937C projects a DEFAULT container when an
         * application has no saved settings. The old empty-dictionary smoke
         * expectations predated the recovered native registry contract. */
        NSDictionary *nativeDefault = @{
            CRAppSetting_Containers: @[@{
                CRCContainer_Name: @"",
                CRCContainer_Identifier: CR_DEFAULT_CONTAINER_IDENTIFIER
            }],
            CRCContainer_ActiveContainer: CR_DEFAULT_CONTAINER_IDENTIFIER
        };
        NSDictionary *fromNil = CRManagerSettingsIncludingDefault(nil);
        NSDictionary *fromEmpty = CRManagerSettingsIncludingDefault(@{});
        assert([fromNil isEqual:nativeDefault]);
        assert([fromEmpty isEqual:nativeDefault]);
        assert([Identifiers(fromNil) isEqual:@[CR_DEFAULT_CONTAINER_IDENTIFIER]]);
        assert([fromNil[CRCContainer_ActiveContainer]
            isEqual:CR_DEFAULT_CONTAINER_IDENTIFIER]);
        assert([CRManagerSettingsIncludingDefault(fromNil) isEqual:fromNil]);
        NSDictionary *custom = @{CRCContainer_Identifier: @"C1", CRCContainer_Name: @"First"};
        NSDictionary *legacy = @{CRCContainer_ActiveContainer: @"C1",
            CRAppSetting_Containers: @[custom], @"other": @"preserved"};
        NSDictionary *normalized = CRManagerSettingsIncludingDefault(legacy);
        NSArray *ids = Identifiers(normalized);
        assert((([ids isEqual:@[CR_DEFAULT_CONTAINER_IDENTIFIER, @"C1"]])));
        assert(Identifiers(legacy).count == 1); /* don't mutate the old registry */
        assert([normalized[@"other"] isEqual:@"preserved"]);
        assert([normalized[CRCContainer_ActiveContainer] isEqual:@"C1"]);
        assert([CRManagerSettingsIncludingDefault(normalized) isEqual:normalized]);

        NSDictionary *defaultOnly = @{CRAppSetting_Containers:
            @[@{CRCContainer_Identifier: CR_DEFAULT_CONTAINER_IDENTIFIER, CRCContainer_Name: @"Original"}]};
        assert([CRManagerSettingsIncludingDefault(defaultOnly) isEqual:defaultOnly]);
        NSDictionary *emptyList = @{CRAppSetting_Containers: @[]};
        assert(Identifiers(CRManagerSettingsIncludingDefault(emptyList)).count == 1);
        /* Native >1 gate hides DEFAULT-only, shows one custom + DEFAULT. */
        assert(Identifiers(normalized).count > 1);
        assert(!(Identifiers(defaultOnly).count > 1));
        NSDictionary *malformed = @{CRAppSetting_Containers: @[custom, custom, NSNull.null]};
        assert(Identifiers(CRManagerSettingsIncludingDefault(malformed)).count == 2);

        /* Native CranePrefs Game Center list is {identifier,name}, not
         * an array of identifiers. Reject partial writes to avoid deleting
         * unrelated account entries when input is malformed. */
        NSDictionary *gameA = @{@"identifier": @"A1", @"name": @"First"};
        NSDictionary *gameB = @{@"identifier": @"B2", @"name": @"Second"};
        NSArray *validGames = @[gameA, gameB];
        assert([CRGameCenterValidatedAccounts(nil) isEqual:@[]]);
        assert([CRGameCenterValidatedAccounts(validGames) isEqual:validGames]);
        assert(CRGameCenterAccountsAreValidForWrite(@[]));
        assert(CRGameCenterAccountsAreValidForWrite(validGames));
        assert(!CRGameCenterAccountsAreValidForWrite(nil));
        assert(!CRGameCenterAccountsAreValidForWrite(@[@"A1", gameB]));
        assert(!CRGameCenterAccountsAreValidForWrite(@[gameA, gameA]));
        assert(!CRGameCenterAccountsAreValidForWrite(
            @[@{@"identifier": CR_DEFAULT_CONTAINER_IDENTIFIER, @"name": @"Fake"}]));
        assert(!CRGameCenterAccountsAreValidForWrite(@[@{@"identifier": @"A1"}]));
        assert([CRGameCenterValidatedAccounts(@[gameA, NSNull.null, gameA, gameB])
            isEqual:validGames]);
        assert(CRGameCenterAccountIdentifierExists(validGames, @"A1"));
        assert(CRGameCenterAccountIdentifierExists(validGames, @"B2"));
        assert(CRGameCenterAccountIdentifierExists(validGames,
            CR_DEFAULT_CONTAINER_IDENTIFIER));
        assert(!CRGameCenterAccountIdentifierExists(validGames, @"unknown"));
        assert(!CRGameCenterAccountIdentifierExists(validGames, nil));
        assert([CRGameCenterResolvedActiveAccount(validGames, nil)
            isEqual:CR_DEFAULT_CONTAINER_IDENTIFIER]);
        assert([CRGameCenterResolvedActiveAccount(validGames, @"A1")
            isEqual:@"A1"]);
        assert([CRGameCenterResolvedActiveAccount(validGames, @"B2")
            isEqual:@"B2"]);
        assert([CRGameCenterResolvedActiveAccount(validGames, @"stale")
            isEqual:CR_DEFAULT_CONTAINER_IDENTIFIER]);
        assert([CRGameCenterResolvedActiveAccount(@[], @"A1")
            isEqual:CR_DEFAULT_CONTAINER_IDENTIFIER]);
        assert([CRGameCenterResolvedActiveAccount(validGames, @42)
            isEqual:CR_DEFAULT_CONTAINER_IDENTIFIER]);

        /* Unused-account removal must not mistake a container reference or
         * a malformed registry for an unused Game Center database. */
        BOOL gcValid = NO;
        NSDictionary *unreferencedSettings = @{@"Containers":
            @[@{@"identifier": @"DEFAULT"},
              @{@"identifier": @"C1", @"associatedGameCenterAccount": @"B2"}]};
        assert(CRGameCenterAccountReferencedInSettings(
            unreferencedSettings, @"B2", &gcValid));
        assert(gcValid);
        gcValid = NO;
        assert(!CRGameCenterAccountReferencedInSettings(
            unreferencedSettings, @"A1", &gcValid));
        assert(gcValid);
        gcValid = YES;
        assert(!CRGameCenterAccountReferencedInSettings(
            @{@"Containers": @[@{@"associatedGameCenterAccount": NSNull.null}]},
            @"A1", &gcValid));
        assert(!gcValid);
        gcValid = YES;
        assert(!CRGameCenterAccountReferencedInSettings(
            @{@"Containers": @"invalid"}, @"A1", &gcValid));
        assert(!gcValid);
        gcValid = YES;
        assert(!CRGameCenterAccountReferencedInSettings(
            @{@"Containers": @[NSNull.null]}, @"A1", &gcValid));
        assert(!gcValid);

        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"crane-menu-smoke-%@", NSUUID.UUID.UUIDString]];
        NSString *fresh = [root stringByAppendingPathComponent:@"fresh"];
        NSError *error = nil;
        assert(CRManagerCreateEmptyContainer(fresh, &error));
        assert(error == nil);
        for (NSString *relative in @[@"tmp", @"Library", @"Library/Caches",
             @"Library/Preferences", @"Library/SplashBoard", @"Documents", @"SystemData"]) {
            BOOL directory = NO;
            assert([fm fileExistsAtPath:[fresh stringByAppendingPathComponent:relative]
                           isDirectory:&directory] && directory);
        }
        /* Re-entering on a populated root must not try mkdir(Library) again. */
        assert(CRManagerCreateEmptyContainer(fresh, &error));

        NSString *outside = [root stringByAppendingPathComponent:@"outside"];
        assert([fm createDirectoryAtPath:outside withIntermediateDirectories:YES
                              attributes:nil error:&error]);
        NSString *marker = [outside stringByAppendingPathComponent:@"keep.txt"];
        assert([[@"untouched" dataUsingEncoding:NSUTF8StringEncoding]
            writeToFile:marker atomically:YES]);
        NSString *linked = [root stringByAppendingPathComponent:@"linked"];
        assert([fm createDirectoryAtPath:linked withIntermediateDirectories:YES
                              attributes:nil error:&error]);
        assert([fm createSymbolicLinkAtPath:[linked stringByAppendingPathComponent:@"Library"]
                       withDestinationPath:outside error:&error]);
        assert(!CRManagerCreateEmptyContainer(linked, &error));
        assert(![fm fileExistsAtPath:[outside stringByAppendingPathComponent:@"Caches"]]);

        NSString *nested = [root stringByAppendingPathComponent:@"nested"];
        assert(CRManagerCreateEmptyContainer(nested, &error));
        NSString *cache = [nested stringByAppendingPathComponent:@"Library/Caches"];
        assert([fm removeItemAtPath:cache error:&error]);
        assert([fm createSymbolicLinkAtPath:cache withDestinationPath:outside error:&error]);
        assert(!CRManagerCreateEmptyContainer(nested, &error));

        NSString *collision = [root stringByAppendingPathComponent:@"collision"];
        assert([fm createDirectoryAtPath:collision withIntermediateDirectories:YES
                              attributes:nil error:&error]);
        NSString *libraryFile = [collision stringByAppendingPathComponent:@"Library"];
        assert([[@"file" dataUsingEncoding:NSUTF8StringEncoding]
            writeToFile:libraryFile atomically:YES]);
        assert(!CRManagerCreateEmptyContainer(collision, &error));
        assert(([[NSString stringWithContentsOfFile:libraryFile encoding:NSUTF8StringEncoding
                    error:NULL] isEqual:@"file"]));
        assert(([[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding
                    error:NULL] isEqual:@"untouched"]));
        assert([fm removeItemAtPath:root error:&error]);
        NSLog(@"Crane production scaffold/defaults/registry smoke: PASS");
        return 0;
    }
}
