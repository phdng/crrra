/*
 * CRRootSuggestions.m — CranePrefs root Suggestions, original 0x21470–0x21B40.
 *
 * Unlike original 0x21470, directory enumeration is checked before reading
 * entries. Detection is read-only and intentionally fails closed when no
 * trusted local evidence is available. No injection/daemon state is mutated.
 */
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "CRCommon.h"

@interface PSSpecifier : NSObject
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target
                          set:(SEL)set get:(SEL)get detail:(Class)detail
                         cell:(NSInteger)cell edit:(NSInteger)edit;
+ (id)emptyGroupSpecifier;
- (void)setName:(NSString *)name;
- (void)setIdentifier:(NSString *)identifier;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end

/* PSTableCell is supplied by Preferences.framework on device. Original
 * CRPInfoTableCell 0x168CC adds a detail-button accessory after base refresh. */
@interface PSTableCell : UITableViewCell
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier;
@end

@interface CRPInfoTableCell : PSTableCell
@end

@implementation CRPInfoTableCell
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];
    self.accessoryType = UITableViewCellAccessoryDetailButton;
}
@end

@interface CRPRootPageSuggestionProvider : NSObject
+ (BOOL)shouldShowChoicyLoaderSuggestion;
+ (BOOL)shouldShowActivatorInfoSuggestion;
+ (BOOL)shouldShowShortcutsInfoSuggestion;
+ (NSArray *)suggestionSpecifiers;
+ (UIAlertController *)alertControllerForSpecifierIdentifier:(NSString *)identifier;
@end

@implementation CRPRootPageSuggestionProvider

/* Native 0x21470 only considers the suggestion on Substrate, if its loader
 * is absent and a distinct installed tweak uses a .dylib in the injection
 * directory. Original unguarded POSIX traversal could crash if the directory is missing. */
+ (BOOL)shouldShowChoicyLoaderSuggestion
{
    if (![CRGetInjectionPlatform() isEqualToString:@"Substrate"])
        return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *loader = CRJailbreakRootPath(@"/usr/lib/ChoicyLoader.dylib");
    if (!loader || [fm fileExistsAtPath:loader])
        return NO;
    NSString *directory = CRJailbreakRootPath(
        @"/Library/MobileSubstrate/DynamicLibraries");
    if (!directory)
        return NO;
    NSError *error = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:directory
                                                           error:&error];
    if (!entries || error)
        return NO;
    for (NSString *name in entries) {
        /* Preserve original reserved names, and skip Crane's own dylibs:
         * they are not evidence of a third-party tweak. */
        if (![name.pathExtension isEqualToString:@"dylib"] ||
            [name isEqualToString:@"   Choicy.dylib"] ||
            [name isEqualToString:@" Crane.dylib"] ||
            [name isEqualToString:@"CraneSB.dylib"] ||
            [name isEqualToString:@"CraneSupport.dylib"])
            continue;
        return YES;
    }
    return NO;
}

/* Native 0x216E0 checks the injected library path, not app installation. */
+ (BOOL)shouldShowActivatorInfoSuggestion
{
    NSString *path = CRJailbreakRootPath(@"/usr/lib/libactivator.dylib");
    return path.length > 0 &&
        [NSFileManager.defaultManager fileExistsAtPath:path];
}

/* Native 0x217BC asks LaunchServices for com.apple.shortcuts.isInstalled.
 * Avoid linking undocumented classes against roothide's incomplete SDK. */
+ (BOOL)shouldShowShortcutsInfoSuggestion
{
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
    SEL installed = NSSelectorFromString(@"isInstalled");
    if (!proxyClass || ![proxyClass respondsToSelector:lookup])
        return NO;
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(
        proxyClass, lookup, @"com.apple.shortcuts");
    if (!proxy || ![proxy respondsToSelector:installed])
        return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(proxy, installed);
}

+ (NSArray *)suggestionSpecifiers
{
    BOOL choicy = [self shouldShowChoicyLoaderSuggestion];
    BOOL activator = [self shouldShowActivatorInfoSuggestion];
    BOOL shortcuts = [self shouldShowShortcutsInfoSuggestion];
    if (!choicy && !activator && !shortcuts)
        return @[];

    NSMutableArray *rows = [NSMutableArray new];
    PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
    [group setName:CRLocalize(@"SUGGESTIONS")];
    [group setIdentifier:@"suggestionsGroup"];
    [rows addObject:group];
    NSArray<NSArray<NSString *> *> *items = @[
        @[@"choicyLoaderSuggestion", @"CHOICYLOADER_SUGGESTION_TITLE"],
        @[@"activatorInfoSuggestion", @"ACTIVATOR_INFO_SUGGESTION_TITLE"],
        @[@"shortcutsInfoSuggestion", @"SHORTCUTS_INFO_SUGGESTION_TITLE"]
    ];
    BOOL enabled[] = {choicy, activator, shortcuts};
    for (NSUInteger i = 0; i < items.count; i++) {
        if (!enabled[i])
            continue;
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:
            CRLocalize(items[i][1]) target:self set:NULL get:NULL detail:Nil
            cell:7 edit:0];
        [row setIdentifier:items[i][0]];
        [row setProperty:@YES forKey:@"enabled"];
        [row setProperty:[CRPInfoTableCell class] forKey:@"cellClass"];
        [rows addObject:row];
    }
    return [rows copy];
}

+ (UIAlertController *)alertControllerForSpecifierIdentifier:(NSString *)identifier
{
    NSString *titleKey = nil;
    NSString *messageKey = nil;
    BOOL offersRepo = NO;
    if ([identifier isEqualToString:@"choicyLoaderSuggestion"]) {
        titleKey = @"CHOICYLOADER_SUGGESTION_TITLE";
        messageKey = @"CHOICYLOADER_SUGGESTION_MESSAGE";
        offersRepo = YES;
    } else if ([identifier isEqualToString:@"activatorInfoSuggestion"]) {
        titleKey = @"ACTIVATOR_INFO_SUGGESTION_TITLE";
        messageKey = @"ACTIVATOR_INFO_SUGGESTION_MESSAGE";
    } else if ([identifier isEqualToString:@"shortcutsInfoSuggestion"]) {
        titleKey = @"SHORTCUTS_INFO_SUGGESTION_TITLE";
        messageKey = @"SHORTCUTS_INFO_SUGGESTION_MESSAGE";
    } else {
        return nil;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        CRLocalize(titleKey) message:CRLocalize(messageKey)
        preferredStyle:UIAlertControllerStyleAlert];
    if (offersRepo) {
        [alert addAction:[UIAlertAction actionWithTitle:CRLocalize(@"OPEN_REPO")
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            /* Original block 0x21AC0: repository landing page only. */
            NSURL *url = [NSURL URLWithString:@"https://opa334.github.io"];
            [UIApplication.sharedApplication openURL:url options:@{}
                                   completionHandler:nil];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:CRLocalize(@"CLOSE")
        style:UIAlertActionStyleCancel handler:nil]];
    return alert;
}
@end
