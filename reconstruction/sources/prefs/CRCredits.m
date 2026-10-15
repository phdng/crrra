/*
 * CRCredits.m — Credits & Licenses controllers recovered from CranePrefs.
 *
 * Original method evidence:
 *   CRPCreditsController                0x146D4–0x14A0C
 *   CRPCreditsMiniZipController         0x14A20
 *   CRPCreditsZipArchiveController      0x14A88
 *   CRPListController localizeSpecifiers 0x16DA0
 *   CRPListController openTwitter...     0x16F9C
 *
 * Keep the original Credits/MiniZipLicense/ZipArchiveLicense plists in layout/.
 * No dynamic licensing text, network retrieval, or account/data mutations.
 */
#import <UIKit/UIKit.h>
#import "CRCommon.h"
#import "CRCreditsLinks.h"

/* Minimal declarations; private Preferences.framework provides the classes.
 * These definitions are local to this compilation unit and do not instantiate
 * substitute runtime PSListController classes. */
@interface PSViewController : UIViewController
@end

@interface PSListController : PSViewController
- (id)specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface PSSpecifier : NSObject
- (NSString *)name;
- (void)setName:(NSString *)name;
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (void)setDetailControllerClass:(Class)cls;
@end

static void CRCreditsOpenURL(NSString *urlString)
{
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || ![url.scheme isEqualToString:@"https"])
        return;
    [UIApplication.sharedApplication openURL:url options:@{}
                           completionHandler:nil];
}

/* Native 0x16F9C prefers the Twitter app and falls back to its web profile.
 * The usernames below are all recovered literals, not user-controlled data. */
void CRCreditsOpenTwitter(NSString *username)
{
    if (![username isKindOfClass:NSString.class] || !username.length)
        return;
    NSURL *scheme = [NSURL URLWithString:@"twitter://"];
    UIApplication *app = UIApplication.sharedApplication;
    if (scheme && [app canOpenURL:scheme]) {
        NSString *encoded = [username stringByAddingPercentEncodingWithAllowedCharacters:
            NSCharacterSet.URLQueryAllowedCharacterSet];
        NSURL *deepLink = [NSURL URLWithString:
            [NSString stringWithFormat:@"twitter://user?screen_name=%@", encoded]];
        if (deepLink) {
            [app openURL:deepLink options:@{} completionHandler:nil];
            return;
        }
    }
    NSString *encoded = [username stringByAddingPercentEncodingWithAllowedCharacters:
        NSCharacterSet.URLPathAllowedCharacterSet];
    CRCreditsOpenURL([NSString stringWithFormat:
        @"https://twitter.com/%@", encoded]);
}

/* Original CRPListController 0x16DA0 localizes each label and footer. */
static NSArray *CRCreditsLocalizedRows(PSListController *controller,
                                      NSString *plistName,
                                      BOOL localize)
{
    NSArray *loaded = [controller loadSpecifiersFromPlistName:plistName
                                                      target:controller] ?: @[];
    NSUInteger licenseIndex = 0;
    for (PSSpecifier *row in loaded) {
        NSString *name = [row name];
        /* The original Credits.plist has two LICENSE rows, ZipArchive then
         * MiniZip. Explicitly bind both detail classes: the private plist
         * loader's class-string resolution differs across Preferences builds. */
        if ([plistName isEqualToString:@"Credits"] &&
            [name isEqualToString:@"LICENSE"]) {
            Class detail = NSClassFromString(licenseIndex == 0
                ? @"CRPCreditsZipArchiveController"
                : @"CRPCreditsMiniZipController");
            if (detail)
                [row setDetailControllerClass:detail];
            ++licenseIndex;
        }
        if (localize && [name isKindOfClass:NSString.class]) {
            NSString *translated = CRLocalize(name);
            if (translated)
                [row setName:translated];
            id footer = [row propertyForKey:@"footerText"];
            if ([footer isKindOfClass:NSString.class]) {
                NSString *localized = CRLocalize(footer);
                if (localized)
                    [row setProperty:localized forKey:@"footerText"];
            }
        }
    }
    return loaded;
}

static void CRCreditsInstallBacking(PSListController *controller, NSArray *rows)
{
    @try {
        [controller setValue:rows forKey:@"_specifiers"];
    } @catch (NSException *exception) {
        NSLog(@"CranePrefs: Credits specifier backing unavailable: %@", exception);
    }
}

@interface CRPCreditsController : PSListController
@property (nonatomic, strong) NSArray *craneCreditsSpecifiers;
@end

@implementation CRPCreditsController

- (void)viewDidLoad
{
    [self specifiers];
    [super viewDidLoad];
}

- (id)specifiers
{
    if (!self.craneCreditsSpecifiers)
        self.craneCreditsSpecifiers =
            CRCreditsLocalizedRows(self, @"Credits", YES);
    self.navigationItem.title = CRLocalize(@"CREDITS_AND_LICENSES");
    CRCreditsInstallBacking(self, self.craneCreditsSpecifiers);
    return self.craneCreditsSpecifiers;
}

/* Exact external destinations recovered from CranePrefs 0x147B0/0x14830/
 * 0x14978. The remaining actions call 0x16F9C with the original usernames. */
- (void)zipArchiveLink
{
    CRCreditsOpenURL(@"https://github.com/ZipArchive/ZipArchive");
}

- (void)miniZipLink
{
    CRCreditsOpenURL(@"https://github.com/nmoinvaz/minizip");
}

- (void)trithucLink { CRCreditsOpenTwitter(@"Trithuc16"); }
- (void)nvbikLink { CRCreditsOpenTwitter(@"nvbik584"); }
- (void)sn0wl3r0kerLink { CRCreditsOpenTwitter(@"Sn0wl3r0ker"); }
- (void)nzar1988Link { CRCreditsOpenTwitter(@"nzar1988"); }
- (void)bwntyHntrLink { CRCreditsOpenTwitter(@"BwntyHntr"); }
- (void)guezomriLink { CRCreditsOpenTwitter(@"guezomri"); }
- (void)torrekieLink { CRCreditsOpenTwitter(@"Torrekie"); }
- (void)ian_dxxLink { CRCreditsOpenTwitter(@"ian_dxx"); }
- (void)Vitalik2187836Link { CRCreditsOpenTwitter(@"Vitalik2187836"); }
- (void)frknvkilicLink { CRCreditsOpenTwitter(@"frknvkilic"); }
- (void)rdaraujoLink
{
    CRCreditsOpenURL(@"https://github.com/rdaraujo");
}
- (void)RedenticDevLink { CRCreditsOpenTwitter(@"RedenticDev"); }
- (void)cySxLLink { CRCreditsOpenTwitter(@"CySxL"); }

@end

@interface CRPCreditsMiniZipController : PSListController
@property (nonatomic, strong) NSArray *craneLicenseSpecifiers;
@end

@implementation CRPCreditsMiniZipController
- (void)viewDidLoad
{
    [self specifiers];
    [super viewDidLoad];
}

- (id)specifiers
{
    if (!self.craneLicenseSpecifiers)
        self.craneLicenseSpecifiers =
            CRCreditsLocalizedRows(self, @"MiniZipLicense", NO);
    CRCreditsInstallBacking(self, self.craneLicenseSpecifiers);
    return self.craneLicenseSpecifiers;
}
@end

@interface CRPCreditsZipArchiveController : PSListController
@property (nonatomic, strong) NSArray *craneLicenseSpecifiers;
@end

@implementation CRPCreditsZipArchiveController
- (void)viewDidLoad
{
    [self specifiers];
    [super viewDidLoad];
}

- (id)specifiers
{
    if (!self.craneLicenseSpecifiers)
        self.craneLicenseSpecifiers =
            CRCreditsLocalizedRows(self, @"ZipArchiveLicense", NO);
    CRCreditsInstallBacking(self, self.craneLicenseSpecifiers);
    return self.craneLicenseSpecifiers;
}
@end
